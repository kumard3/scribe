import Accelerate
import Foundation

/// 128-bin log-mel frontend matching HuggingFace `WhisperFeatureExtractor`
/// (n_fft 400, hop 160, slaney mel, centre-padded), which is what the Audio8
/// `Qwen3ASRProcessor` bundles use.
enum WhisperMel {
  static let nFFT = 400
  static let hop = 160
  static let bins = nFFT / 2 + 1  // 201
  static let sampleRate = 16000

  /// mel [nMel][bins], row-major. Built once per bin count.
  private static var filterCache: [Int: [Float]] = [:]
  private static let cacheLock = NSLock()

  private static func hertzToMel(_ f: Double) -> Double {
    let minLogHertz = 1000.0, minLogMel = 15.0
    let logstep = 27.0 / log(6.4)
    return f >= minLogHertz
      ? minLogMel + log(f / minLogHertz) * logstep
      : 3.0 * f / 200.0
  }

  private static func melToHertz(_ m: Double) -> Double {
    let minLogHertz = 1000.0, minLogMel = 15.0
    let logstep = log(6.4) / 27.0
    return m >= minLogMel
      ? minLogHertz * exp(logstep * (m - minLogMel))
      : 200.0 * m / 3.0
  }

  /// Slaney-normalised triangular mel filterbank, [nMel * bins] row-major.
  static func filterBank(nMel: Int) -> [Float] {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    if let cached = filterCache[nMel] { return cached }

    let fftFreqs = (0..<bins).map { Double($0) * Double(sampleRate / 2) / Double(bins - 1) }
    let melMin = hertzToMel(0), melMax = hertzToMel(Double(sampleRate / 2))
    let filterFreqs = (0..<(nMel + 2)).map { i -> Double in
      melToHertz(melMin + (melMax - melMin) * Double(i) / Double(nMel + 1))
    }

    var out = [Float](repeating: 0, count: nMel * bins)
    for m in 0..<nMel {
      let left = filterFreqs[m], center = filterFreqs[m + 1], right = filterFreqs[m + 2]
      let downDiff = center - left, upDiff = right - center
      let enorm = 2.0 / (right - left)
      for k in 0..<bins {
        let f = fftFreqs[k]
        let down = downDiff > 0 ? (f - left) / downDiff : 0
        let up = upDiff > 0 ? (right - f) / upDiff : 0
        let v = max(0.0, min(down, up)) * enorm
        out[m * bins + k] = Float(v)
      }
    }
    filterCache[nMel] = out
    return out
  }

  /// Log-mel spectrogram, returned mel-major ([nMel][frames] flattened) exactly
  /// as the ONNX `audios` input expects. `frames` is `samples.count / hop`,
  /// matching Whisper's centre-padded STFT with the trailing frame dropped.
  static func logMel(samples: [Float], nMel: Int = 128) -> (data: [Float], frames: Int) {
    let n = samples.count
    let frames = max(1, n / hop)
    let pad = nFFT / 2

    // Reflect-pad, then lay every windowed frame out as a row: [frames x nFFT].
    var padded = [Float](repeating: 0, count: n + 2 * pad)
    for i in 0..<pad { padded[i] = samples[min(n - 1, max(0, pad - i))] }
    for i in 0..<n { padded[pad + i] = samples[i] }
    for j in 0..<pad { padded[n + pad + j] = samples[max(0, n - 2 - j)] }

    // Periodic Hann, np.hanning(n_fft + 1)[:-1].
    var window = [Float](repeating: 0, count: nFFT)
    for i in 0..<nFFT {
      window[i] = Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(nFFT)))
    }

    var frameMatrix = [Float](repeating: 0, count: frames * nFFT)
    for f in 0..<frames {
      let start = f * hop
      for i in 0..<nFFT {
        let idx = start + i
        frameMatrix[f * nFFT + i] = idx < padded.count ? padded[idx] * window[i] : 0
      }
    }

    // n_fft = 400 is not a vDSP-supported DFT length (needs f*2^n, f in 1,3,5,15),
    // so the real DFT runs as two GEMMs against precomputed cos/sin bases.
    var cosBasis = [Float](repeating: 0, count: nFFT * bins)
    var sinBasis = [Float](repeating: 0, count: nFFT * bins)
    for t in 0..<nFFT {
      for k in 0..<bins {
        let a = -2.0 * Double.pi * Double(t) * Double(k) / Double(nFFT)
        cosBasis[t * bins + k] = Float(cos(a))
        sinBasis[t * bins + k] = Float(sin(a))
      }
    }

    var re = [Float](repeating: 0, count: frames * bins)
    var im = [Float](repeating: 0, count: frames * bins)
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                Int32(frames), Int32(bins), Int32(nFFT), 1.0,
                frameMatrix, Int32(nFFT), cosBasis, Int32(bins), 0.0, &re, Int32(bins))
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                Int32(frames), Int32(bins), Int32(nFFT), 1.0,
                frameMatrix, Int32(nFFT), sinBasis, Int32(bins), 0.0, &im, Int32(bins))

    var power = [Float](repeating: 0, count: frames * bins)
    vDSP_vsq(re, 1, &power, 1, vDSP_Length(frames * bins))
    var imSq = [Float](repeating: 0, count: frames * bins)
    vDSP_vsq(im, 1, &imSq, 1, vDSP_Length(frames * bins))
    vDSP_vadd(power, 1, imSq, 1, &power, 1, vDSP_Length(frames * bins))

    // mel [nMel x bins] @ power^T [bins x frames] -> [nMel x frames]
    let filters = filterBank(nMel: nMel)
    var mel = [Float](repeating: 0, count: nMel * frames)
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                Int32(nMel), Int32(frames), Int32(bins), 1.0,
                filters, Int32(bins), power, Int32(bins), 0.0, &mel, Int32(frames))

    var floor: Float = 1e-10
    vDSP_vthr(mel, 1, &floor, &mel, 1, vDSP_Length(mel.count))
    var count = Int32(mel.count)
    vvlog10f(&mel, mel, &count)

    var peak: Float = 0
    vDSP_maxv(mel, 1, &peak, vDSP_Length(mel.count))
    var lower = peak - 8.0
    vDSP_vthr(mel, 1, &lower, &mel, 1, vDSP_Length(mel.count))
    var add: Float = 4.0, scale: Float = 0.25
    vDSP_vsadd(mel, 1, &add, &mel, 1, vDSP_Length(mel.count))
    vDSP_vsmul(mel, 1, &scale, &mel, 1, vDSP_Length(mel.count))

    return (mel, frames)
  }

  /// Zero-pads (or truncates) a mel-major spectrogram to `target` frames.
  static func padFrames(_ mel: [Float], nMel: Int, frames: Int, to target: Int) -> [Float] {
    if frames == target { return mel }
    var out = [Float](repeating: 0, count: nMel * target)
    let copy = min(frames, target)
    for m in 0..<nMel {
      for t in 0..<copy { out[m * target + t] = mel[m * frames + t] }
    }
    return out
  }
}
