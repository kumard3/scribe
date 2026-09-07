import Foundation

/// Serializes ArkasrEngine work off the main thread and caches the loaded
/// sessions, evicting after idle. Mirrors AsrRuntime; the graphs hold a few
/// hundred MB resident so they should not linger.
final class ArkasrRuntime: @unchecked Sendable {
  static let shared = ArkasrRuntime()

  private let queue = DispatchQueue(label: "ai.scribe.arkasr", qos: .userInitiated)
  private var engine: OfflineAsrEngine?
  private var loadedId = ""

  /// Builds the engine that matches the bundle layout the spec ships.
  static func make(_ spec: ModelSpec) throws -> OfflineAsrEngine {
    let dir = ModelStore.dir(for: spec)
    switch spec.kind {
    case .arkOnnx: return try ArkEngine(dir: dir, config: spec.arkConfig)
    default: return try ArkasrEngine(dir: dir, config: spec.arkasrConfig)
    }
  }
  private var evict: DispatchWorkItem?

  private func scheduleEvict() {
    evict?.cancel()
    let w = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.engine = nil
      self.loadedId = ""
      dlog("arkasr evicted after idle")
    }
    evict = w
    queue.asyncAfter(deadline: .now() + 30, execute: w)
  }

  /// Transcribes mono float PCM; `completion` runs on the main queue.
  func transcribe(spec: ModelSpec, samples: [Float], sampleRate: Int,
                  completion: @escaping (Result<String, Error>) -> Void) {
    queue.async {
      do {
        if self.loadedId != spec.id || self.engine == nil {
          self.engine = nil
          let started = Date()
          self.engine = try Self.make(spec)
          self.loadedId = spec.id
          dlog("arkasr loaded \(spec.id) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
        guard let engine = self.engine else {
          throw Ort.Error(message: "\(spec.label) failed to load")
        }
        let text = try engine.transcribe(samples: samples, sampleRate: sampleRate)
        self.scheduleEvict()
        DispatchQueue.main.async { completion(.success(text)) }
      } catch {
        self.engine = nil
        self.loadedId = ""
        dlog("arkasr failed: \(error.localizedDescription)")
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }

  func release(completion: (() -> Void)? = nil) {
    queue.async {
      self.evict?.cancel()
      self.engine = nil
      self.loadedId = ""
      if let completion { DispatchQueue.main.async(execute: completion) }
    }
  }
}
