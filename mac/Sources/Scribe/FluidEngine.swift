import Foundation
import FluidAudio

/// Parakeet on the Apple Neural Engine via FluidAudio. Unlike every sherpa
/// model this runs in-process rather than in the worker subprocess, and it
/// fetches its own CoreML bundles on first use, so ModelStore never sees it.
actor FluidEngine {
  static let shared = FluidEngine()

  private var manager: AsrManager?
  private var loadedVersion: AsrModelVersion?

  func transcribe(_ samples: [Float], sampleRate: Int, version: AsrModelVersion) async throws
    -> String
  {
    let audio = SileroVAD.resampleTo16k(samples, from: sampleRate)
    guard !audio.isEmpty else { return "" }
    let engine = try await ready(version)
    var state = try TdtDecoderState()
    let result = try await engine.transcribe(audio, decoderState: &state)
    return result.text
  }

  func release() {
    manager = nil
    loadedVersion = nil
  }

  private func ready(_ version: AsrModelVersion) async throws -> AsrManager {
    if let manager, loadedVersion == version { return manager }
    dlog("fluid: loading Parakeet \(version) (downloads on first use)")
    let models = try await AsrModels.downloadAndLoad(version: version)
    let engine = AsrManager(config: .default)
    try await engine.loadModels(models)
    manager = engine
    loadedVersion = version
    dlog("fluid: Parakeet \(version) ready")
    return engine
  }
}
