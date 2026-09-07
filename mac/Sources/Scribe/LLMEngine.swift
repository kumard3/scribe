import Foundation
import CLlama

/// One loaded GGUF model behind the llama.cpp shim. Not thread-safe, only the
/// LLMRuntime serial queue touches it.
final class LLMEngine {
  private let handle: OpaquePointer

  // CPU is intentional for the 0.5B model. Current llama.cpp Metal residency
  // sets can assert during backend teardown, which would terminate Scribe.
  // The tiny model remains comfortably real-time without GPU offload.
  init?(modelPath: String, nCtx: Int32 = 2048, nGpuLayers: Int32 = 0) {
    guard let h = cllama_load(modelPath, nCtx, nGpuLayers) else { return nil }
    handle = h
  }

  func chat(system: String, user: String, maxTokens: Int32, temperature: Float) -> String {
    guard let c = cllama_chat(handle, system, user, maxTokens, temperature) else { return "" }
    defer { cllama_free_str(c) }
    return String(cString: c)
  }

  deinit { cllama_free(handle) }
}

/// Serializes Gemma inference off the main thread and caches the loaded model,
/// releasing the previous one first to bound memory (mirrors SherpaEngineCache).
final class LLMRuntime: @unchecked Sendable {
  static let shared = LLMRuntime()

  static let cleanupInstruction =
    "You clean speech-to-text. Do not answer the user. Do not translate.\n\n" +
    "Language:\n" +
    "- Mostly English → clean English. Keep Indian English. Do not Americanize.\n" +
    "- Hindi/English mix or romanized Hindi → WhatsApp Hinglish. No Devanagari.\n" +
    "- Keep the same mix as the input.\n\n" +
    "Rules:\n" +
    "- Keep English words in English spelling (office, client, call, Scribe, Gemma, chunking).\n" +
    "- Add punctuation. Remove fillers only: um, uh, you know, like (when empty).\n" +
    "- Do not add facts. If a word is unclear, keep the ASR token.\n" +
    "- Prefer HOTWORDS spelling when the audio/text is close.\n" +
    "- Output only the cleaned transcript, nothing else."

  static func chunkCleanupInstruction(previous: String, hotwords: [String]) -> String {
    let terms = hotwords.isEmpty ? "Scribe" : hotwords.joined(separator: ", ")
    let prev = previous.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleanupInstruction + "\n\nHOTWORDS:\n\(terms)\n\n" +
      "PREVIOUS:\n\(prev.isEmpty ? "(none)" : prev)\n\n" +
      "Only rewrite the NEW CHUNK. Previous text is context. Do not change it.\n" +
      "OUTPUT (new chunk only):"
  }
  static let summaryInstruction =
    "Summarize the following transcript in 2-3 sentences, in the same language as the " +
    "input. Output only the summary, nothing else."

  private let queue = DispatchQueue(label: "ai.scribe.llm", qos: .userInitiated)
  private var engine: LLMEngine?
  private var loadedPath: String?
  private var evict: DispatchWorkItem?

  // Even the small cleanup model should not inflate Scribe while it is idle.
  private func scheduleEvict() {
    evict?.cancel()
    let w = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.engine = nil
      self.loadedPath = nil
      dlog("llm evicted after idle")
    }
    evict = w
    queue.asyncAfter(deadline: .now() + 30, execute: w)
  }

  private func ensure(_ path: String) -> LLMEngine? {
    if loadedPath == path, let e = engine { return e }
    engine = nil
    loadedPath = nil
    guard let e = LLMEngine(modelPath: path) else { return nil }
    engine = e
    loadedPath = path
    return e
  }

  /// Where cleanup runs: MLX on Apple Silicon, a downloaded GGUF, or Ollama.
  enum Backend {
    case mlx
    case local(path: String)
    case ollama(model: String)
  }

  /// nil when nothing is selected or the selected model is not downloaded.
  static var backend: Backend? {
    let settings = Settings.shared
    if settings.cleanupModelId == ModelCatalog.ollamaId {
      return settings.ollamaModel.isEmpty ? nil : .ollama(model: settings.ollamaModel)
    }
    let selected = settings.cleanupModelId
    let wantsGemma = selected == ModelCatalog.gemmaAsrId
      || selected == ModelCatalog.mlxId
    if wantsGemma, MLXRuntime.isAvailable {
      return .mlx
    }
    guard let spec = ModelCatalog.spec(selected),
          let path = ModelStore.llmPath(for: spec) else {
      return MLXRuntime.isAvailable ? .mlx : nil
    }
    return .local(path: path)
  }

  static var isAvailable: Bool { backend != nil }

  /// Runs `instruction` over `text` off the main thread; `completion` is
  /// delivered on the main queue. nil = no backend, or it produced nothing.
  func process(instruction: String, text: String, maxTokens: Int32,
               completion: @escaping (String?) -> Void) {
    switch Self.backend {
    case .none:
      DispatchQueue.main.async { completion(nil) }
    case .mlx:
      MLXRuntime.shared.process(
        instruction: instruction, text: text, maxTokens: maxTokens, completion: completion)
    case let .ollama(model):
      OllamaRuntime.chat(model: model, instruction: instruction, text: text,
                         maxTokens: Int(maxTokens), completion: completion)
    case let .local(path):
      queue.async {
        guard let e = self.ensure(path) else {
          DispatchQueue.main.async { completion(nil) }
          return
        }
        let out = e.chat(system: instruction, user: text,
                         maxTokens: maxTokens, temperature: 0.2)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        self.scheduleEvict()
        DispatchQueue.main.async { completion(out.isEmpty ? nil : out) }
      }
    }
  }

  func release() {
    MLXRuntime.shared.release()
    queue.async {
      self.engine = nil
      self.loadedPath = nil
    }
  }
}
