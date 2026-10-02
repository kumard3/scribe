import AppKit
import SwiftUI

/// Recording island that wraps the MacBook notch (or sits top-center on screens without one):
/// red dot + timer left, live You/Others waveforms and Stop right. A click opens the Recorder.
final class NotchHUD: ObservableObject {
  static let shared = NotchHUD()
  @Published private(set) var hiddenByUser = false
  private var panel: NSPanel?

  private var recording: Bool { MeetingRecorder.shared.isRecording || ScreenRecorder.shared.isRecording }

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

  private func show() {
    guard let screen = NSScreen.main else { return }
    let layout = NotchLayout(screen: screen)
    if panel == nil {
      let p = NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
      )
      p.level = .statusBar
      p.isOpaque = false
      p.backgroundColor = .clear
      p.hasShadow = false
      p.becomesKeyOnlyIfNeeded = true
      p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
      panel = p
    }
    panel?.contentView = FirstClickHost(
      rootView: NotchHUDView(meeting: MeetingRecorder.shared, screen: ScreenRecorder.shared, layout: layout)
    )
    panel?.setFrame(layout.frame, display: true)
    panel?.orderFrontRegardless()
  }
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
  let layout: NotchLayout

  var body: some View {
    HStack(spacing: 0) {
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
      .frame(width: NotchLayout.side)

      if layout.hasNotch { Spacer().frame(width: layout.notchWidth) }

      HStack(spacing: 8) {
        if meeting.isRecording {
          TrackWave(icon: "person.fill", level: meeting.youLevel)
          TrackWave(icon: "speaker.wave.2.fill", level: meeting.othersLevel)
        }
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
      .frame(width: NotchLayout.side)
    }
    .frame(width: layout.frame.width, height: layout.frame.height)
    .contentShape(Rectangle())
    .onTapGesture { RecorderPanel.shared.show() }
    .help("Open the Recorder")
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
