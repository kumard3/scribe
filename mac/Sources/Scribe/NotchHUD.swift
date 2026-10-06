import AppKit
import SwiftUI

/// Where the island sits: wrapped around the notch, or a compact pill in a corner or at the
/// bottom, like Wispr Flow's bar. Dragging snaps it to the nearest spot, remembered across launches.
enum IslandDock: String, CaseIterable {
  case notch, topLeft, topRight, bottomLeft, bottomRight, bottom
}

/// Recording island: red dot + timer, live You/Others waveforms and Stop. A click opens the
/// Recorder; a drag moves it.
final class NotchHUD: ObservableObject {
  static let shared = NotchHUD()
  static let compactSize = NSSize(width: 214, height: 34)
  @Published private(set) var hiddenByUser = false
  @Published private(set) var compact = false
  private var panel: NSPanel?
  private var dragStart: (mouse: NSPoint, origin: NSPoint)?

  private var recording: Bool { MeetingRecorder.shared.isRecording || ScreenRecorder.shared.isRecording }

  private var dock: IslandDock {
    get { IslandDock(rawValue: UserDefaults.standard.string(forKey: "islandDock") ?? "") ?? .notch }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "islandDock") }
  }

  private var screen: NSScreen? {
    let id = UserDefaults.standard.integer(forKey: "islandScreen")
    return NSScreen.screens.first { $0.displayID.map(Int.init) == id } ?? NSScreen.main
  }

  func refresh() {
    guard recording else {
      hiddenByUser = false
      panel?.orderOut(nil)
      return
    }
    hiddenByUser ? panel?.orderOut(nil) : show()
  }

  func hide() {
    hiddenByUser = true
    panel?.orderOut(nil)
  }

  func unhide() {
    hiddenByUser = false
    refresh()
  }

  private func frame(for dock: IslandDock, on screen: NSScreen) -> NSRect {
    let notch = NotchLayout(screen: screen)
    if dock == .notch, notch.hasNotch { return notch.frame }
    let size = Self.compactSize, v = screen.visibleFrame, m: CGFloat = 12
    let origin: NSPoint
    switch dock {
    case .notch: origin = NSPoint(x: v.midX - size.width / 2, y: v.maxY - size.height - 6)
    case .topLeft: origin = NSPoint(x: v.minX + m, y: v.maxY - size.height - m)
    case .topRight: origin = NSPoint(x: v.maxX - size.width - m, y: v.maxY - size.height - m)
    case .bottomLeft: origin = NSPoint(x: v.minX + m, y: v.minY + m)
    case .bottomRight: origin = NSPoint(x: v.maxX - size.width - m, y: v.minY + m)
    case .bottom: origin = NSPoint(x: v.midX - size.width / 2, y: v.minY + m)
    }
    return NSRect(origin: origin, size: size)
  }

  private func show() {
    guard let screen else { return }
    let layout = NotchLayout(screen: screen)
    compact = !(dock == .notch && layout.hasNotch)
    if panel == nil {
      let p = IslandPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
      )
      p.level = .statusBar
      p.isOpaque = false
      p.backgroundColor = .clear
      p.hasShadow = false
      p.becomesKeyOnlyIfNeeded = true
      p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
      NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
        self?.holdPosition()
      }
      panel = p
    }
    panel?.contentView = FirstClickHost(
      rootView: NotchHUDView(meeting: MeetingRecorder.shared, screen: ScreenRecorder.shared, hud: self, layout: layout)
    )
    panel?.setFrame(frame(for: dock, on: screen), display: true)
    panel?.orderFrontRegardless()
  }

  /// macOS moved the island on its own (it landed mid-screen during calls); put it back.
  private func holdPosition() {
    guard dragStart == nil, let panel, panel.isVisible, let screen else { return }
    let want = frame(for: dock, on: screen)
    if abs(panel.frame.minX - want.minX) > 1 || abs(panel.frame.minY - want.minY) > 1 {
      panel.setFrame(want, display: true)
    }
  }

  func dragChanged() {
    guard let panel else { return }
    let mouse = NSEvent.mouseLocation
    if dragStart == nil {
      if !compact {
        compact = true
        let size = Self.compactSize
        panel.setFrame(NSRect(x: mouse.x - size.width / 2, y: panel.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
      }
      dragStart = (mouse, panel.frame.origin)
    }
    guard let start = dragStart else { return }
    panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
  }

  func dragEnded() {
    guard let panel else { return }
    dragStart = nil
    let mouse = NSEvent.mouseLocation
    guard let target = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? screen else { return }
    let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    func distance(_ d: IslandDock) -> CGFloat {
      let f = frame(for: d, on: target)
      return hypot(f.midX - center.x, f.midY - center.y)
    }
    dock = IslandDock.allCases.min { distance($0) < distance($1) } ?? .notch
    UserDefaults.standard.set(target.displayID.map(Int.init) ?? 0, forKey: "islandScreen")
    show()
  }
}

/// AppKit pushes windows out of the menu bar strip when a full-screen Space opens, which dropped
/// the island to the middle of the screen; the island belongs in that strip.
private final class IslandPanel: NSPanel {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The panel never becomes key, so without this the first click on Stop is swallowed.
final class FirstClickHost<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NotchLayout {
  let frame: NSRect
  let notchWidth: CGFloat
  let hasNotch: Bool

  static let side: CGFloat = 118

  init(screen: NSScreen) {
    let f = screen.frame
    let top = screen.safeAreaInsets.top
    if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
      hasNotch = true
      notchWidth = f.width - left.width - right.width
      let width = notchWidth + NotchLayout.side * 2
      frame = NSRect(x: f.midX - width / 2, y: f.maxY - top, width: width, height: top)
    } else {
      hasNotch = false
      notchWidth = 0
      let width = NotchLayout.side * 2 + 12
      frame = NSRect(x: f.midX - width / 2, y: screen.visibleFrame.maxY - 38, width: width, height: 32)
    }
  }
}

struct NotchHUDView: View {
  @ObservedObject var meeting: MeetingRecorder
  @ObservedObject var screen: ScreenRecorder
  @ObservedObject var hud: NotchHUD
  let layout: NotchLayout

  var body: some View {
    Group { hud.compact ? AnyView(compactPill) : AnyView(notchPill) }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 3)
          .onChanged { _ in hud.dragChanged() }
          .onEnded { _ in hud.dragEnded() }
      )
      .onTapGesture { RecorderPanel.shared.show() }
      .help("Click to open the Recorder, drag to move")
  }

  private var notchPill: some View {
    HStack(spacing: 0) {
      timer.frame(width: NotchLayout.side)
      if layout.hasNotch { Spacer().frame(width: layout.notchWidth) }
      HStack(spacing: 8) {
        waves
        stopButton
      }
      .frame(width: NotchLayout.side)
    }
    .frame(width: layout.frame.width, height: layout.frame.height)
    .background(
      Group {
        if layout.hasNotch {
          UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(Color.black)
        } else {
          Capsule().fill(Color.black.opacity(0.9))
        }
      }
    )
  }

  private var compactPill: some View {
    HStack(spacing: 8) {
      timer
      Spacer(minLength: 0)
      waves
      stopButton
    }
    .padding(.horizontal, 12)
    .frame(width: NotchHUD.compactSize.width, height: NotchHUD.compactSize.height)
    .background(Capsule().fill(Color.black.opacity(0.92)))
    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
  }

  private var timer: some View {
    HStack(spacing: 6) {
      Circle().fill(Color.red).frame(width: 8, height: 8)
      Text(meeting.isRecording ? meeting.elapsedLabel : screen.elapsedLabel)
        .font(.system(size: 12, weight: .semibold))
        .monospacedDigit()
        .foregroundColor(.white)
      if screen.isRecording {
        Image(systemName: "rectangle.dashed.badge.record")
          .font(.system(size: 9))
          .foregroundColor(.white.opacity(0.7))
      }
    }
  }

  @ViewBuilder
  private var waves: some View {
    if meeting.isRecording {
      TrackWave(icon: "person.fill", level: meeting.youLevel)
      TrackWave(icon: "speaker.wave.2.fill", level: meeting.othersLevel)
    }
  }

  private var stopButton: some View {
    Button { meeting.isRecording ? meeting.stop() : screen.stop() } label: {
      Image(systemName: "stop.fill")
        .font(.system(size: 7))
        .foregroundColor(.black)
        .frame(width: 17, height: 17)
        .background(Circle().fill(Color.white))
    }
    .buttonStyle(.plain)
    .help(meeting.isRecording ? "Stop and transcribe" : "Stop screen recording")
  }
}

/// Five bars that rise with the track's live level; flat when that side is silent.
private struct TrackWave: View {
  let icon: String
  let level: Float

  private let weights: [CGFloat] = [0.45, 0.8, 1.0, 0.7, 0.4]

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: icon)
        .font(.system(size: 8))
        .foregroundColor(.white.opacity(level > 0.02 ? 0.9 : 0.4))
      HStack(spacing: 2) {
        ForEach(0..<5, id: \.self) { i in
          Capsule()
            .fill(Color.white.opacity(level > 0.02 ? 1 : 0.35))
            .frame(width: 2.5, height: 3 + CGFloat(min(max(level, 0), 1)) * 13 * weights[i])
        }
      }
      .frame(height: 16)
      .animation(.easeOut(duration: 0.1), value: level)
    }
  }
}
