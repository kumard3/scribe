import Foundation

enum FlowPhase: String, Codable {
  case off, idle, listening, transcribing
}

struct FlowState: Codable {
  var phase = FlowPhase.off
  var beat = Date.distantPast
  var resultID: String?
  var resultText: String?
  var resultRequest: String?
  var resultAt: Date?
  var error: String?

  var alive: Bool { phase != .off && Date().timeIntervalSince(beat) < 6 }
}

struct FlowRequest: Codable {
  var id: String
  var action: String
  var at: Date
}

/// App, keyboard and widget talk through JSON files in the App Group. Any process can post a
/// Darwin notification, so it is only a wake-up: the engine acts on a fresh request file, which
/// only holders of the App Group entitlement can write.
enum FlowShared {
  static let group = "group.ai.localvoice.app"
  static let start = "ai.localvoice.app.flow.start"
  static let stop = "ai.localvoice.app.flow.stop"
  static let cancel = "ai.localvoice.app.flow.cancel"
  static let changed = "ai.localvoice.app.flow.changed"

  static var directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
  private static var url: URL? { directory?.appendingPathComponent("flow.json") }
  private static var requestURL: URL? { directory?.appendingPathComponent("request.json") }

  /// Writes a request for `action` (a notification name) and wakes the app. Returns the request id.
  @discardableResult
  static func request(_ action: String) -> String {
    let request = FlowRequest(id: UUID().uuidString, action: action, at: Date())
    if let requestURL, let data = try? JSONEncoder().encode(request) { try? data.write(to: requestURL, options: .atomic) }
    post(action)
    return request.id
  }

  /// Consumes a fresh request for `action`, or returns nil when there is none.
  static func takeRequest(_ action: String, within seconds: TimeInterval = 5) -> String? {
    guard let requestURL, let data = try? Data(contentsOf: requestURL),
          let request = try? JSONDecoder().decode(FlowRequest.self, from: data),
          request.action == action, abs(request.at.timeIntervalSinceNow) < seconds else { return nil }
    try? FileManager.default.removeItem(at: requestURL)
    return request.id
  }

  static func read() -> FlowState {
    guard let url, let data = try? Data(contentsOf: url),
          let state = try? JSONDecoder().decode(FlowState.self, from: data) else { return FlowState() }
    return state
  }

  static func write(_ state: FlowState) {
    guard let url, let data = try? JSONEncoder().encode(state) else { return }
    try? data.write(to: url, options: .atomic)
  }

  static func post(_ name: String) {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true
    )
  }

  private static var handlers: [String: () -> Void] = [:]

  static func observe(_ name: String, _ handler: @escaping () -> Void) {
    let registered = handlers[name] != nil
    handlers[name] = handler
    if registered { return }
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), nil,
      { _, _, name, _, _ in
        guard let key = name?.rawValue as String? else { return }
        DispatchQueue.main.async { FlowShared.handlers[key]?() }
      },
      name as CFString, nil, .deliverImmediately
    )
  }
}
