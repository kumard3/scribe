import SwiftUI
import Carbon

enum HoldKey: String, CaseIterable, Identifiable {
  case fn, rightCommand, rightOption, rightControl, rightShift, off

  var id: String { rawValue }

  var label: String {
    switch self {
    case .fn: return "fn (Globe)"
    case .rightCommand: return "Right ⌘"
    case .rightOption: return "Right ⌥"
    case .rightControl: return "Right ⌃"
    case .rightShift: return "Right ⇧"
    case .off: return "Off"
    }
  }

  var keyCode: UInt16? {
    switch self {
    case .fn: return UInt16(kVK_Function)
    case .rightCommand: return UInt16(kVK_RightCommand)
    case .rightOption: return UInt16(kVK_RightOption)
    case .rightControl: return UInt16(kVK_RightControl)
    case .rightShift: return UInt16(kVK_RightShift)
    case .off: return nil
    }
  }

  var flag: NSEvent.ModifierFlags {
    switch self {
    case .fn: return .function
    case .rightCommand: return .command
    case .rightOption: return .option
    case .rightControl: return .control
    case .rightShift: return .shift
    case .off: return []
    }
  }
}

/// Human-readable name for a Carbon virtual key code (display only).
func keyName(_ code: UInt32) -> String {
  let names: [Int: String] = [
    kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
    kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
    kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
    kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
    kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
    kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
    kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
    kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
    kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
    kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
    kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
    kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
    kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
    kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
    kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
    kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
    kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
    kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
  ]
  return names[Int(code)] ?? "key \(code)"
}

/// Carbon modifier mask → display symbols.
func modifierSymbols(_ mods: UInt32) -> String {
  var s = ""
  if mods & UInt32(controlKey) != 0 { s += "⌃" }
  if mods & UInt32(optionKey) != 0 { s += "⌥" }
  if mods & UInt32(shiftKey) != 0 { s += "⇧" }
  if mods & UInt32(cmdKey) != 0 { s += "⌘" }
  return s
}

func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
  var mods: UInt32 = 0
  if flags.contains(.control) { mods |= UInt32(controlKey) }
  if flags.contains(.option) { mods |= UInt32(optionKey) }
  if flags.contains(.shift) { mods |= UInt32(shiftKey) }
  if flags.contains(.command) { mods |= UInt32(cmdKey) }
  return mods
}

enum ToggleHotkey: String, CaseIterable, Identifiable {
  case ctrlAltSpace, ctrlAltD, ctrlShiftSpace, f19, off

  var id: String { rawValue }

  var label: String {
    switch self {
    case .ctrlAltSpace: return "⌃⌥Space"
    case .ctrlAltD: return "⌃⌥D"
    case .ctrlShiftSpace: return "⌃⇧Space"
    case .f19: return "F19"
    case .off: return "Off"
    }
  }

  var keyCode: UInt32? {
    switch self {
    case .ctrlAltSpace, .ctrlShiftSpace: return UInt32(kVK_Space)
    case .ctrlAltD: return UInt32(kVK_ANSI_D)
    case .f19: return UInt32(kVK_F19)
    case .off: return nil
    }
  }

  var modifiers: UInt32 {
    switch self {
    case .ctrlAltSpace, .ctrlAltD: return UInt32(controlKey | optionKey)
    case .ctrlShiftSpace: return UInt32(controlKey | shiftKey)
    case .f19, .off: return 0
    }
  }
}

struct SpeechLanguage: Identifiable, Hashable {
  let code: String
  let label: String
  var id: String { code }
}

let speechLanguages: [SpeechLanguage] = [
  .init(code: "auto", label: "Auto-detect"),
  .init(code: "en", label: "English"),
  .init(code: "hi", label: "Hindi"),
  .init(code: "es", label: "Spanish"),
  .init(code: "fr", label: "French"),
  .init(code: "de", label: "German"),
  .init(code: "pt", label: "Portuguese"),
  .init(code: "it", label: "Italian"),
  .init(code: "nl", label: "Dutch"),
  .init(code: "ru", label: "Russian"),
  .init(code: "ar", label: "Arabic"),
  .init(code: "tr", label: "Turkish"),
  .init(code: "id", label: "Indonesian"),
  .init(code: "zh", label: "Chinese"),
  .init(code: "ja", label: "Japanese"),
  .init(code: "ko", label: "Korean"),
  .init(code: "bn", label: "Bengali"),
  .init(code: "ta", label: "Tamil"),
  .init(code: "te", label: "Telugu"),
  .init(code: "mr", label: "Marathi"),
  .init(code: "gu", label: "Gujarati"),
  .init(code: "kn", label: "Kannada"),
  .init(code: "ml", label: "Malayalam"),
  .init(code: "pa", label: "Punjabi"),
  .init(code: "ur", label: "Urdu"),
]

// Whisper's own language detection misfires on accented speech — it will read
// accented English as Hindi/Urdu and emit garbage — so default to the Mac's language.
func defaultSpeechLanguage() -> String {
  let code = Locale.current.language.languageCode?.identifier ?? ""
  return speechLanguages.contains { $0.code == code } ? code : "auto"
}

final class Settings: ObservableObject {
  static let shared = Settings()

  @AppStorage("holdKey") var holdKeyRaw: String = HoldKey.fn.rawValue {
    willSet { objectWillChange.send() }
  }
  @AppStorage("toggleKeyCode") var toggleKeyCode: Int = kVK_Space {
    willSet { objectWillChange.send() }
  }
  @AppStorage("toggleMods") var toggleMods: Int = Int(controlKey | optionKey) {
    willSet { objectWillChange.send() }
  }
  @AppStorage("tapHandsFree") var tapHandsFree: Bool = true {
    willSet { objectWillChange.send() }
  }
  @AppStorage("restoreClipboard") var restoreClipboard: Bool = false {
    willSet { objectWillChange.send() }
  }
  @AppStorage("saveHistory") var saveHistory: Bool = true {
    willSet { objectWillChange.send() }
  }
  @AppStorage("activeModel") var activeModelId: String = ModelCatalog.systemId {
    willSet { objectWillChange.send() }
  }
  @AppStorage("language") var language: String = defaultSpeechLanguage() {
    willSet { objectWillChange.send() }
  }
  @AppStorage("useGpu") var useGpu: Bool = false {
    willSet { objectWillChange.send() }
  }
  @AppStorage("romanizeHindi") var romanizeHindi: Bool = true {
    willSet { objectWillChange.send() }
  }

  // sherpa-onnx execution provider. "coreml" needs a CoreML-enabled build; on a
  // CPU-only lib sherpa logs a warning and falls back to CPU, so this is safe.
  var sherpaProvider: String { useGpu ? "coreml" : "cpu" }
  @AppStorage("autoCleanLLM") var autoCleanLLM: Bool = false {
    willSet { objectWillChange.send() }
  }
  @AppStorage("onboardedV1") var onboarded: Bool = false {
    willSet { objectWillChange.send() }
  }

  private init() {
    // migrate from the old preset-enum storage
    if let old = UserDefaults.standard.string(forKey: "toggleHotkey"),
       let preset = ToggleHotkey(rawValue: old) {
      toggleKeyCode = preset.keyCode.map(Int.init) ?? -1
      toggleMods = Int(preset.modifiers)
      UserDefaults.standard.removeObject(forKey: "toggleHotkey")
    }
  }

  var activeModel: ModelSpec {
    ModelCatalog.spec(activeModelId) ?? ModelCatalog.all[0]
  }

  var holdKey: HoldKey {
    get { HoldKey(rawValue: holdKeyRaw) ?? .fn }
    set { holdKeyRaw = newValue.rawValue }
  }

  /// "⌃⌥Space" — or "Off" when disabled.
  var toggleLabel: String {
    toggleKeyCode < 0
      ? "Off"
      : modifierSymbols(UInt32(toggleMods)) + keyName(UInt32(toggleKeyCode))
  }

  func setToggle(keyCode: Int, mods: Int) {
    toggleKeyCode = keyCode
    toggleMods = mods
    HotKeyManager.shared.apply(keyCode: keyCode, mods: mods)
  }
}
