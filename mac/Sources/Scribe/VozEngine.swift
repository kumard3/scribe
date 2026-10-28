import Foundation
import Voz
import Who

/// Desert Ant Labs Voz on Core ML, in-process. English plus 24 European languages, no Hindi.
actor VozEngine {
  static let shared = VozEngine()

  struct TimedWord {
    let text: String
    let start: Double
    let end: Double
  }

  nonisolated static var downloaded: Bool { Voz.isDownloaded() }
  nonisolated static var cacheDir: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("desert-ant-models", isDirectory: true)
  }

  private var voz: Voz?

  func prepare(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
    _ = try await ready(progress: progress)
  }

  func transcribe(_ samples: [Float], sampleRate: Int, vocabulary: [String]) async throws
    -> (text: String, words: [TimedWord])
  {
    let audio = SileroVAD.resampleTo16k(samples, from: sampleRate)
    guard !audio.isEmpty else { return ("", []) }
    let result = try await ready().transcribe(samples: audio, vocabulary: vocabulary)
    dlog("voz: \(String(format: "%.1f", result.duration)) s audio in \(String(format: "%.2f", result.processingTime)) s")
    return (
      result.text.trimmingCharacters(in: .whitespacesAndNewlines),
      result.words.map { TimedWord(text: $0.text.trimmingCharacters(in: .whitespaces), start: $0.start, end: $0.end) }
    )
  }

  func release() { voz = nil }

  private func ready(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Voz {
    if let voz { return voz }
    dlog("voz: loading (downloads on first use)")
    let loaded = try await Voz(progress: { progress($0.fraction) })
    voz = loaded
    dlog("voz: ready")
    return loaded
  }
}

/// Desert Ant Labs Who speaker turns for a whole track. Blocking.
enum WhoDiarizer {
  static var downloaded: Bool { Who.isDownloaded() }

  static func diarize(samples: [Float]) -> [SpeakerSegment]? {
    let done = DispatchSemaphore(value: 0)
    var out: [SpeakerSegment]?
    Task.detached {
      do {
        let result = try await Who().diarize(samples: samples, sampleRate: Double(TranscriptionLimits.sampleRate))
          .keepingSpeakers(minimumShare: 0.05)
        var end = 0.0
        out = result.turns.sorted { $0.start < $1.start }.compactMap { turn in
          let start = max(turn.start, end)
          guard turn.end - start > 0.2 else { return nil }
          end = turn.end
          return SpeakerSegment(start: start, end: turn.end, speaker: turn.speaker)
        }
      } catch {
        dlog("who diarize failed: \(error.localizedDescription)")
      }
      done.signal()
    }
    done.wait()
    return out.flatMap { $0.isEmpty ? nil : $0 }
  }
}
