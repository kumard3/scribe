import Foundation
import CSherpa

/// On-device punctuation restoration for engines that emit an unpunctuated,
/// lowercase wall of words. Wraps sherpa-onnx OnlinePunctuation (CNN-BiLSTM).
/// Loaded in-process (the model is ~29 MB) and evicted after idle.
final class PunctuationRuntime: @unchecked Sendable {
  static let shared = PunctuationRuntime()

  private let queue = DispatchQueue(label: "ai.scribe.punct", qos: .userInitiated)
  private var handle: OpaquePointer?
  private var loadedKey = ""
  private var evict: DispatchWorkItem?

  /// True for the ASR kinds whose output carries no punctuation or casing.
  /// Whisper, Nemotron, Canary (use_pnc), Apple, Srota and Moonshine already
  /// punctuate; only the streaming Zipformer and the CTC models do not.
  static func needsPunctuation(_ kind: ModelKind) -> Bool {
    switch kind {
    case .onlineTransducer, .nemoCtc, .dolphinCtc: return true
    default: return false
    }
  }

  /// Synchronous, safe to call from any non-main queue. No-op (returns the
  /// input) when the model is missing or inference fails.
  func punctuate(_ text: String) -> String {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          SupportModelStore.punctInstalled else { return text }
    var out = text
    queue.sync { out = self.add(text) }
    return out
  }

  func release() {
    queue.sync {
      if let h = handle { SherpaOnnxDestroyOnlinePunctuation(h) }
      handle = nil
      loadedKey = ""
    }
  }

  private func add(_ text: String) -> String {
    guard let model = SupportModelStore.punctModelPath(),
          let vocab = SupportModelStore.punctVocabPath() else { return text }
    let key = model + "|" + vocab
    if handle == nil || loadedKey != key {
      if let h = handle { SherpaOnnxDestroyOnlinePunctuation(h) }
      handle = Self.create(model: model, vocab: vocab)
      loadedKey = handle != nil ? key : ""
    }
    guard let h = handle else { return text }
    var result = text
    text.withCString { c in
      if let out = SherpaOnnxOnlinePunctuationAddPunct(h, c) {
        result = String(cString: out)
        SherpaOnnxOnlinePunctuationFreeText(out)
      }
    }
    scheduleEvict()
    return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : result
  }

  private func scheduleEvict() {
    evict?.cancel()
    let w = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.queue.async {
        if let h = self.handle { SherpaOnnxDestroyOnlinePunctuation(h) }
        self.handle = nil
        self.loadedKey = ""
        dlog("punctuation evicted after idle")
      }
    }
    evict = w
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: w)
  }

  private static func create(model: String, vocab: String) -> OpaquePointer? {
    var cfg = SherpaOnnxOnlinePunctuationConfig()
    memset(&cfg, 0, MemoryLayout.size(ofValue: cfg))
    let m = strdup(model)
    let v = strdup(vocab)
    let p = strdup("cpu")
    defer { free(m); free(v); free(p) } // sherpa copies the config strings
    cfg.model.cnn_bilstm = UnsafePointer(m)
    cfg.model.bpe_vocab = UnsafePointer(v)
    cfg.model.num_threads = 1
    cfg.model.provider = UnsafePointer(p)
    let h = SherpaOnnxCreateOnlinePunctuation(&cfg)
    if h == nil { dlog("punctuation: create failed") }
    return h
  }
}
