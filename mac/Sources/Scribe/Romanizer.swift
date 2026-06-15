import Foundation

/// Devanagari → Latin "Hinglish" romanization for the Roman Hindi mode.
/// Apple's hi-IN transcribes to Devanagari; this converts it to readable
/// Latin script. It's phonetic, not perfect — English words come back
/// spelled by sound (office→ophis) since their identity is lost in Devanagari.
enum Romanizer {
  static func hinglish(_ s: String) -> String {
    guard !s.isEmpty else { return s }
    var latin = transform(s, kCFStringTransformToLatin)
    // anusvāra / chandrabindu nasal → "n" (mēṁ→men, maiṁ→main, nahīṁ→nahin)
    for ch in ["ṁ", "ṃ", "ṅ", "ñ", "\u{0901}", "\u{0902}"] {
      latin = latin.replacingOccurrences(of: ch, with: "n")
    }
    latin = latin.replacingOccurrences(of: "\u{0310}", with: "")

    // Hindi schwa deletion (approx): drop a word-final inherent 'a' after a
    // consonant — but not a long 'ā' — so "kala"→"kal", "jānā"→"jana".
    let vowels = Set("aeiouāēīōū")
    let trimmed = latin.split(separator: " ").map { tok -> String in
      var chars = Array(String(tok).precomposedStringWithCanonicalMapping)
      if chars.count >= 3, chars.last == "a", !vowels.contains(chars[chars.count - 2]) {
        chars.removeLast()
      }
      return String(chars)
    }.joined(separator: " ")

    return transform(trimmed, kCFStringTransformStripDiacritics)
  }

  private static func transform(_ s: String, _ t: CFString) -> String {
    let m = NSMutableString(string: s) as CFMutableString
    var range = CFRange(location: 0, length: CFStringGetLength(m))
    CFStringTransform(m, &range, t, false)
    return m as String
  }
}
