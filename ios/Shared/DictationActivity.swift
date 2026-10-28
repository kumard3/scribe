import ActivityKit
import AppIntents
import Foundation

struct DictationActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var phase: FlowPhase
    var since: Date
  }
}

/// The Live Activity's Stop button. Ends the recording, or the whole session when idle.
@available(iOS 17.0, *)
struct FlowStopIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Stop Bolkit dictation"
  static let isDiscoverable = false

  func perform() async throws -> some IntentResult {
    let before = FlowShared.read().resultID
    FlowShared.request(FlowShared.stop)
    // Stay alive until the transcript lands: the clipboard write only works while an intent runs.
    for _ in 0..<40 {
      try? await Task.sleep(nanoseconds: 250_000_000)
      let state = FlowShared.read()
      if state.resultID != before || (state.phase != .listening && state.phase != .transcribing) { break }
    }
    return .result()
  }
}
