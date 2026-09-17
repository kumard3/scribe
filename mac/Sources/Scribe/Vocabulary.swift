import Foundation

/// User vocabulary: names, jargon and acronyms the recognizer keeps getting
/// wrong. Terms bias transducer decoding directly and prime whisper.cpp.
enum Vocabulary {
  /// Apple's recognizer hears the product's own name as "Chris" with nothing to bias it.
  static let base = [
    "Bolkit", "Gemma", "E2B", "E4B", "chunking", "on-device",
    "whisper.cpp", "Hinglish", "Oriserve", "Apex", "Swift",
  ]

  static var terms: [String] {
    Settings.shared.vocabulary
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// What every engine biases toward: the built-in terms plus the user's.
  static var biasTerms: [String] {
    var seen = Set<String>()
    return (base + terms).filter { seen.insert($0.lowercased()).inserted }
  }

  /// sherpa wants one term per line, tokens space-separated inside a term.
  static var hotwordsBuffer: String? {
    let list = biasTerms
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
    let list = biasTerms
    guard !list.isEmpty else { return nil }
    return list.joined(separator: ", ")
  }

  private static let instructionStems: [String] = contentWords(
    ModelCatalog.transcribeInstruction + " " + ModelCatalog.hinglishInstruction + " The audio is in. Write the transcript in."
  )

  private static func contentWords(_ s: String) -> [String] {
    s.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
  }

  /// "transcribing" matches "transcribe", "mix" matches "mixes".
  private static func sameStem(_ a: String, _ b: String) -> Bool {
    let shorter = min(a.count, b.count)
    return zip(a, b).prefix { $0 == $1 }.count >= min(5, shorter)
  }

  // Gemma drops its "Transcribe this audio verbatim" ask mid-sentence on quiet audio. A plain "transcribe this"
  // is only cut when it can't be speech: capitalised mid-line, before a capitalised word, or ending the text.
  private static let instructionPhrases = try! NSRegularExpression(pattern: [
    #"(?i:\s*\btranscrib\w*\s+this\s+(audio\s+)?verbatim\b\.?)"#,
    #"(?i:\s*\btranscrib\w*\s+this\s+audio\b\.?)"#,
    #"(?<=\S)\s+Transcribe this\b\.?"#,
    #"(?i:\s*\btranscribe this\b\.?)(?=\s+[A-Z])"#,
    #"(?i:\s*\btranscribe this\.?\s*$)"#,
  ].joined(separator: "|"))

  /// Removes what a model recites from its prompt instead of transcribing: a run of 4+
  /// vocabulary words, the instruction phrase, or a sentence made of the instruction's own words.
  static func stripPromptEcho(_ text: String) -> String {
    let vocab = stripVocabularyRun(text)
    let stripped = instructionPhrases
      .stringByReplacingMatches(in: vocab, range: NSRange(vocab.startIndex..., in: vocab), withTemplate: "")
    // What an echo leaves behind ("Uh", "I am a") is not speech.
    if stripped != vocab, contentWords(stripped).isEmpty { return "" }
    return stripped
      .split(separator: ".", omittingEmptySubsequences: false)
      .filter { sentence in
        let words = contentWords(String(sentence))
        guard words.count >= 4,
              words.contains(where: { w in ["transcrib", "verbatim", "devanagari", "commentar", "timestamp", "mix"].contains { w.hasPrefix($0) } })
        else { return true }
        let echoed = words.filter { w in instructionStems.contains { sameStem(w, $0) } }.count
        return Double(echoed) / Double(words.count) < 0.75
      }
      .joined(separator: ".")
      .trimmingCharacters(in: .whitespaces)
  }

  private static func stripVocabularyRun(_ text: String) -> String {
    let known = Set(biasTerms.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
    let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    let key = { (w: String) in w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;:")) }
    var out: [String] = []
    var i = 0
    while i < words.count {
      var j = i
      while j < words.count, known.contains(key(words[j])) { j += 1 }
      if j - i >= 4 {
        i = j
      } else {
        out.append(words[i])
        i += 1
      }
    }
    return out.filter { !$0.isEmpty }.joined(separator: " ")
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
    assert(biasTerms.contains("Bolkit"))
    assert(biasTerms.contains("E2B"))
    assert(biasTerms.contains("Hinglish"))
    assert(biasTerms.filter { $0.lowercased() == "bolkit" }.count == 1)
    let leak = "Bolkit Gemma E2B E4B chunking on-device whisper.cpp Hinglish Oriserve Apex Swift Are bhai mast kar diya"
    assert(stripPromptEcho(leak) == "Are bhai mast kar diya", stripPromptEcho(leak))
    assert(stripPromptEcho("I tested Gemma E2B chunking today") == "I tested Gemma E2B chunking today")
    for echo in ["Uh Transcribe this audio verbatim.", "I am a transcribing this audio verbatim.",
                 "The sound is a mix of Hindi and English.", "Uh Transcribe this verbatim.", "um transcribe this"] {
      precondition(stripPromptEcho(echo).isEmpty, "echo kept: \(stripPromptEcho(echo))")
    }
    precondition(stripPromptEcho("Hey sir this stupid. Transcribe this audio verbatim.") == "Hey sir this stupid.")
    precondition(stripPromptEcho("Bhai kal client ko audio file bhej dena") == "Bhai kal client ko audio file bhej dena")
    precondition(stripPromptEcho("The speaker never spoke English.") == "The speaker never spoke English.")
    let heard: [(String, String)] = [
      ("Hmm Transcribe this audio verbatim", "Hmm"),
      ("OK", "OK"),
      ("They are some Transcribe this audio verbatim.", "They are some"),
      ("I'm already done with my GST from Transcribe this audio", "I'm already done with my GST from"),
      ("Five percent Transcribe this Ah yes that's what it says", "Five percent Ah yes that's what it says"),
      ("just need a review um transcribe this Okay so", "just need a review um Okay so"),
      ("Can you transcribe this recording for me", "Can you transcribe this recording for me"),
    ]
    for (input, want) in heard {
      precondition(stripPromptEcho(input) == want, "\(input) -> \(stripPromptEcho(input))")
    }
    print("Vocabulary selftest ok")
  }
}
