import Foundation

/// Lightweight, deterministic microphone conditioning for 16 kHz mono speech.
///
/// This deliberately avoids denoising, compression and spectral rewriting:
/// those can erase consonants or alter code-switched words. It only removes
/// DC/low-frequency rumble and applies a bounded, peak-safe level correction.
enum AudioConditioner {
  static func process16k(_ input: [Float]) -> [Float] {
    guard !input.isEmpty else { return [] }

    // First-order 60 Hz high-pass. This also removes microphone DC offset.
    let alpha = Float(exp(-2 * Double.pi * 60 / 16_000))
    var filtered = [Float](repeating: 0, count: input.count)
    var previousInput: Float = 0
    var previousOutput: Float = 0
    for i in input.indices {
      let x = input[i].isFinite ? input[i] : 0
      let y = alpha * (previousOutput + x - previousInput)
      filtered[i] = y
      previousInput = x
      previousOutput = y
    }

    // Estimate speech level from non-silent 20 ms frames. Ignoring silent
    // frames prevents long pauses from causing excessive amplification.
    let frameSize = 320
    var frameLevels: [Float] = []
    frameLevels.reserveCapacity((filtered.count + frameSize - 1) / frameSize)
    var offset = 0
    while offset < filtered.count {
      let end = min(filtered.count, offset + frameSize)
      var energy: Double = 0
      for sample in filtered[offset..<end] {
        energy += Double(sample) * Double(sample)
      }
      let rms = Float(sqrt(energy / Double(end - offset)))
      if rms >= 0.003 { frameLevels.append(rms) }
      offset = end
    }
    guard !frameLevels.isEmpty else { return filtered.map { abs($0) < 1e-7 ? 0 : $0 } }

    frameLevels.sort()
    let reference = frameLevels[Int(Double(frameLevels.count - 1) * 0.65)]
    var gain = min(3, max(0.75, 0.08 / max(reference, 1e-6)))
    if let peak = filtered.map(abs).max(), peak > 0 {
      gain = min(gain, 0.98 / peak)
    }
    return filtered.map { min(0.98, max(-0.98, $0 * gain)) }
  }
}
