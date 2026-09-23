import AppKit
import SwiftUI

final class MeetingScreen: NSObject, NSWindowDelegate {
  static let shared = MeetingScreen()
  private var window: NSWindow?

  func show() {
    let meeting = MeetingRecorder.shared
    if !meeting.isRecording { meeting.start() }
    if window == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false
      )
      w.titlebarAppearsTransparent = true
      w.titleVisibility = .hidden
      w.backgroundColor = .black
      w.isReleasedWhenClosed = false
      w.collectionBehavior = [.fullScreenPrimary]
      w.delegate = self
      w.contentView = NSHostingView(rootView: MeetingScreenView(meeting: meeting) { [weak self] in
        MeetingRecorder.shared.stop()
        self?.close()
      })
      w.center()
      window = w
    }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if window?.styleMask.contains(.fullScreen) == false { window?.toggleFullScreen(nil) }
  }

  func close() {
    if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
    window?.orderOut(nil)
  }

  func windowWillClose(_ notification: Notification) { window = nil }
}

struct MeetingScreenView: View {
  @ObservedObject var meeting: MeetingRecorder
  let onStop: () -> Void

  var body: some View {
    VStack(spacing: 48) {
      Spacer()
      HStack(spacing: 14) {
        Circle().fill(meeting.isRecording ? Color.red : Mono.textFaint).frame(width: 16, height: 16)
        Text(meeting.isRecording ? "Recording" : "Stopped")
          .font(.system(size: 20, weight: .medium)).foregroundColor(Mono.textDim)
      }
      Text(meeting.elapsedLabel)
        .font(.system(size: 120, weight: .thin)).monospacedDigit().foregroundColor(.white)
      HStack(spacing: 80) {
        BigWave(label: "You", icon: "person.fill", level: meeting.youLevel)
        BigWave(label: "This Mac", icon: "speaker.wave.2.fill", level: meeting.othersLevel)
      }
      Text("Talking in person? Everyone is picked up by your mic and separated into speakers after you stop.")
        .font(.system(size: 14)).foregroundColor(Mono.textFaint)
      Button(action: onStop) {
        Text(meeting.isRecording ? "Stop and transcribe" : "Close")
          .font(.system(size: 16, weight: .semibold)).foregroundColor(.black)
          .padding(.horizontal, 36).padding(.vertical, 14)
          .background(Capsule().fill(Color.white))
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.escape, modifiers: [])
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
  }
}

private struct BigWave: View {
  let label: String
  let icon: String
  let level: Float

  private let weights: [CGFloat] = [0.3, 0.55, 0.8, 1.0, 0.85, 0.6, 0.35]

  var body: some View {
    let active = level > 0.02
    VStack(spacing: 16) {
      HStack(spacing: 6) {
        ForEach(weights.indices, id: \.self) { i in
          Capsule()
            .fill(Color.white.opacity(active ? 1 : 0.25))
            .frame(width: 10, height: 12 + CGFloat(min(max(level, 0), 1)) * 110 * weights[i])
        }
      }
      .frame(height: 130)
      .animation(.easeOut(duration: 0.1), value: level)
      Label(label, systemImage: icon)
        .font(.system(size: 15, weight: .medium))
        .foregroundColor(active ? .white : Mono.textDim)
    }
  }
}
