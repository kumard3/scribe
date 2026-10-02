import AppKit
import CoreAudio
import SwiftUI

/// Notices a call app (or a browser, for Meet) opening the mic and offers to record the meeting.
@available(macOS 14.4, *)
final class CallDetector {
  static let shared = CallDetector()
  private var timer: Timer?
  private var asked: Set<String> = []

  private static let apps: [(prefix: String, name: String)] = [
    ("us.zoom", "Zoom"), ("com.microsoft.teams", "Teams"), ("com.apple.FaceTime", "FaceTime"),
    ("com.apple.avconferenced", "FaceTime"), ("com.tinyspeck.slackmacgap", "Slack"), ("com.hnc.Discord", "Discord"),
    ("net.whatsapp", "WhatsApp"), ("ru.keepcoder.Telegram", "Telegram"), ("com.cisco", "Webex"),
    ("Cisco-Systems.Spark", "Webex"), ("com.google.Chrome", "Chrome"), ("company.thebrowser", "Arc"),
    ("com.apple.Safari", "Safari"), ("com.apple.WebKit.GPU", "Safari"), ("com.microsoft.edgemac", "Edge"),
    ("com.brave.Browser", "Brave"), ("org.mozilla.firefox", "Firefox"),
  ]

  // ponytail: 3 s poll of the process list; a property listener would react instantly if that ever matters.
  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
  }

  private func poll() {
    let live = Set(Self.micUsers().compactMap { id in Self.apps.first { id.hasPrefix($0.prefix) }?.name })
    asked.formIntersection(live)
    if MeetingRecorder.shared.isRecording || !Settings.shared.askToRecordCalls {
      asked.formUnion(live)
      return
    }
    guard let app = live.subtracting(asked).sorted().first else { return }
    asked.insert(app)
    dlog("call detected: \(app)")
    CallPrompt.shared.show(app: app)
  }

  static func micUsers() -> [String] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
      var property = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
      )
      var running: UInt32 = 0
      var length = UInt32(MemoryLayout<UInt32>.size)
      guard AudioObjectGetPropertyData(id, &property, 0, nil, &length, &running) == noErr, running != 0 else { return nil }
      property.mSelector = kAudioProcessPropertyBundleID
      var bundle: Unmanaged<CFString>?
      length = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      guard AudioObjectGetPropertyData(id, &property, 0, nil, &length, &bundle) == noErr else { return nil }
      return bundle?.takeRetainedValue() as String?
    }
  }
}

/// Top-right card: "Zoom is using your mic. Record this meeting?" Hides itself after 20 s.
final class CallPrompt {
  static let shared = CallPrompt()
  private var panel: NSPanel?
  private var hideWork: DispatchWorkItem?

  func show(app: String) {
    guard let screen = NSScreen.main else { return }
    let size = NSSize(width: 340, height: 92)
    if panel == nil {
      let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      p.level = .statusBar
      p.isOpaque = false
      p.backgroundColor = .clear
      p.hasShadow = true
      p.becomesKeyOnlyIfNeeded = true
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel = p
    }
    panel?.contentView = FirstClickHost(rootView: CallPromptView(app: app) { [weak self] record in
      self?.hide()
      if record { MeetingRecorder.shared.start() }
    })
    let frame = screen.visibleFrame
    panel?.setFrame(NSRect(x: frame.maxX - size.width - 14, y: frame.maxY - size.height - 10, width: size.width, height: size.height), display: true)
    panel?.orderFrontRegardless()
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.hide() }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
  }

  func hide() { panel?.orderOut(nil) }
}

struct CallPromptView: View {
  let app: String
  let onChoice: (Bool) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "record.circle")
        .font(.system(size: 20)).foregroundColor(Color(hex: 0xFF453A))
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(app) is using your mic").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
          Text("Record this meeting with Bolkit?").font(.system(size: 12)).foregroundColor(Mono.textDim)
        }
        HStack(spacing: 8) {
          Button { onChoice(true) } label: {
            Text("Record").font(.system(size: 12, weight: .semibold)).foregroundColor(.black)
              .padding(.horizontal, 14).padding(.vertical, 5)
              .background(Capsule().fill(Color.white))
          }
          Button { onChoice(false) } label: {
            Text("Not now").font(.system(size: 12)).foregroundColor(Mono.textDim)
              .padding(.horizontal, 10).padding(.vertical, 5)
          }
        }
        .buttonStyle(.plain)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x1C1C1F)))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Mono.border))
  }
}
