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

  func generate(prompt: String, maxTokens: Int32, temperature: Float) -> String {
    guard let c = cllama_generate(handle, prompt, maxTokens, temperature) else { return "" }
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
    "Rewrite the following transcript with correct punctuation and capitalization. " +
    "Remove filler words and false starts. Keep all of the meaning and the original " +
    "language (including Hindi or Hinglish). Output only the rewritten text, nothing else."
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

  /// Runs `instruction` over `text` on a background queue; `completion` is
  /// delivered on the main queue. nil = model failed to load or produced nothing.
  func process(modelPath: String, instruction: String, text: String,
               maxTokens: Int32, completion: @escaping (String?) -> Void) {
    queue.async {
      guard let e = self.ensure(modelPath) else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      let prompt = "<|im_start|>system\n\(instruction)<|im_end|>\n" +
        "<|im_start|>user\n\(text)<|im_end|>\n<|im_start|>assistant\n"
      let out = e.generate(prompt: prompt, maxTokens: maxTokens, temperature: 0.2)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      self.scheduleEvict()
      DispatchQueue.main.async { completion(out.isEmpty ? nil : out) }
    }
  }

  func release() {
    queue.async {
      self.engine = nil
      self.loadedPath = nil
    }
  }
}
