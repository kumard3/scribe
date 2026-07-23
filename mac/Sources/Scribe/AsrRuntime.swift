import Foundation
import CLlama

/// Serializes Qwen3-ASR (Srota) inference off the main thread. Mirrors
/// LLMRuntime: caches the loaded model pair, evicts after idle to keep the
/// app's memory footprint down.
final class AsrRuntime: @unchecked Sendable {
  static let shared = AsrRuntime()

  private let queue = DispatchQueue(label: "ai.scribe.qwenasr", qos: .userInitiated)
  private var handle: OpaquePointer?
  private var loadedKey = ""
  private var evict: DispatchWorkItem?

  private func scheduleEvict() {
    evict?.cancel()
    let w = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if let h = self.handle { cllama_asr_free(h) }
      self.handle = nil
      self.loadedKey = ""
      dlog("qwen-asr evicted after idle")
    }
    evict = w
    queue.asyncAfter(deadline: .now() + 30, execute: w)
  }

  /// Transcribes mono float PCM; `completion` on the main queue, nil on failure.
  func transcribe(modelPath: String, mmprojPath: String,
                  samples: [Float], sampleRate: Int,
                  completion: @escaping (String?) -> Void) {
    queue.async {
      let key = modelPath + "|" + mmprojPath
      if self.loadedKey != key || self.handle == nil {
        if let h = self.handle { cllama_asr_free(h) }
        self.handle = cllama_asr_load(modelPath, mmprojPath)
        self.loadedKey = self.handle != nil ? key : ""
      }
      guard let h = self.handle else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      var text: String?
      samples.withUnsafeBufferPointer { buf in
        if let c = cllama_asr_transcribe(h, buf.baseAddress, Int32(samples.count),
                                         Int32(sampleRate), 1024) {
          text = String(cString: c)
          cllama_free_str(c)
        }
      }
      self.scheduleEvict()
      DispatchQueue.main.async {
        completion(text.map(Self.cleanOutput))
      }
    }
  }

  func release(completion: (() -> Void)? = nil) {
    queue.async {
      if let h = self.handle { cllama_asr_free(h) }
      self.handle = nil
      self.loadedKey = ""
      if let completion { DispatchQueue.main.async(execute: completion) }
    }
  }

  /// Qwen3-ASR wraps its transcript in a structured header,
  /// "language …<asr_text>the text</asr_text>". Keep only the text.
  static func cleanOutput(_ raw: String) -> String {
    var s = raw
    if let r = s.range(of: "<asr_text>") { s = String(s[r.upperBound...]) }
    if let r = s.range(of: "</asr_text>") { s = String(s[..<r.lowerBound]) }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
