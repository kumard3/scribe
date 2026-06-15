import SwiftUI
import AppKit
import AVFoundation
import Speech

/// First-launch setup: welcome → permissions → hotkey + live test.
/// Shown by AppDelegate when Settings.onboarded is false; re-runnable from
/// the dashboard.
final class OnboardingController {
  static let shared = OnboardingController()
  private var window: NSWindow?

  func show() {
    if window == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
        styleMask: [.titled, .closable, .fullSizeContentView],
        backing: .buffered,
        defer: false
      )
      w.titlebarAppearsTransparent = true
      w.titleVisibility = .hidden
      w.isMovableByWindowBackground = true
      w.backgroundColor = .black
      w.isReleasedWhenClosed = false
      w.contentView = NSHostingView(rootView: OnboardingView { [weak w] in
        Settings.shared.onboarded = true
        w?.close()
      })
      w.center()
      window = w
    }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

private enum OMono {
  static let bg = Color.black
  static let surface = Color(red: 0.078, green: 0.078, blue: 0.086)
  static let border = Color(red: 0.165, green: 0.165, blue: 0.18)
  static let dim = Color(red: 0.604, green: 0.604, blue: 0.639)
}

struct OnboardingView: View {
  let onDone: () -> Void
  @State private var step = 0

  var body: some View {
    VStack(spacing: 0) {
      Spacer().frame(height: 36)
      switch step {
      case 0: WelcomeStep { step = 1 }
      case 1: PermissionsStep { step = 2 }
      default: HotkeyStep(onDone: onDone)
      }
      Spacer()
      HStack(spacing: 6) {
        ForEach(0..<3, id: \.self) { i in
          Circle()
            .fill(i == step ? Color.white : Color.white.opacity(0.25))
            .frame(width: 6, height: 6)
        }
      }
      .padding(.bottom, 24)
    }
    .frame(width: 520, height: 560)
    .background(OMono.bg)
    .preferredColorScheme(.dark)
  }
}

private struct WelcomeStep: View {
  let next: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      LogoMark(size: 76)
      Text("Welcome to Scribe")
        .font(.system(size: 28, weight: .bold))
        .foregroundColor(.white)
      Text("Hold a key, speak, release — your words land in any app.\nEverything is transcribed on this Mac.")
        .font(.system(size: 14))
        .foregroundColor(OMono.dim)
        .multilineTextAlignment(.center)
        .lineSpacing(4)
      Spacer().frame(height: 8)
      Button(action: next) {
        Text("Get started")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.black)
          .padding(.horizontal, 28)
          .padding(.vertical, 10)
          .background(Capsule().fill(Color.white))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 40)
  }
}

private struct PermissionsStep: View {
  let next: () -> Void
  @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
  @State private var speech = SFSpeechRecognizer.authorizationStatus() == .authorized
  @State private var ax = AXIsProcessTrusted()
  private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var allGranted: Bool { mic && speech && ax }

  var body: some View {
    VStack(spacing: 16) {
      Text("Permissions")
        .font(.system(size: 24, weight: .bold))
        .foregroundColor(.white)
      Text("Scribe needs three things to work everywhere.")
        .font(.system(size: 13))
        .foregroundColor(OMono.dim)

      VStack(spacing: 10) {
        permissionRow(
          granted: mic, title: "Microphone", detail: "To hear you speak"
        ) {
          AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { mic = ok }
          }
        }
        permissionRow(
          granted: speech, title: "Speech Recognition", detail: "Apple's on-device transcriber"
        ) {
          SFSpeechRecognizer.requestAuthorization { auth in
            DispatchQueue.main.async { speech = auth == .authorized }
          }
        }
        permissionRow(
          granted: ax, title: "Accessibility", detail: "Watches the hold key and pastes for you"
        ) {
          Paster.ensureAccessibility()
          NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
          )
        }
      }
      .padding(.horizontal, 36)

      Spacer().frame(height: 4)
      Button(action: next) {
        Text(allGranted ? "Continue" : "Continue anyway")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.black)
          .padding(.horizontal, 28)
          .padding(.vertical, 10)
          .background(Capsule().fill(Color.white))
      }
      .buttonStyle(.plain)
      if !ax {
        Text("Without Accessibility the hold key won’t work — only the toggle shortcut.")
          .font(.caption)
          .foregroundColor(OMono.dim)
      }
    }
    .onReceive(tick) { _ in
      mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
      speech = SFSpeechRecognizer.authorizationStatus() == .authorized
      ax = AXIsProcessTrusted()
    }
  }

  private func permissionRow(
    granted: Bool, title: String, detail: String, action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
        .font(.system(size: 20))
        .foregroundColor(granted ? .green : OMono.dim)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 14, weight: .medium)).foregroundColor(.white)
        Text(detail).font(.system(size: 11.5)).foregroundColor(OMono.dim)
      }
      Spacer()
      if !granted {
        Button("Grant", action: action)
          .font(.system(size: 12, weight: .medium))
      }
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 12).fill(OMono.surface))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OMono.border))
  }
}

private struct HotkeyStep: View {
  let onDone: () -> Void
  @ObservedObject var settings = Settings.shared
  @ObservedObject var dictation = DictationManager.shared

  var body: some View {
    VStack(spacing: 16) {
      Text("Pick your keys")
        .font(.system(size: 24, weight: .bold))
        .foregroundColor(.white)

      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text("HOLD TO TALK")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(OMono.dim)
            .kerning(1)
          Picker("", selection: $settings.holdKeyRaw) {
            ForEach(HoldKey.allCases) { k in Text(k.label).tag(k.rawValue) }
          }
          .labelsHidden()
          Text("Hold while speaking, release to insert. Quick tap = hands-free.")
            .font(.caption).foregroundColor(OMono.dim)
        }

        Divider().overlay(OMono.border)

        VStack(alignment: .leading, spacing: 6) {
          Text("TOGGLE SHORTCUT — CLICK TO SET ANY COMBO")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(OMono.dim)
            .kerning(1)
          ShortcutRecorder()
          Text("Press it once to start, again to stop. Works without Accessibility.")
            .font(.caption).foregroundColor(OMono.dim)
        }
      }
      .padding(16)
      .background(RoundedRectangle(cornerRadius: 12).fill(OMono.surface))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OMono.border))
      .padding(.horizontal, 36)
      .tint(.white)

      VStack(spacing: 6) {
        Text("Try it now — hold \(settings.holdKey.label) and say something")
          .font(.system(size: 12.5))
          .foregroundColor(OMono.dim)
        Text(dictation.isRecording
          ? "● Listening…"
          : (dictation.lastText.isEmpty ? " " : "“\(snippet(dictation.lastText))”"))
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(dictation.isRecording ? .red : .white)
          .lineLimit(2)
          .frame(minHeight: 34)
          .padding(.horizontal, 24)
      }

      Button(action: onDone) {
        Text("Finish")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.black)
          .padding(.horizontal, 28)
          .padding(.vertical, 10)
          .background(Capsule().fill(Color.white))
      }
      .buttonStyle(.plain)
    }
  }

  private func snippet(_ s: String) -> String {
    s.count > 90 ? String(s.prefix(90)) + "…" : s
  }
}
