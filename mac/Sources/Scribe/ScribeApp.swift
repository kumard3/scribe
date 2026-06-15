import SwiftUI
import AppKit

@main
struct ScribeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var dictation = DictationManager.shared

  init() {
    DebugCLI.runIfRequested()
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContent(dictation: dictation)
    } label: {
      Image(systemName: dictation.isRecording ? "waveform" : "mic")
    }
    .menuBarExtraStyle(.menu)

    Window("Scribe", id: "dashboard") {
      DashboardView()
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 600, height: 680)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var stoppedOnHoldPress = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    if Settings.shared.onboarded {
      Paster.ensureAccessibility() // prompts once so paste + hold-key monitor work
    } else {
      OnboardingController.shared.show()
    }

    HotKeyManager.shared.onTrigger = { DictationManager.shared.toggle() }
    HotKeyManager.shared.apply(
      keyCode: Settings.shared.toggleKeyCode, mods: Settings.shared.toggleMods
    )

    let hold = HoldKeyMonitor.shared
    hold.onPress = { [weak self] in
      let d = DictationManager.shared
      if d.isRecording {
        d.stop()
        self?.stoppedOnHoldPress = true
      } else {
        d.start()
        self?.stoppedOnHoldPress = false
      }
    }
    hold.onRelease = { [weak self] held in
      guard self?.stoppedOnHoldPress == false else { return }
      // held = push-to-talk; quick tap = hands-free (if enabled in dashboard)
      if held >= 0.4 || !Settings.shared.tapHandsFree {
        DictationManager.shared.stop()
      }
    }
    hold.start()
  }
}

struct MenuContent: View {
  @ObservedObject var dictation: DictationManager
  @ObservedObject var settings = Settings.shared
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Text(dictation.isRecording
      ? "● Listening…"
      : "Hold \(settings.holdKey.label) to dictate")

    if !dictation.lastText.isEmpty {
      Divider()
      Button("Paste last transcript") {
        Paster.insert(dictation.lastText)
      }
      Text(snippet(dictation.lastText))
        .foregroundColor(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: 320, alignment: .leading)
      Button("Copy last transcript") {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(dictation.lastText, forType: .string)
      }
    }

    Divider()
    // No .keyboardShortcut here: the Carbon hotkey already covers the combo
    // globally. Registering it on the menu item too made both fire when the
    // app was active — an instant start-then-stop that looked like a dead mic.
    Button(dictation.isRecording
      ? "Stop dictation (\(settings.toggleLabel))"
      : "Start dictation (\(settings.toggleLabel))") {
      dictation.toggle()
    }

    Button("Dashboard…") {
      openWindow(id: "dashboard")
      NSApp.activate(ignoringOtherApps: true)
    }

    Button("Setup guide…") {
      OnboardingController.shared.show()
    }

    if !AXIsProcessTrusted() {
      Button("Grant Accessibility (needed for hold-key + auto-paste)") {
        Paster.ensureAccessibility()
        NSWorkspace.shared.open(
          URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
      }
    }

    Text(dictation.status).font(.caption)

    Divider()
    Button("Quit Scribe") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }

  private func snippet(_ s: String) -> String {
    s.count > 64 ? String(s.prefix(64)) + "…" : s
  }
}
