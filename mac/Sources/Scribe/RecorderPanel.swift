import AppKit
import ScreenCaptureKit
import SwiftUI

/// The one place with every recording option: meeting or screen only, and what to share,
/// picked from live thumbnails. Opens from Record buttons and from a click on the island.
final class RecorderPanel: NSObject, ObservableObject, NSWindowDelegate {
  static let shared = RecorderPanel()
  enum Mode { case meeting, screen }

  @Published var mode = Mode.meeting
  private var window: NSWindow?

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
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func close() { window?.orderOut(nil) }

  func windowWillClose(_ notification: Notification) { window = nil }
}

/// Shareable screens and windows with small live thumbnails.
@available(macOS 15, *)
@MainActor
final class ShareSources: ObservableObject {
  struct Tile: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    var image: CGImage?
    var suggested = false
  }

  @Published private(set) var tiles: [Tile] = []
  @Published private(set) var loading = false
  @Published private(set) var denied = false

  func load() async {
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
      denied = true
      return
    }
    denied = false
    loading = true
    defer { loading = false }
    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
    async let call = MeetingWindow.find(in: content)
    var found: [(Tile, SCContentFilter)] = []
    for display in content.displays {
      let name = NSScreen.screens.first { $0.displayID == display.displayID }?.localizedName ?? "Display"
      found.append((Tile(id: "display:\(display.displayID)", title: name, subtitle: "Whole screen"),
                    SCContentFilter(display: display, excludingWindows: [])))
    }
    let windows = MeetingWindow.candidates(content)
    for window in windows.prefix(9) {
      found.append((Tile(id: "window:\(window.windowID)", title: window.owningApplication?.applicationName ?? "App",
                         subtitle: window.title ?? ""),
                    SCContentFilter(desktopIndependentWindow: window)))
    }
    tiles = found.map(\.0)
    for (i, (_, filter)) in found.enumerated() {
      let image = await Self.thumbnail(filter)
      if tiles.indices.contains(i) { tiles[i].image = image }
    }
    // Apple's model answers in a few seconds; its pick moves to the front as the suggested call.
    guard let call = await call else { return }
    let existing = tiles.firstIndex { $0.id == "window:\(call.windowID)" }
    let image = existing.flatMap { tiles[$0].image }
    if let existing { tiles.remove(at: existing) }
    var tile = Tile(id: "call", title: "Call window", subtitle: MeetingWindow.label(call), suggested: true)
    tile.image = image
    tiles.insert(tile, at: 0)
    if image == nil { tiles[0].image = await Self.thumbnail(SCContentFilter(desktopIndependentWindow: call)) }
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
      HStack {
        Text("SHARE").font(.system(size: 11, weight: .semibold)).kerning(1).foregroundColor(Mono.textFaint)
        if sources.loading { ProgressView().controlSize(.small) }
        Spacer()
        Button { Task { await sources.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
          .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Mono.textDim)
      }
      if sources.denied {
        Text("Allow Bolkit under System Settings > Privacy & Security > Screen & System Audio Recording to share a screen.")
          .font(.system(size: 12)).foregroundColor(Mono.textDim)
      }
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], alignment: .leading, spacing: 14) {
          if mode == .meeting {
            ShareTile(title: "No screen", subtitle: "Audio only", image: nil, icon: "waveform",
                      suggested: false, selected: selected == "none") { pick("none") }
          }
          ForEach(sources.tiles) { tile in
            ShareTile(title: tile.title, subtitle: tile.subtitle, image: tile.image, icon: "macwindow",
                      suggested: tile.suggested, selected: isSelected(tile.id)) { pick(tile.id) }
          }
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
    .task { await sources.load() }
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

  private func isSelected(_ id: String) -> Bool {
    if id == selected { return true }
    // "display" means the screen under the pointer; show it on that screen's tile.
    guard selected == "display", let pointer = NSScreen.screens.first(where: {
      NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
    })?.displayID else { return false }
    return id == "display:\(pointer)"
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
  let icon: String
  let suggested: Bool
  let selected: Bool
  let action: () -> Void

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
              .strokeBorder(selected ? Color(hex: 0xFF453A) : Mono.border, lineWidth: selected ? 2.5 : 1)
          )
          .overlay(alignment: .topLeading) {
            if suggested {
              Text("Suggested")
                .font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color(hex: 0xFF453A)))
                .padding(6)
            }
          }
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(Mono.text).lineLimit(1)
        Text(subtitle).font(.system(size: 11)).foregroundColor(Mono.textDim).lineLimit(1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
