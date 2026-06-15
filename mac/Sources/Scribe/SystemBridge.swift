import AppKit
import Carbon
import ApplicationServices
import ServiceManagement

/// Global toggle hotkey via Carbon (works without Accessibility permission).
/// Re-registrable so the dashboard can change the combo.
final class HotKeyManager {
  static let shared = HotKeyManager()
  var onTrigger: (() -> Void)?

  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?

  func apply(keyCode: Int, mods: Int) {
    installHandlerIfNeeded()
    if let ref = hotKeyRef {
      UnregisterEventHotKey(ref)
      hotKeyRef = nil
    }
    guard keyCode >= 0 else { return }
    let id = EventHotKeyID(signature: OSType(0x53435242), id: 1) // 'SCRB'
    RegisterEventHotKey(UInt32(keyCode), UInt32(mods), id, GetApplicationEventTarget(), 0, &hotKeyRef)
  }

  private func installHandlerIfNeeded() {
    guard handlerRef == nil else { return }
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    InstallEventHandler(
      GetApplicationEventTarget(),
      { (_, _, userData) -> OSStatus in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue().onTrigger?()
        return noErr
      },
      1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
    )
  }
}

/// Wispr-style hold-key handling: hold = push-to-talk (release stops),
/// quick tap = hands-free toggle. The key is read from Settings at event
/// time, so dashboard changes apply immediately. Needs Accessibility.
final class HoldKeyMonitor {
  static let shared = HoldKeyMonitor()
  var onPress: (() -> Void)?
  var onRelease: ((TimeInterval) -> Void)?

  private var monitor: Any?
  private var downAt: Date?

  func start() {
    guard monitor == nil else { return }
    monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
      guard let self else { return }
      let key = Settings.shared.holdKey
      guard let keyCode = key.keyCode, e.keyCode == keyCode else { return }
      let isDown = e.modifierFlags.contains(key.flag)
      if isDown, downAt == nil {
        downAt = Date()
        onPress?()
      } else if !isDown, let at = downAt {
        downAt = nil
        onRelease?(Date().timeIntervalSince(at))
      }
    }
  }
}

enum LoginItem {
  static var enabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  static func set(_ on: Bool) {
    if on {
      try? SMAppService.mainApp.register()
    } else {
      try? SMAppService.mainApp.unregister()
    }
  }
}

/// Inserts text into the frontmost app via Cmd-V, then restores whatever was
/// on the clipboard before.
enum Paster {
  @discardableResult
  static func ensureAccessibility() -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  /// Returns true if a paste keystroke was sent; false means the text was
  /// only copied (Accessibility missing).
  @discardableResult
  static func insert(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    let pb = NSPasteboard.general
    let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
      var byType: [NSPasteboard.PasteboardType: Data] = [:]
      for t in item.types {
        if let data = item.data(forType: t) { byType[t] = data }
      }
      return byType
    }

    pb.clearContents()
    pb.setString(text, forType: .string)
    let ourChange = pb.changeCount

    // Cmd-V synthesis requires Accessibility. Without it the text stays on
    // the clipboard so the user can paste manually.
    guard AXIsProcessTrusted() else {
      dlog("insert: AX not trusted, copied only")
      return false
    }
    let src = CGEventSource(stateID: .combinedSessionState)
    let v = CGKeyCode(kVK_ANSI_V)
    let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
    down?.flags = .maskCommand
    let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
    dlog("insert: pasted \(text.count) chars")

    // The transcript stays on the clipboard by default — restoring the old
    // clipboard is opt-in, and skipped if anything else copied meanwhile.
    guard Settings.shared.restoreClipboard, !saved.isEmpty else { return true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      guard pb.changeCount == ourChange else { return }
      pb.clearContents()
      let items = saved.map { byType -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (t, data) in byType { item.setData(data, forType: t) }
        return item
      }
      pb.writeObjects(items)
    }
    return true
  }
}
