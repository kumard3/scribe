import Foundation

/// User vocabulary: names, jargon and acronyms the recognizer keeps getting
/// wrong. Terms bias transducer decoding directly and prime whisper.cpp.
enum Vocabulary {
  static var terms: [String] {
    Settings.shared.vocabulary
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// sherpa wants one term per line, tokens space-separated inside a term.
  static var hotwordsBuffer: String? {
    let list = terms
    guard !list.isEmpty else { return nil }
    return list.joined(separator: "\n")
  }

  /// The offline recognizer takes a path, not a buffer, so the terms are
  /// written out next to the models. Returns nil when there is nothing to bias.
  static func hotwordsFile() -> String? {
    guard let text = hotwordsBuffer else { return nil }
    let url = ModelStore.root.appendingPathComponent("hotwords.txt")
    do {
      try FileManager.default.createDirectory(
        at: ModelStore.root, withIntermediateDirectories: true
      )
      try text.write(to: url, atomically: true, encoding: .utf8)
      return url.path
    } catch {
      dlog("vocabulary: could not write hotwords file: \(error.localizedDescription)")
      return nil
    }
  }

  /// whisper.cpp has no hotword decoding, but it conditions on an initial
  /// prompt, which is enough to pull spellings toward known terms.
  static var whisperPrompt: String? {
    let list = terms
    guard !list.isEmpty else { return nil }
    return list.joined(separator: ", ")
  }

  static func add(_ term: String) {
    let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean.count <= 40 else { return }
    var list = terms
    guard !list.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else {
      return
    }
    list.append(clean)
    // Oldest terms fall off: an unbounded list slows beam search and drifts.
    if list.count > 200 { list.removeFirst(list.count - 200) }
    Settings.shared.vocabulary = list.joined(separator: "\n")
    dlog("vocabulary: learned \"\(clean)\" (\(list.count) terms)")
  }

  /// A correction is worth learning when the user replaced a short run of words
  /// inside text we just inserted, and the replacement is not a pure edit of
  /// punctuation or case.
  static func isLearnable(heard: String, corrected: String) -> Bool {
    let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
    let c = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !h.isEmpty, !c.isEmpty, h != c else { return false }
    guard c.count <= 40, c.split(whereSeparator: \.isWhitespace).count <= 3 else { return false }
    guard h.lowercased() != c.lowercased() else { return false }
    return c.rangeOfCharacter(from: .letters) != nil
  }

  static func selfTest() {
    assert(isLearnable(heard: "kumar deepanshu", corrected: "Kumar Deepanshu") == false)
    assert(isLearnable(heard: "assist able", corrected: "Assistable"))
    assert(isLearnable(heard: "sherpa", corrected: "sherpa") == false)
    assert(isLearnable(heard: "foo", corrected: "") == false)
    // Too long to be a vocabulary term, that is a rewrite not a correction.
    assert(isLearnable(heard: "a", corrected: "one two three four") == false)
    print("Vocabulary selftest ok")
  }
}
