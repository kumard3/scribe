import Foundation
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

/// Gemma 4 E2B on Apple Silicon via MLX.
///
/// One safetensors bundle for both text cleanup and Gemma STT. llama.cpp Metal
/// teardown can abort, so GGUF stays CPU-only; MLX is the GPU path.
actor MLXEngine {
  private var container: ModelContainer?
  private var loadedDir: String?

  func generate(dir: URL, vision: Bool, instruction: String, text: String, maxTokens: Int) async throws -> String {
    let container = try await ensure(dir: dir, vision: vision)
    let session = ChatSession(
      container,
      instructions: instruction,
      generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.2)
    )
    return try await session.respond(to: text)
  }

  func transcribe(dir: URL, instruction: String, samples: [Float], sampleRate: Int,
                  maxTokens: Int) async throws -> String {
    let pcm = SileroVAD.resampleTo16k(samples, from: sampleRate)
    let wav = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-mlx-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: wav) }
    try WaveFile.write(samples: pcm, sampleRate: 16_000, to: wav)
    let container = try await ensure(dir: dir, vision: true)
    var processing = UserInput.Processing()
    processing.audio.sampleRate = 16_000
    processing.audio.channels = 1
    let session = ChatSession(
      container,
      generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.1),
      processing: processing
    )
    return try await session.respond(to: instruction, audio: .url(wav))
  }

  func release() {
    container = nil
    loadedDir = nil
    Memory.clearCache()
  }

  /// `vision` models (Gemma audio) load through MLXVLM, text-only ones (Qwen) through MLXLLM.
  private func ensure(dir: URL, vision: Bool) async throws -> ModelContainer {
    if loadedDir == dir.path, let container { return container }
    container = nil
    loadedDir = nil
    let downloader = LocalDirDownloader(dir: dir)
    let loaded = vision
      ? try await VLMModelFactory.shared.loadContainer(
          from: downloader, using: #huggingFaceTokenizerLoader(),
          configuration: ModelConfiguration(directory: dir, extraEOSTokens: ["<turn|>", "<end_of_turn>"]))
      : try await LLMModelFactory.shared.loadContainer(
          from: downloader, using: #huggingFaceTokenizerLoader(),
          configuration: ModelConfiguration(directory: dir))
    container = loaded
    loadedDir = dir.path
    dlog("mlx \(vision ? "vlm" : "llm") loaded \(dir.lastPathComponent)")
    return loaded
  }
}

/// Weights are already on disk; mlx-swift-lm still wants a Downloader.
struct LocalDirDownloader: Downloader {
  let dir: URL

  func download(
    id: String,
    revision: String?,
    matching patterns: [String],
    useLatest: Bool,
    progressHandler: @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    progressHandler(Progress(totalUnitCount: 1))
    return dir
  }
}

final class MLXRuntime: @unchecked Sendable {
  static let shared = MLXRuntime()
  private let engine = MLXEngine()
  private var evict: DispatchWorkItem?
  private let lock = NSLock()

  private init() {
    // The buffer cache defaults to ~1.5x the GPU working set (12.9 GB measured on an 18 GB Mac):
    // every variable-length audio piece allocates new sizes, so a meeting fills it and swaps the Mac.
    Memory.cacheLimit = 256 << 20
  }

  static var isAvailable: Bool {
    guard let spec = ModelCatalog.spec("gemma4-e2b-mlx") else { return false }
    return ModelStore.mlxInstalled(spec)
  }

  static func gemmaAsrUsesMlx(_ spec: ModelSpec) -> Bool {
    spec.id == ModelCatalog.gemmaAsrId && isAvailable
  }

  func process(spec: ModelSpec, instruction: String, text: String, maxTokens: Int32,
               completion: @escaping (String?) -> Void) {
    guard ModelStore.mlxInstalled(spec) else {
      DispatchQueue.main.async { completion(nil) }
      return
    }
    let dir = ModelStore.dir(for: spec)
    let vision = spec.id == ModelCatalog.mlxId
    Task {
      let out: String?
      do {
        let raw = try await self.engine.generate(
          dir: dir, vision: vision, instruction: instruction, text: text, maxTokens: Int(maxTokens)
        )
        out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scheduleEvict()
      } catch {
        dlog("mlx cleanup failed: \(error.localizedDescription)")
        out = nil
      }
      await MainActor.run { completion(out?.isEmpty == false ? out : nil) }
    }
  }

  func transcribe(samples: [Float], sampleRate: Int, instruction: String,
                  maxTokens: Int32 = 256,
                  completion: @escaping (String?) -> Void) {
    guard let spec = ModelCatalog.spec("gemma4-e2b-mlx"),
          ModelStore.mlxInstalled(spec) else {
      DispatchQueue.main.async { completion(nil) }
      return
    }
    let dir = ModelStore.dir(for: spec)
    Task {
      let out: String?
      do {
        let raw = try await self.engine.transcribe(
          dir: dir, instruction: instruction, samples: samples,
          sampleRate: sampleRate, maxTokens: Int(maxTokens)
        )
        out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scheduleEvict()
      } catch {
        dlog("mlx stt failed: \(error.localizedDescription)")
        out = nil
      }
      await MainActor.run { completion(out?.isEmpty == false ? out : nil) }
    }
  }

  func release() {
    lock.lock()
    evict?.cancel()
    evict = nil
    lock.unlock()
    Task { await engine.release() }
  }

  private func scheduleEvict() {
    lock.lock()
    evict?.cancel()
    let w = DispatchWorkItem { [weak self] in
      Task { await self?.engine.release() }
      dlog("mlx evicted after idle")
    }
    evict = w
    lock.unlock()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60, execute: w)
  }
}
