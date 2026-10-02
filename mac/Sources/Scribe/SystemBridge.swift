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

  #if MAS
  // App Sandbox forbids the Accessibility-gated global monitor; a listen-only
  // tap needs Input Monitoring instead, and only exists once that is granted.
  func start() {
    guard monitor == nil else { return }
    // tapCreate itself raises the Input Monitoring prompt; only onboarding should ask.
    let tap = !CGPreflightListenEventAccess() ? nil : CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
      eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
      callback: { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<HoldKeyMonitor>.fromOpaque(info).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
          if let tap = me.monitor { CGEvent.tapEnable(tap: tap as! CFMachPort, enable: true) }
        } else if let e = NSEvent(cgEvent: event) {
          me.handle(e)
        }
        return Unmanaged.passUnretained(event)
      },
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    )
    guard let tap else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
      return
    }
    monitor = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
  }
  #else
  func start() {
    guard monitor == nil else { return }
    monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
      self?.handle(e)
    }
  }
  #endif

  private func handle(_ e: NSEvent) {
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

/// Inserts text at the caret. Writes straight into the focused field over the
/// Accessibility API when it will take it, and falls back to a Cmd-V paste
/// otherwise.
enum Paster {
  enum Outcome {
    /// Written into the field directly, clipboard untouched.
    case direct
    case pasted
    /// Left on the clipboard, with a reason to show the user.
    case copiedOnly(String)
  }

  #if MAS
  static let permissionName = "Accessibility and Input Monitoring"
  static var trusted: Bool { CGPreflightPostEventAccess() && CGPreflightListenEventAccess() }
  static var settingsURL: URL {
    let pane = CGPreflightPostEventAccess() ? "Privacy_ListenEvent" : "Privacy_Accessibility"
    return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
  }

  @discardableResult
  static func ensureAccessibility() -> Bool {
    let post = CGPreflightPostEventAccess() || CGRequestPostEventAccess()
    let listen = CGPreflightListenEventAccess() || CGRequestListenEventAccess()
    return post && listen
  }
  #else
  static let permissionName = "Accessibility"
  static var trusted: Bool { AXIsProcessTrusted() }
  static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

  @discardableResult
  static func ensureAccessibility() -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }
  #endif

  static func insert(_ text: String, done: ((Outcome) -> Void)? = nil) {
    guard !text.isEmpty else { return }

    #if MAS
    guard CGPreflightPostEventAccess() else {
      copyToPasteboard(text)
      dlog("insert: post-event not granted, copied only")
      done?(.copiedOnly("Copied to clipboard, grant Accessibility for auto-paste"))
      return
    }
    #else
    guard AXIsProcessTrusted() else {
      copyToPasteboard(text)
      dlog("insert: AX not trusted, copied only")
      done?(.copiedOnly("Copied to clipboard, grant Accessibility for auto-paste"))
      return
    }

    if let field = focusedField(), writeDirectly(text, into: field) {
      dlog("insert: wrote \(text.count) chars via AX")
      CorrectionWatcher.arm(field.element, inserted: text)
      // Leaving the transcript on the clipboard is the default behaviour and
      // the direct path never touches it, so put it there ourselves.
      if !Settings.shared.restoreClipboard { copyToPasteboard(text) }
      done?(.direct)
      return
    }
    #endif

    paste(text, done: done)
  }

  #if MAS
  private struct Field {}
  private static func focusedField() -> Field? { nil }
  private static func confirmPaste(_ field: Field?, count: Int, then: @escaping (Bool) -> Void) {
    then(true)
  }
  #else
  // MARK: - Accessibility path

  private struct Field {
    let element: AXUIElement
    let caret: CFRange
  }

  private static let axTimeout: Float = 0.5

  private static func focusedField() -> Field? {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, axTimeout)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      system, kAXFocusedUIElementAttribute as CFString, &ref
    ) == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }

    let element = unsafeBitCast(ref, to: AXUIElement.self)
    AXUIElementSetMessagingTimeout(element, axTimeout)
    // No readable caret means no way to tell an insert from a silent no-op,
    // and a wrong guess types the transcript twice.
    guard let caret = caret(of: element) else { return nil }
    return Field(element: element, caret: caret)
  }

  private static func caret(of element: AXUIElement) -> CFRange? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element, kAXSelectedTextRangeAttribute as CFString, &ref
    ) == .success, let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    var range = CFRange(location: 0, length: 0)
    guard AXValueGetValue(unsafeBitCast(ref, to: AXValue.self), .cfRange, &range) else { return nil }
    return range
  }

  private static func writeDirectly(_ text: String, into field: Field) -> Bool {
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(
      field.element, kAXSelectedTextAttribute as CFString, &settable
    ) == .success, settable.boolValue else { return false }

    guard AXUIElementSetAttributeValue(
      field.element, kAXSelectedTextAttribute as CFString, text as CFString
    ) == .success else { return false }

    guard let after = caret(of: field.element) else { return false }
    return insertLanded(before: field.caret, after: after, count: text.utf16.count)
  }
  #endif

  /// A field that took the text moves its caret to the end of it. Anything else
  /// that moved the caret still counts as landed: falling back after a partial
  /// insert would duplicate the transcript, which is worse than not verifying.
  static func insertLanded(before: CFRange, after: CFRange, count: Int) -> Bool {
    if after.location == before.location + count { return true }
    return after.location != before.location || after.length != before.length
  }

  // MARK: - Paste path

  private static func paste(_ text: String, done: ((Outcome) -> Void)?) {
    // Synthetic keystrokes are dropped while a password field holds the input,
    // so the paste would silently do nothing.
    guard !IsSecureEventInputEnabled() else {
      copyToPasteboard(text)
      dlog("insert: secure input active, copied only")
      done?(.copiedOnly("Password field, transcript copied, press Cmd-V"))
      return
    }

    let field = focusedField()
    let pb = NSPasteboard.general
    let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
      var byType: [NSPasteboard.PasteboardType: Data] = [:]
      for t in item.types {
        if let data = item.data(forType: t) { byType[t] = data }
      }
      return byType
    }
    copyToPasteboard(text)
    let ourChange = pb.changeCount

    // Apps read the pasteboard asynchronously; posting Cmd-V in the same tick
    // gets some of them the previous contents.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
      let src = CGEventSource(stateID: .combinedSessionState)
      let v = CGKeyCode(kVK_ANSI_V)
      let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
      down?.flags = .maskCommand
      let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
      up?.flags = .maskCommand
      down?.post(tap: .cghidEventTap)
      up?.post(tap: .cghidEventTap)
      dlog("insert: pasted \(text.count) chars")

      confirmPaste(field, count: text.utf16.count) { landed in
        if !landed {
          done?(.copiedOnly("Could not paste here, transcript copied, press Cmd-V"))
          return
        }
        done?(.pasted)
        #if !MAS
        if let field { CorrectionWatcher.arm(field.element, inserted: text) }
        #endif
        guard Settings.shared.restoreClipboard, !saved.isEmpty else { return }
        guard pb.changeCount == ourChange else { return }
        pb.clearContents()
        pb.writeObjects(saved.map { byType in
          let item = NSPasteboardItem()
          for (t, data) in byType { item.setData(data, forType: t) }
          return item
        })
      }
    }
  }

  #if !MAS
  private static func confirmPaste(
    _ field: Field?, count: Int, deadline: Int = 8, then: @escaping (Bool) -> Void
  ) {
    guard let field else { return then(true) }
    guard deadline > 0 else { return then(false) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      if let after = caret(of: field.element),
         insertLanded(before: field.caret, after: after, count: count) {
        return then(true)
      }
      confirmPaste(field, count: count, deadline: deadline - 1, then: then)
    }
  }
  #endif

  private static func copyToPasteboard(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
  }

  static func selfTest() {
    func r(_ loc: Int, _ len: Int) -> CFRange { CFRange(location: loc, length: len) }

    assert(insertLanded(before: r(10, 0), after: r(15, 0), count: 5))
    // Replacing a selection lands at the end of the new text.
    assert(insertLanded(before: r(10, 4), after: r(15, 0), count: 5))
    // A field that ignored the write leaves the caret exactly where it was.
    assert(!insertLanded(before: r(10, 0), after: r(10, 0), count: 5))
    assert(!insertLanded(before: r(0, 0), after: r(0, 0), count: 1))
    // Moved, but not by the amount asked for: still inserted, do not retry.
    assert(insertLanded(before: r(10, 0), after: r(13, 0), count: 5))
    assert(insertLanded(before: r(10, 0), after: r(10, 3), count: 5))
    print("Paster selftest ok")
  }
}
