import AppKit
import ScreenCaptureKit
import SwiftUI

/// The one place with every recording option: meeting or screen only, and what to share,
/// picked from live thumbnails. Opens from Record buttons and from a click on the island.
final class RecorderPanel: NSObject, ObservableObject, NSWindowDelegate {
  static let shared = RecorderPanel()
  enum Mode { case meeting, screen }

  @Published var mode = Mode.meeting
  @Published private(set) var opens = 0
  private var window: NSWindow?

  var isOpen: Bool { window?.isVisible == true }

  func show(_ mode: Mode? = nil) {
    guard ScreenRecorder.supported else {
      if mode == .meeting || mode == nil { MeetingRecorder.shared.toggle() }
      return
    }
    if let mode { self.mode = mode }
    if window == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
      )
      w.title = "Bolkit Recorder"
      w.titlebarAppearsTransparent = true
      w.appearance = NSAppearance(named: .darkAqua)
      w.backgroundColor = .black
      w.isReleasedWhenClosed = false
      w.delegate = self
      if #available(macOS 15, *) { w.contentView = NSHostingView(rootView: RecorderView()) }
      w.center()
      window = w
    }
    if !isOpen { opens += 1 }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func close() {
    window?.orderOut(nil)
    ShareFrame.hover.hide()
  }

  func windowWillClose(_ notification: Notification) {
    window = nil
    ShareFrame.hover.hide()
  }
}

/// A border around a real display or window: white while a Recorder tile is hovered, red with a
/// pill while it is being recorded. Targets use the share-choice form, "display:<id>" or "window:<id>".
final class ShareFrame {
  static let hover = ShareFrame(recording: false)
  static let live = ShareFrame(recording: true)

  private let recording: Bool
  private var panel: NSPanel?
  private var timer: Timer?
  private(set) var target = ""

  private init(recording: Bool) { self.recording = recording }

  func show(_ target: String) {
    guard target != self.target else { return }
    hide()
    self.target = target
    place()
    guard target.hasPrefix("window:") else { return }
    let t = Timer(timeInterval: 0.33, repeats: true) { [weak self] _ in self?.place() }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  /// With `only`, hides just that target, so leaving one tile can't clear the next tile's border.
  func hide(_ only: String? = nil) {
    guard only == nil || only == target else { return }
    timer?.invalidate()
    timer = nil
    panel?.orderOut(nil)
    panel = nil
    target = ""
  }

  private static let pillHeight: CGFloat = 30

  private func place() {
    let isWindow = target.hasPrefix("window:")
    let frame: NSRect, top: CGFloat, above: Bool
    if isWindow, let id = CGWindowID(target.dropFirst("window:".count)), let f = Self.windowFrame(id) {
      let room = NSScreen.screens.first { $0.frame.intersects(f) }?.visibleFrame.maxY ?? .infinity
      above = recording && f.maxY + 4 + Self.pillHeight <= room
      let box = f.insetBy(dx: -4, dy: -4)
      frame = above ? NSRect(x: box.minX, y: box.minY, width: box.width, height: box.height + Self.pillHeight) : box
      top = above ? 0 : 10
    } else if !isWindow, let id = CGDirectDisplayID(target.dropFirst("display:".count)),
              let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
      frame = screen.frame
      top = screen.frame.maxY - screen.visibleFrame.maxY + 8
      above = false
    } else {
      panel?.orderOut(nil)
      return
    }
    let view = ShareFrameView(recording: recording, window: isWindow, top: top, pill: above ? Self.pillHeight : 0)
    let p = panel ?? makePanel(level: isWindow && recording ? .normal : .screenSaver)
    panel = p
    if let host = p.contentView as? NSHostingView<ShareFrameView> {
      if host.rootView != view { host.rootView = view }
    } else {
      p.contentView = NSHostingView(rootView: view)
    }
    if p.frame != frame { p.setFrame(frame, display: true) }
    if isWindow, recording, let id = Int(target.dropFirst("window:".count)) {
      p.order(.above, relativeTo: id)
    } else if !p.isVisible {
      p.orderFrontRegardless()
    }
  }

  private func makePanel(level: NSWindow.Level) -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.ignoresMouseEvents = true
    p.isReleasedWhenClosed = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    // A recorded window's border lives in its z-order, so windows stacked above it stay uncovered.
    p.level = level
    return p
  }

  /// CGWindowList bounds are top-left based from the primary display; Cocoa is bottom-left based.
  static func windowFrame(_ id: CGWindowID) -> NSRect? {
    guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
          info[kCGWindowIsOnscreen as String] as? Bool == true,
          let bounds = info[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: bounds),
          let primary = NSScreen.screens.first?.frame else { return nil }
    return NSRect(x: rect.minX, y: primary.maxY - rect.maxY, width: rect.width, height: rect.height)
  }
}

private struct ShareFrameView: View, Equatable {
  let recording: Bool
  let window: Bool
  let top: CGFloat
  let pill: CGFloat

  var body: some View {
    let color = recording ? Color(hex: 0xFF453A) : Color.white
    ZStack(alignment: .top) {
      RoundedRectangle(cornerRadius: window ? 12 : 0)
        .strokeBorder(color, lineWidth: 4)
        .padding(.top, recording ? pill : 0)
      if recording {
        HStack(spacing: 6) {
          Circle().fill(Color.white).frame(width: 7, height: 7)
          Text(window ? "Bolkit is recording this window" : "Bolkit is recording this screen")
        }
        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Capsule().fill(color))
        .padding(.top, top)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Shareable screens and windows. While the Recorder is open, thumbnails refresh every second
/// and the list every three, so windows that open or close show up without a refresh.
@available(macOS 15, *)
@MainActor
final class ShareSources: ObservableObject {
  struct Tile: Identifiable {
    let id: String
    let target: String
    let title: String
    let subtitle: String
    var icon: NSImage?
    var image: CGImage?
    var suggested = false
  }

  @Published private(set) var screens: [Tile] = []
  @Published private(set) var windows: [Tile] = []
  @Published private(set) var denied = false
  private var filters: [String: SCContentFilter] = [:]
  private var call: CGWindowID?

  func run(while open: @escaping () -> Bool) async {
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
      denied = true
      return
    }
    denied = false
    call = nil
    var asked = false
    var tick = 0
    repeat {
      if tick % 3 == 0, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
        list(content)
        if !asked {
          asked = true
          // Apple's model answers in a few seconds; ask once per open, not on every relist.
          Task {
            guard let window = await MeetingWindow.find(in: content) else { return }
            self.call = window.windowID
            self.list(content)
          }
        }
      }
      await refreshThumbnails()
      tick += 1
      try? await Task.sleep(for: .seconds(1))
    } while !Task.isCancelled && open()
  }

  private func list(_ content: SCShareableContent) {
    let me = content.applications.filter { $0.processID == getpid() }
    var filters: [String: SCContentFilter] = [:]
    let screens = content.displays.map { display in
      let target = "display:\(display.displayID)"
      filters[target] = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
      let name = NSScreen.screens.first { $0.displayID == display.displayID }?.localizedName ?? "Display"
      return Tile(id: target, target: target, title: name, subtitle: "\(display.width) x \(display.height)")
    }
    var windows = MeetingWindow.candidates(content).prefix(12).map { window in
      let target = "window:\(window.windowID)"
      filters[target] = SCContentFilter(desktopIndependentWindow: window)
      let pid = window.owningApplication?.processID
      return Tile(id: target, target: target, title: window.owningApplication?.applicationName ?? "App",
                  subtitle: window.title ?? "", icon: pid.flatMap { NSRunningApplication(processIdentifier: $0)?.icon })
    }
    if let call, let i = windows.firstIndex(where: { $0.target == "window:\(call)" }) {
      let tile = windows.remove(at: i)
      windows.insert(Tile(id: "call", target: tile.target, title: tile.title, subtitle: tile.subtitle,
                          icon: tile.icon, suggested: true), at: 0)
    }
    let old = Dictionary((self.screens + self.windows).map { ($0.target, $0.image) }, uniquingKeysWith: { a, _ in a })
    self.screens = screens.map { var t = $0; t.image = old[t.target] ?? nil; return t }
    self.windows = windows.map { var t = $0; t.image = old[t.target] ?? nil; return t }
    self.filters = filters
  }

  private func refreshThumbnails() async {
    var images: [String: CGImage] = [:]
    for (target, filter) in filters {
      if let image = await Self.thumbnail(filter) { images[target] = image }
    }
    guard !Task.isCancelled else { return }
    for i in screens.indices { screens[i].image = images[screens[i].target] ?? screens[i].image }
    for i in windows.indices { windows[i].image = images[windows[i].target] ?? windows[i].image }
  }

  private static func thumbnail(_ filter: SCContentFilter) async -> CGImage? {
    let config = SCStreamConfiguration()
    let rect = filter.contentRect
    config.width = 360
    config.height = max(1, Int(360 * rect.height / max(rect.width, 1)))
    config.showsCursor = false
    return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
  }
}

@available(macOS 15, *)
struct RecorderView: View {
  @ObservedObject var panel = RecorderPanel.shared
  @ObservedObject var meeting = MeetingRecorder.shared
  @ObservedObject var screen = ScreenRecorder.shared
  @ObservedObject var settings = Settings.shared
  @ObservedObject var hud = NotchHUD.shared
  @StateObject private var sources = ShareSources()

  private var recording: Bool { meeting.isRecording || screen.isRecording }
  private var mode: RecorderPanel.Mode { meeting.isRecording ? .meeting : screen.isRecording ? .screen : panel.mode }

  private var selected: String {
    if meeting.isRecording { return screen.isRecording && !screen.standalone ? screen.choice : "none" }
    if screen.isRecording { return screen.choice }
    return mode == .meeting ? settings.meetingShare : settings.screenShare
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      if sources.denied {
        Text("Allow Bolkit under System Settings > Privacy & Security > Screen & System Audio Recording to share a screen.")
          .font(.system(size: 12)).foregroundColor(Mono.textDim)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if mode == .meeting {
            grid {
              ShareTile(title: "No screen", subtitle: "Audio only", image: nil, appIcon: nil, icon: "waveform",
                        suggested: false, selected: selected == "none", live: false) { pick("none") }
            }
          }
          section("ENTIRE SCREEN", sources.screens, icon: "display")
          if !sources.windows.isEmpty { section("WINDOW", sources.windows, icon: "macwindow") }
        }
        .padding(2)
      }
      if meeting.isRecording {
        HStack(spacing: 18) {
          meter("You", meeting.youLevel)
          meter("This Mac", meeting.othersLevel)
        }
      }
      Text("Only record people who know and agree. Recordings stay on this Mac.")
        .font(.system(size: 11)).foregroundColor(Mono.textFaint)
      footer
    }
    .padding(.horizontal, 24)
    .padding(.top, 34)
    .padding(.bottom, 22)
    .frame(width: 600, height: 640)
    .background(Mono.bg)
    .tint(.white)
    .task(id: panel.opens) { await sources.run { RecorderPanel.shared.isOpen } }
  }

  private func grid(@ViewBuilder _ content: () -> some View) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], alignment: .leading, spacing: 14) {
      content()
    }
  }

  private func section(_ title: String, _ tiles: [ShareSources.Tile], icon: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.system(size: 11, weight: .semibold)).kerning(1).foregroundColor(Mono.textFaint)
        .padding(.top, 6)
      grid {
        ForEach(tiles) { tile in
          ShareTile(title: tile.title, subtitle: tile.subtitle, image: tile.image, appIcon: tile.icon, icon: icon,
                    suggested: tile.suggested, selected: isSelected(tile), live: screen.live == tile.target) {
            pick(tile.id)
          }
          .onHover { inside in inside ? ShareFrame.hover.show(tile.target) : ShareFrame.hover.hide(tile.target) }
        }
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      if recording {
        HStack(spacing: 10) {
          Circle().fill(Color(hex: 0xFF453A)).frame(width: 10, height: 10)
          Text(meeting.isRecording ? "Recording meeting" : "Recording screen")
            .font(.system(size: 20, weight: .bold)).foregroundColor(Mono.text)
          Text(meeting.isRecording ? meeting.elapsedLabel : screen.elapsedLabel)
            .font(.system(size: 20, weight: .light)).monospacedDigit().foregroundColor(Mono.textDim)
        }
      } else {
        Picker("", selection: $panel.mode) {
          Text("Meeting").tag(RecorderPanel.Mode.meeting)
          Text("Screen only").tag(RecorderPanel.Mode.screen)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 260)
      }
      Text(subtitle).font(.system(size: 12.5)).foregroundColor(Mono.textDim)
    }
  }

  private var subtitle: String {
    if screen.isRecording, !screen.target.isEmpty { return "Sharing \(screen.target). Pick another to switch." }
    if meeting.isRecording { return "Your mic and the call audio are recorded. Pick a screen to record with it." }
    return mode == .meeting
      ? "Your mic and everything this Mac plays are always recorded and transcribed. Pick a screen to record too, or none."
      : "Pick a screen or a window. Your mic and the Mac's sound are recorded with it."
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Button {
        if recording {
          meeting.isRecording ? meeting.stop() : screen.stop()
        } else {
          mode == .meeting ? meeting.start() : screen.toggle()
          RecorderPanel.shared.close()
        }
      } label: {
        Label(recording ? (meeting.isRecording ? "Stop and transcribe" : "Stop recording") : "Start recording",
              systemImage: recording ? "stop.fill" : "record.circle")
          .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 11)
          .background(Capsule().fill(Color(hex: 0xFF453A)))
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.defaultAction)
      if recording {
        Button(hud.hiddenByUser ? "Show island" : "Hide island") {
          hud.hiddenByUser ? hud.unhide() : hud.hide()
        }
        .font(.system(size: 12))
      }
    }
  }

  private func isSelected(_ tile: ShareSources.Tile) -> Bool {
    if screen.isRecording, let live = screen.live { return tile.target == live }
    if tile.id == selected { return true }
    // "display" means the screen under the pointer; show it on that screen's tile.
    guard selected == "display", let pointer = NSScreen.screens.first(where: {
      NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
    })?.displayID else { return false }
    return tile.target == "display:\(pointer)"
  }

  private func pick(_ id: String) {
    if meeting.isRecording {
      meeting.setScreen(id)
    } else if screen.isRecording {
      screen.switchTo(id)
    } else if mode == .meeting {
      settings.meetingShare = id
    } else {
      settings.screenShare = id
    }
  }

  private func meter(_ label: String, _ level: Float) -> some View {
    HStack(spacing: 8) {
      Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(Mono.textDim).frame(width: 54, alignment: .leading)
      GeometryReader { g in
        ZStack(alignment: .leading) {
          Capsule().fill(Mono.surfaceAlt)
          Capsule().fill(Color.white).frame(width: g.size.width * CGFloat(min(max(level, 0), 1)))
        }
      }
      .frame(height: 6)
      .animation(.easeOut(duration: 0.1), value: level)
    }
  }
}

private struct ShareTile: View {
  let title: String
  let subtitle: String
  let image: CGImage?
  let appIcon: NSImage?
  let icon: String
  let suggested: Bool
  let selected: Bool
  let live: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 6) {
        RoundedRectangle(cornerRadius: 10)
          .fill(Mono.surfaceAlt)
          .overlay {
            if let image {
              Image(decorative: image, scale: 1).resizable().scaledToFit().padding(4)
            } else {
              Image(systemName: icon).font(.system(size: 24)).foregroundColor(Mono.textFaint)
            }
          }
          .frame(height: 100)
          .overlay(
            RoundedRectangle(cornerRadius: 10)
              .strokeBorder(selected ? Color(hex: 0xFF453A) : hovering ? Mono.textDim : Mono.border,
                            lineWidth: selected ? 2.5 : hovering ? 1.5 : 1)
          )
          .overlay(alignment: .topLeading) {
            if suggested { badge("Suggested", dot: false) }
          }
          .overlay(alignment: .topTrailing) {
            if live { badge("Recording", dot: true) }
          }
        HStack(spacing: 6) {
          if let appIcon {
            Image(nsImage: appIcon).resizable().frame(width: 14, height: 14)
          }
          Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(Mono.text).lineLimit(1)
        }
        Text(subtitle).font(.system(size: 11)).foregroundColor(Mono.textDim).lineLimit(1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }

  private func badge(_ text: String, dot: Bool) -> some View {
    HStack(spacing: 4) {
      if dot { Circle().fill(Color.white).frame(width: 6, height: 6) }
      Text(text)
    }
    .font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
    .padding(.horizontal, 6).padding(.vertical, 2)
    .background(Capsule().fill(Color(hex: 0xFF453A)))
    .padding(6)
  }
}
