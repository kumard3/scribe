import Foundation

/// Devanagari → Latin "Hinglish" romanization for the Roman Hindi mode.
/// Apple's hi-IN transcribes to Devanagari; this converts it to readable
/// Latin script. It's phonetic, not perfect — English words come back
/// spelled by sound (office→ophis) since their identity is lost in Devanagari.
enum Romanizer {
  /// Romanizes only the Devanagari words in mixed-script text, leaving
  /// English (or any Latin) untouched — hinglish()'s schwa-deletion would
  /// otherwise clip English words ("extra" → "extr").
  static func mixed(_ s: String) -> String {
    guard s.unicodeScalars.contains(where: { (0x0900...0x097F).contains($0.value) })
    else { return s }
    return s.split(separator: " ", omittingEmptySubsequences: false).map { tok in
      tok.unicodeScalars.contains(where: { (0x0900...0x097F).contains($0.value) })
        ? hinglish(String(tok))
        : String(tok)
    }.joined(separator: " ")
  }

  private static let vowels = Set("aeiouāēīōūaiau")

  static func hinglish(_ s: String) -> String {
    guard !s.isEmpty else { return s }
    var latin = transform(s, kCFStringTransformToLatin)

    // Nasals: anusvāra / chandrabindu → n. The combining candrabindu can land
    // after a base "m" (dabā'ēm̐), so map the m-combinations before stripping.
    for pair in [("m\u{0310}", "n"), ("ṁ", "n"), ("ṃ", "n"), ("ṅ", "n"), ("ñ", "n")] {
      latin = latin.replacingOccurrences(of: pair.0, with: pair.1)
    }
    latin = latin.replacingOccurrences(of: "\u{0310}", with: "n")
    // The transform separates adjacent vowels with an apostrophe (li'ē) —
    // pure noise in Hinglish.
    for apos in ["'", "\u{2019}", "\u{02BC}"] {
      latin = latin.replacingOccurrences(of: apos, with: "")
    }

    let words = latin.split(separator: " ", omittingEmptySubsequences: false).map { tok -> String in
      var chars = Array(String(tok).precomposedStringWithCanonicalMapping)

      // y-glide between vowel pairs, the way Hinglish is actually typed:
      // liē→liyē, dabāēn→dabāyēn, ki'ā→kiyā.
      var glided: [Character] = []
      for (idx, c) in chars.enumerated() {
        glided.append(c)
        if idx + 1 < chars.count,
           "iīāa".contains(c), "eēāa".contains(chars[idx + 1]), c != chars[idx + 1] {
          glided.append("y")
        }
      }
      chars = glided

      // Word-final inherent 'a' after a consonant first: kala→kal,
      // baṭana→baṭan — before the internal pass, so a doomed final 'a'
      // can't count as the "following vowel" for an internal deletion.
      if chars.count >= 3, chars.last == "a", !vowels.contains(chars[chars.count - 2]) {
        chars.removeLast()
      }
      // Hindi schwa deletion, right to left: drop an inherent 'a' between two
      // consonants when a vowel follows (isako→isko, badalane→badalne) —
      // never the word's first vowel (yahān stays yahān, nayā stays nayā).
      let firstVowel = chars.firstIndex(where: { vowels.contains($0) })
      var i = chars.count - 2
      while i > 0 {
        if chars[i] == "a", firstVowel.map({ i > $0 }) ?? false,
           !vowels.contains(chars[i - 1]),
           i + 1 < chars.count, !vowels.contains(chars[i + 1]),
           i + 2 < chars.count, vowels.contains(chars[i + 2]) {
          chars.remove(at: i)
        }
        i -= 1
      }
      return String(chars)
    }

    return transform(words.joined(separator: " "), kCFStringTransformStripDiacritics)
  }

  static func selfTest() {
    let got = mixed("अब इसको बदलने के लिए यहाँ एक नया बटन दबाएँ")
    assert(got == "ab isko badalne ke liye yahan ek naya batan dabayen",
           "romanizer: \(got)")
    assert(mixed("main कल office जाऊँगा") == "main kal office jaunga",
           "romanizer mixed: \(mixed("main कल office जाऊँगा"))")
    assert(mixed("plain english stays") == "plain english stays")
    print("Romanizer selftest ok")
  }

  private static func transform(_ s: String, _ t: CFString) -> String {
    let m = NSMutableString(string: s) as CFMutableString
    var range = CFRange(location: 0, length: CFStringGetLength(m))
    CFStringTransform(m, &range, t, false)
    return m as String
  }
}
