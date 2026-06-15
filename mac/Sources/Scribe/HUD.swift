import AppKit
import SwiftUI

/// Floating bottom-center pill shown while dictating: live level bars +
/// rolling partial transcript, then a brief "Inserted" confirmation.
final class HUD {
  static let shared = HUD()
  private var panel: NSPanel?

  func show() {
    if panel == nil { panel = makePanel() }
    position()
    panel?.orderFrontRegardless()
  }

  func hide(after delay: TimeInterval = 0) {
    guard delay > 0 else {
      panel?.orderOut(nil)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard !DictationManager.shared.isRecording else { return }
      self?.panel?.orderOut(nil)
    }
  }

  private func makePanel() -> NSPanel {
    let p = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 64),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    p.level = .statusBar
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.ignoresMouseEvents = true
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.contentView = NSHostingView(rootView: HUDView(dictation: DictationManager.shared))
    return p
  }

  private func position() {
    guard let p = panel, let screen = NSScreen.main else { return }
    let f = screen.visibleFrame
    p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 28))
  }
}

struct HUDView: View {
  @ObservedObject var dictation: DictationManager

  var body: some View {
    HStack(spacing: 12) {
      if dictation.phase == .inserted {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.green)
        Text("Inserted")
          .foregroundColor(.white)
      } else if dictation.phase == .transcribing {
        ProgressView()
          .controlSize(.small)
          .tint(.white)
        Text("Transcribing…")
          .foregroundColor(.white)
      } else {
        LevelBars(level: dictation.level)
        Text(tail(dictation.lastText.isEmpty ? "Listening…" : dictation.lastText))
          .lineLimit(1)
          .truncationMode(.head)
          .foregroundColor(.white)
      }
    }
    .font(.system(size: 14, weight: .medium))
    .padding(.horizontal, 20)
    .frame(height: 44)
    .background(Capsule().fill(Color.black.opacity(0.87)))
    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func tail(_ s: String) -> String {
    s.count > 58 ? "…" + String(s.suffix(58)) : s
  }
}

struct LevelBars: View {
  var level: Float

  var body: some View {
    HStack(spacing: 3) {
      ForEach(0..<5, id: \.self) { i in
        Capsule()
          .fill(Color.white)
          .frame(width: 3, height: barHeight(i))
      }
    }
    .frame(height: 26)
    .animation(.easeOut(duration: 0.09), value: level)
  }

  private func barHeight(_ i: Int) -> CGFloat {
    let weights: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]
    return 5 + CGFloat(min(max(level, 0), 1)) * 20 * weights[i]
  }
}
