import SwiftUI
import AppKit
import Carbon

/// "Click, then press any key combo" capture field for the toggle shortcut.
/// Esc cancels. Plain keys need a modifier unless they're function keys.
struct ShortcutRecorder: View {
  @ObservedObject var settings = Settings.shared
  @State private var recording = false
  @State private var monitor: Any?
  @State private var hint = ""

  var body: some View {
    HStack(spacing: 8) {
      Button {
        recording ? stopRecording() : startRecording()
      } label: {
        Text(recording ? "Press keys… (⎋ to cancel)" : settings.toggleLabel)
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .frame(minWidth: 130)
          .background(
            RoundedRectangle(cornerRadius: 7)
              .fill(recording ? Color.white.opacity(0.18) : Color.white.opacity(0.07))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 7)
              .strokeBorder(recording ? Color.white : Color.white.opacity(0.2))
          )
      }
      .buttonStyle(.plain)

      if !recording && settings.toggleKeyCode >= 0 {
        Button("Off") {
          settings.setToggle(keyCode: -1, mods: 0)
        }
        .font(.system(size: 11))
      }
      if !hint.isEmpty {
        Text(hint).font(.caption).foregroundColor(.secondary)
      }
    }
    .onDisappear { stopRecording() }
  }

  private func startRecording() {
    recording = true
    hint = ""
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
      defer { stopRecording() }
      if e.keyCode == UInt16(kVK_Escape) { return nil }
      let mods = carbonModifiers(from: e.modifierFlags)
      let isFKey = (Int(e.keyCode) >= kVK_F1 && Int(e.keyCode) <= kVK_F12)
        || [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
          .contains(Int(e.keyCode))
      guard mods != 0 || isFKey else {
        hint = "Add a modifier (⌃⌥⇧⌘) — or use an F-key alone"
        return nil
      }
      settings.setToggle(keyCode: Int(e.keyCode), mods: Int(mods))
      return nil
    }
  }

  private func stopRecording() {
    recording = false
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
}
