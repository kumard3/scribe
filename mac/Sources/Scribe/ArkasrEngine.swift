import Accelerate
import Foundation

/// Runs the Audio8 `audio8_asr_onnx_bundle` models (Audio8-ASR-0.1B and the
/// ARK-ASR line) on ONNX Runtime. The arch is `arkasr`: a Whisper-style mel
/// front end, an MLP projector into a small Qwen-style causal LM, then greedy
/// decoding with an external KV cache.
///
/// Ported from `asr_onnx_runtime.py` in the bundle. sherpa-onnx cannot load
/// these graphs and llama.cpp has no `arkasr` converter, so the decode loop
/// lives here rather than in an existing engine.
final class ArkasrEngine: OfflineAsrEngine {
  struct Config: Equatable {
    var nMel = 128
    var framesPadded = 3000
    var hop = 160
    var mergeFactor = 4
    var maxAudioSeconds = 30
    var sampleRate = 16000
    var numLayers = 8
    var numKVHeads = 8
    var headDim = 64
    var maxTotalLen = 512
    var maxNewTokens = 128
    var audioTokenId = 151646
    var padTokenId = 151643
    var eosTokenIds: Set<Int> = [151645]
    var blockedTokenIds: Set<Int> = [151647, 151650, 151648, 151646, 151649]
    var userTokenId = 151647
    var beginAudioTokenId = 151648
    var endAudioTokenId = 151649
    var assistantTokenId = 151650
    /// BPE ids for "Please transcribe this audio.". The reference runtime
    /// hardcodes that string, so the ids are baked in rather than shipping
    /// merges.txt and a BPE encoder to recompute them.
    var promptSuffix = [5501, 1356, 3114, 419, 7699, 13]
  }

  private let config: Config
  private let audio: Ort.Session
  private let prefill: Ort.Session
  private let decode: Ort.Session
  private let tokenizer: ArkasrTokenizer
  private let embedding: Npy.Array
  private let projNormWeight: [Float]
  private let projNormBias: [Float]
  private let projLinearWeight: [Float]  // [out=512, in=1024] row-major
  private let projLinearBias: [Float]
  private let hiddenSize: Int
  private let audioDim: Int

  init(dir: URL, config: Config = Config()) throws {
    self.config = config
    let threads = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))

    func pick(_ needle: String) throws -> String {
      guard let url = ModelStore.find(needle, in: dir, preferInt8: true) else {
        throw Ort.Error(message: "\(needle) graph missing from \(dir.lastPathComponent)")
      }
      return url.path
    }
    audio = try Ort.Session(path: try pick("audio_hidden"), threads: threads)
    prefill = try Ort.Session(path: try pick("lm_cache_prefill"), threads: threads)
    decode = try Ort.Session(path: try pick("lm_cache_decode"), threads: threads)

    tokenizer = try ArkasrTokenizer(vocabURL: dir.appendingPathComponent("vocab.json"))
    embedding = try Npy.load(url: dir.appendingPathComponent("token_embedding.npy"))
    guard embedding.shape.count == 2 else {
      throw Ort.Error(message: "token_embedding.npy must be 2-D, got \(embedding.shape)")
    }
    hiddenSize = embedding.shape[1]

    let projector = try Npy.loadZip(url: dir.appendingPathComponent("audio_projector.npz"))
    guard let nw = projector["norm_weight"], let nb = projector["norm_bias"],
          let lw = projector["linear_weight"], let lb = projector["linear_bias"] else {
      throw Ort.Error(message: "audio_projector.npz missing norm/linear arrays")
    }
    projNormWeight = nw.floats()
    projNormBias = nb.floats()
    projLinearWeight = lw.floats()
    projLinearBias = lb.floats()
    audioDim = lw.shape.count == 2 ? lw.shape[1] : projNormWeight.count
  }

  /// Number of audio tokens the prompt must reserve, mirroring
  /// `ark_audio_token_count` in the reference runtime.
  private func audioTokenCount(samples: Int) -> Int {
    let melFrames = samples / config.hop
    let downsampled = (melFrames + 1) / 2
    return max(1, downsampled / config.mergeFactor)
  }

  func transcribe(samples input: [Float], sampleRate: Int) throws -> String {
    var samples = SileroVAD.resampleTo16k(input, from: sampleRate)
    let maxSamples = config.maxAudioSeconds * config.sampleRate
    if samples.count > maxSamples { samples = Array(samples[0..<maxSamples]) }
    guard samples.count >= config.hop else { return "" }

    let audioEmbeds = try encodeAudio(samples)
    let tokens = audioEmbeds.count
    guard tokens > 0 else { return "" }

    var ids = [config.userTokenId, config.beginAudioTokenId]
    ids.append(contentsOf: Array(repeating: config.audioTokenId, count: tokens))
    ids.append(config.endAudioTokenId)
    ids.append(contentsOf: config.promptSuffix)
    ids.append(config.assistantTokenId)
    guard ids.count <= config.maxTotalLen else {
      throw Ort.Error(message: "prompt of \(ids.count) exceeds cache length \(config.maxTotalLen)")
    }

    var embeds = [Float](repeating: 0, count: ids.count * hiddenSize)
    var audioSlot = 0
    for (i, id) in ids.enumerated() {
      if id == config.audioTokenId {
        let row = audioEmbeds[audioSlot]
        audioSlot += 1
        for d in 0..<min(hiddenSize, row.count) { embeds[i * hiddenSize + d] = row[d] }
      } else {
        let row = embedding.row(id)
        for d in 0..<min(hiddenSize, row.count) { embeds[i * hiddenSize + d] = row[d] }
      }
    }

    return try generate(promptEmbeds: embeds, promptLen: ids.count)
  }

  // MARK: - Audio branch

  private func encodeAudio(_ samples: [Float]) throws -> [[Float]] {
    let (mel, frames) = WhisperMel.logMel(samples: samples, nMel: config.nMel)
    let padded = WhisperMel.padFrames(
      mel, nMel: config.nMel, frames: frames, to: config.framesPadded)
    let featureLen = min(
      max(1, Int((Double(samples.count) / Double(config.hop)).rounded(.up))), frames)

    let out = try audio.run(
      floats: ["audios": (padded, [1, Int64(config.nMel), Int64(config.framesPadded)])],
      int64s: ["audio_feature_lengths": ([Int64(featureLen)], [1])])
    guard out.count >= 2 else { throw Ort.Error(message: "audio graph returned \(out.count) outputs") }

    let hidden = out[0].data
    let mask = out[1].data
    let dim = Int(out[0].shape.last ?? Int64(audioDim))
    var rows: [[Float]] = []
    rows.reserveCapacity(mask.count)
    for (i, m) in mask.enumerated() where m != 0 {
      let start = i * dim
      guard start + dim <= hidden.count else { break }
      rows.append(Array(hidden[start..<(start + dim)]))
    }

    let want = audioTokenCount(samples: samples.count)
    if rows.count != want { rows = Self.adaptiveAvgPool(rows, to: want) }
    return rows.map { project($0) }
  }

  /// LayerNorm(eps 1e-5) then the projector's linear layer, 1024 to 512.
  private func project(_ x: [Float]) -> [Float] {
    var mean: Float = 0
    vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
    var centered = [Float](repeating: 0, count: x.count)
    var negMean = -mean
    vDSP_vsadd(x, 1, &negMean, &centered, 1, vDSP_Length(x.count))
    var variance: Float = 0
    vDSP_measqv(centered, 1, &variance, vDSP_Length(x.count))
    var inv = 1.0 / sqrt(variance + 1e-5)
    vDSP_vsmul(centered, 1, &inv, &centered, 1, vDSP_Length(x.count))
    vDSP_vmul(centered, 1, projNormWeight, 1, &centered, 1, vDSP_Length(x.count))
    vDSP_vadd(centered, 1, projNormBias, 1, &centered, 1, vDSP_Length(x.count))

    var out = projLinearBias
    cblas_sgemv(CblasRowMajor, CblasNoTrans,
                Int32(hiddenSize), Int32(x.count), 1.0,
                projLinearWeight, Int32(x.count), centered, 1, 1.0, &out, 1)
    return out
  }

  private static func adaptiveAvgPool(_ rows: [[Float]], to size: Int) -> [[Float]] {
    guard !rows.isEmpty, rows.count != size, size > 0 else { return rows }
    let dim = rows[0].count
    return (0..<size).map { i in
      let start = Int(floor(Double(i * rows.count) / Double(size)))
      let end = max(start + 1, Int(ceil(Double((i + 1) * rows.count) / Double(size))))
      var acc = [Float](repeating: 0, count: dim)
      var n: Float = 0
      for r in start..<min(end, rows.count) {
        vDSP_vadd(acc, 1, rows[r], 1, &acc, 1, vDSP_Length(dim))
        n += 1
      }
      if n > 1 {
        var scale = 1 / n
        vDSP_vsmul(acc, 1, &scale, &acc, 1, vDSP_Length(dim))
      }
      return acc
    }
  }

  // MARK: - LM branch

  private func generate(promptEmbeds: [Float], promptLen: Int) throws -> String {
    let layers = config.numLayers
    let heads = config.numKVHeads
    let dim = config.headDim
    let total = config.maxTotalLen
    let perLayer = heads * total * dim

    var caches = [[Float]](repeating: [Float](repeating: 0, count: perLayer), count: layers * 2)

    let prefillOut = try prefill.run(
      floats: ["inputs_embeds": (promptEmbeds, [1, Int64(promptLen), Int64(hiddenSize)])],
      int64s: ["cache_position": ((0..<Int64(promptLen)).map { $0 }, [Int64(promptLen)])])
    guard prefillOut.count >= 1 + layers * 2 else {
      throw Ort.Error(message: "prefill returned \(prefillOut.count) outputs, want \(1 + layers * 2)")
    }
    for l in 0..<(layers * 2) {
      let src = prefillOut[1 + l].data
      for h in 0..<heads {
        for t in 0..<promptLen {
          let s = (h * promptLen + t) * dim
          let d = (h * total + t) * dim
          guard s + dim <= src.count else { continue }
          caches[l].replaceSubrange(d..<(d + dim), with: src[s..<(s + dim)])
        }
      }
    }

    var logits = Self.lastRow(prefillOut[0])
    var generated: [Int] = []
    var position = promptLen

    for _ in 0..<config.maxNewTokens {
      for id in config.blockedTokenIds where id < logits.count { logits[id] = -.infinity }
      var best: Float = -.infinity
      var next = config.padTokenId
      for (i, v) in logits.enumerated() where v > best { best = v; next = i }
      if config.eosTokenIds.contains(next) || next == config.padTokenId { break }
      generated.append(next)
      guard position < total else { break }

      var mask = [Int64](repeating: 0, count: total)
      for i in 0...position where i < total { mask[i] = 1 }

      var floats: [String: (data: [Float], shape: [Int64])] = [
        "inputs_embeds": (embedding.row(next), [1, 1, Int64(hiddenSize)])
      ]
      for l in 0..<layers {
        floats["cache_key_\(l)"] = (caches[2 * l], [1, Int64(heads), Int64(total), Int64(dim)])
        floats["cache_value_\(l)"] = (caches[2 * l + 1], [1, Int64(heads), Int64(total), Int64(dim)])
      }
      let out = try decode.run(floats: floats, int64s: [
        "attention_mask": (mask, [1, Int64(total)]),
        "cache_position": ([Int64(position)], [1]),
      ])
      guard out.count >= 1 + layers * 2 else {
        throw Ort.Error(message: "decode returned \(out.count) outputs")
      }
      for l in 0..<(layers * 2) {
        let src = out[1 + l].data
        for h in 0..<heads {
          let s = h * dim
          let d = (h * total + position) * dim
          guard s + dim <= src.count else { continue }
          caches[l].replaceSubrange(d..<(d + dim), with: src[s..<(s + dim)])
        }
      }
      logits = Self.lastRow(out[0])
      position += 1
    }

    return ArkasrTokenizer.normalize(tokenizer.decode(generated))
  }

  /// Logits for the final sequence position of a [1, S, V] output.
  private static func lastRow(_ tensor: (data: [Float], shape: [Int64])) -> [Float] {
    guard let vocab = tensor.shape.last.map({ Int($0) }), vocab > 0 else { return tensor.data }
    let start = tensor.data.count - vocab
    guard start >= 0 else { return tensor.data }
    return Array(tensor.data[start...])
  }
}
