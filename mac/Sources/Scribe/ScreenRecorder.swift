import AppKit
import ScreenCaptureKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Records what the Recorder's share choice names, with system audio and the mic, to an mp4
/// (macOS 15+). A meeting saves screen.mp4 (then screen-2.mp4…) in its folder; "Record screen"
/// on its own saves to ~/Movies/Bolkit.
///
/// Share choices: "none", "call" (the window Apple's model picks as the call), "display" (the one
/// under the pointer), "display:<id>", "window:<id>".
final class ScreenRecorder: NSObject, ObservableObject {
  static let shared = ScreenRecorder()

  static var supported: Bool {
    if #available(macOS 15, *) { return true }
    return false
  }

  static var folder: URL {
    FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Bolkit", isDirectory: true)
  }

  struct Item: Identifiable {
    let id: URL
    let date: Date
    let bytes: Int
  }

  @Published private(set) var isRecording = false
  @Published private(set) var elapsed: TimeInterval = 0
  @Published private(set) var target = ""
  @Published private(set) var choice = ""
  @Published private(set) var recordings: [Item] = []
  @Published var openRecording: URL?
  private(set) var standalone = false

  private var stream: SCStream?
  private var output: AnyObject?
  private var finishing: [(output: AnyObject, stream: SCStream)] = []
  private var url: URL?
  private var startedAt = Date()
  private var timer: Timer?
  private var generation = 0

  override init() {
    super.init()
    refreshRecordings()
  }

  var elapsedLabel: String {
    Duration.seconds(Int(elapsed)).formatted(.time(pattern: elapsed >= 3600 ? .hourMinuteSecond : .minuteSecond))
  }

  static func describe(_ choice: String) -> String {
    if choice == "none" { return "No screen" }
    if choice == "call" { return "The call window" }
    if choice.hasPrefix("window:") { return "A window" }
    let id = CGDirectDisplayID(choice.dropFirst("display:".count)) ?? 0
    return NSScreen.screens.first { $0.displayID == id }?.localizedName ?? "The screen under the pointer"
  }

  func refreshRecordings() {
    let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
    let files = (try? FileManager.default.contentsOfDirectory(
      at: Self.folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
    )) ?? []
    recordings = files.filter { $0.pathExtension == "mp4" && $0 != (isRecording ? url : nil) }.map { file in
      let values = try? file.resourceValues(forKeys: Set(keys))
      return Item(id: file, date: values?.creationDate ?? .distantPast, bytes: values?.fileSize ?? 0)
    }
    .sorted { $0.date > $1.date }
  }

  func toggle() {
    isRecording ? stop() : startStandalone(Settings.shared.screenShare)
  }

  private func startStandalone(_ choice: String) {
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    start(to: Self.folder.appendingPathComponent("Bolkit Screen \(stamp.string(from: Date())).mp4"), choice: choice, standalone: true)
  }

  func start(to url: URL, choice: String, standalone: Bool) {
    guard #available(macOS 15, *) else {
      DictationManager.shared.status = "Screen recording needs macOS 15 or later."
      return
    }
    guard !isRecording else { return }
    isRecording = true
    self.standalone = standalone
    self.url = url
    self.choice = choice
    target = ""
    startedAt = Date()
    elapsed = 0
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.elapsed = Date().timeIntervalSince(self.startedAt)
    }
    NotchHUD.shared.refresh()
    generation += 1
    let current = generation
    Task { @MainActor in
      do {
        try await self.capture(to: url, generation: current)
      } catch {
        if current == self.generation { self.failed(error) }
      }
    }
  }

  func stop() {
    guard isRecording else { return }
    generation += 1
    isRecording = false
    timer?.invalidate()
    timer = nil
    endStream()
    NotchHUD.shared.refresh()
  }

  /// Picking another share while recording ends the running capture and starts a new clip with it.
  func switchTo(_ newChoice: String) {
    guard isRecording, standalone, newChoice != choice, newChoice != "none" else { return }
    stop()
    startStandalone(newChoice)
  }

  private func endStream() {
    guard let s = stream else { return }
    stream = nil
    retire(s, output)
  }

  // ScreenCaptureKit only removes its menu-bar stop button if the stream is still alive when the file finishes.
  private func retire(_ s: SCStream, _ out: AnyObject?) {
    if let out { finishing.append((out, s)) }
    Task { try? await s.stopCapture() }
  }

  private func finished(_ out: AnyObject) {
    finishing.removeAll { $0.output === out }
  }

  @available(macOS 15, *)
  @MainActor private func capture(to url: URL, generation current: Int) async throws {
    let filter = try await contentFilter(choice)
    let config = SCStreamConfiguration()
    // Native 5K h264 ran about 3 GB an hour; 2560 wide keeps text readable.
    let scale = min(CGFloat(filter.pointPixelScale), 2560 / max(filter.contentRect.width, 1))
    config.width = Int(filter.contentRect.width * scale)
    config.height = Int(filter.contentRect.height * scale)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.captureMicrophone = true

    let recording = SCRecordingOutputConfiguration()
    recording.outputURL = url
    recording.outputFileType = .mp4
    if recording.availableVideoCodecTypes.contains(.hevc) { recording.videoCodecType = .hevc }
    let out = SCRecordingOutput(configuration: recording, delegate: self)
    let s = SCStream(filter: filter, configuration: config, delegate: self)
    try s.addRecordingOutput(out)
    try await s.startCapture()
    // A stop or a newer start happened while this one was still starting up.
    guard current == generation, isRecording else {
      retire(s, out)
      return
    }
    stream = s
    output = out
    dlog("screen recording: \(target) \(config.width)x\(config.height)")
  }

  /// A window that has closed, or a call that isn't found, falls back to the screen under the pointer.
  @available(macOS 15, *)
  @MainActor private func contentFilter(_ choice: String) async throws -> SCContentFilter {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let window: SCWindow?
    if choice.hasPrefix("window:") {
      let id = CGWindowID(choice.dropFirst("window:".count))
      window = content.windows.first { $0.windowID == id }
    } else if choice == "call" {
      window = await MeetingWindow.find(in: content)
    } else {
      window = nil
    }
    if let window {
      target = MeetingWindow.label(window)
      return SCContentFilter(desktopIndependentWindow: window)
    }
    let wanted = CGDirectDisplayID(choice.dropFirst("display:".count))
    let pointer = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?.displayID
    guard let display = content.displays.first(where: { $0.displayID == wanted })
            ?? content.displays.first(where: { $0.displayID == pointer }) ?? content.displays.first else {
      throw CocoaError(.featureUnsupported)
    }
    target = NSScreen.screens.first { $0.displayID == display.displayID }?.localizedName ?? "Whole screen"
    let me = content.applications.filter { $0.processID == getpid() }
    return SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
  }

  private func failed(_ error: Error) {
    dlog("screen recording: \(error)")
    stream = nil
    output = nil
    if isRecording {
      isRecording = false
      timer?.invalidate()
      timer = nil
    }
    NotchHUD.shared.refresh()
    DictationManager.shared.status = (error as? SCStreamError)?.code == .userDeclined
      ? "Allow Bolkit under System Settings > Privacy & Security > Screen & System Audio Recording, then try again."
      : "Screen recording stopped: \(error.localizedDescription)"
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID? {
    deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  }
}

extension ScreenRecorder: SCStreamDelegate {
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    DispatchQueue.main.async { self.failed(error) }
  }
}

@available(macOS 15, *)
extension ScreenRecorder: SCRecordingOutputDelegate {
  func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
    DispatchQueue.main.async {
      self.finished(recordingOutput)
      if self.output === recordingOutput { self.output = nil }
      self.refreshRecordings()
      guard self.standalone, !self.isRecording, let url = self.url else { return }
      self.openRecording = url
      DashboardWindow.show(.screen)
    }
  }

  func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
    DispatchQueue.main.async {
      self.finished(recordingOutput)
      self.failed(error)
    }
  }
}

/// Finds the window holding a live call: a known call app if exactly one window matches,
/// otherwise Apple's on-device model picks from the window titles, then a keyword guess.
@available(macOS 15, *)
enum MeetingWindow {
  private static let callApps: Set<String> = [
    "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime",
    "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
  ]
  private static let browsers = [
    "com.google.Chrome", "company.thebrowser", "com.apple.Safari", "com.microsoft.edgemac",
    "com.brave.Browser", "org.mozilla.firefox", "com.operasoftware", "com.vivaldi",
  ]
  private static let keywords = ["meet", "zoom", "teams", "huddle", "webex", "facetime", "call"]

  static func label(_ w: SCWindow) -> String {
    "\(w.owningApplication?.applicationName ?? "App"): \(w.title ?? "")"
  }

  /// Real app windows worth offering: on screen, titled, not tiny, not Bolkit's own.
  static func candidates(_ content: SCShareableContent) -> [SCWindow] {
    content.windows.filter {
      $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width >= 320 && $0.frame.height >= 240
        && !($0.title ?? "").isEmpty && $0.owningApplication?.processID != getpid()
    }
  }

  static func find(in content: SCShareableContent) async -> SCWindow? {
    let windows = candidates(content)
    let calls = windows.filter { callApps.contains($0.owningApplication?.bundleIdentifier ?? "") }
    if calls.count == 1 { return calls[0] }
    // Web calls live in browser tabs; any other app's window (a terminal titled "meeting notes") is never the call.
    let web = windows.filter { w in browsers.contains { (w.owningApplication?.bundleIdentifier ?? "").hasPrefix($0) } }
    let pool = Array((calls.isEmpty ? web : calls).prefix(25))
    guard !pool.isEmpty else { return nil }
    if let i = await askModel(pool) { return pool.indices.contains(i) ? pool[i] : nil }
    return pool.first { w in keywords.contains { (w.title ?? "").localizedCaseInsensitiveContains($0) } }
  }

  /// nil when the model can't answer; -1 when it says none of the windows is a call.
  private static func askModel(_ windows: [SCWindow]) async -> Int? {
    #if canImport(FoundationModels)
    guard #available(macOS 26, *), MeetingLLM.appleAvailable, !windows.isEmpty else { return nil }
    let list = windows.enumerated().map { "\($0.offset + 1). \(label($0.element))" }.joined(separator: "\n")
    let session = LanguageModelSession(instructions: """
      You are given numbered Mac windows as "App: window title". Pick the one showing a live video call \
      or online meeting (Zoom, Google Meet, Teams, FaceTime, Slack huddle, Webex, Discord). \
      Reply with only its number, or 0 if none of them is a call.
      """)
    guard let reply = try? await session.respond(to: list).content,
          let n = reply.split(whereSeparator: { !$0.isNumber }).first.flatMap({ Int($0) }),
          (0...windows.count).contains(n) else { return nil }
    dlog("meeting window (apple): \(n == 0 ? "none" : label(windows[n - 1]))")
    return n - 1
    #else
    return nil
    #endif
  }
}
