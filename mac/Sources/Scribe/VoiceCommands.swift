import Foundation

/// Deterministic spoken-command pass over a finished transcript. No model,
/// instant, zero memory, never hallucinates. Runs in finish() before LLM
/// cleanup and insertion.
///
/// Commands (case-insensitive, ASR punctuation around them is ignored):
///   "new line" / "next line"            → newline
///   "new paragraph" / "next paragraph"  → blank line
///   "point N" / "number N" (1–20)       → numbered list item on its own line
///   "bullet" / "bullet point"           → "- " list item on its own line
///   "cancel the last line" / "delete last line" / "scratch that"
///                                       → drop the current line, continue fresh
///   "delete everything (I said so far)" / "start over"
///                                       → drop everything before it
///
/// ponytail: commands edit only the current dictation buffer, editing text
/// already inserted into the target app would need Accessibility keystrokes.
enum VoiceCommands {
  private static let numbers: [String: Int] = {
    var m: [String: Int] = [
      "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
      "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
      "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
      "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
    ]
    for n in 1...20 { m["\(n)"] = n }
    return m
  }()

  private static let strip = CharacterSet(charactersIn: ".,!?;:…")
  private static let sentenceEnd = CharacterSet(charactersIn: ".,!?;")

  private static let clearVerbs: Set<String> = [
    "delete", "erase", "scratch", "clear", "remove", "cancel", "forget", "undo",
  ]
  private static let clearObjects: [[String]] = [
    ["everything"], ["it", "all"], ["all", "of", "that"], ["all", "that"],
    ["all", "of", "this"], ["all", "this"], ["all", "of", "it"],
  ]
  private static let saidVerbs: [[String]] = [
    ["said"], ["told", "you"], ["dictated"], ["spoke"], ["spoken"], ["wrote"], ["typed"],
  ]
  private static let soFar: [[String]] = [
    ["so", "far"], ["till", "now"], ["until", "now"], ["up", "to", "now"], ["up", "till", "now"],
  ]
  private static let timeWords = soFar + [["before"], ["above"], ["earlier"]]

  /// Spoken punctuation → symbols. Formatting, so applied everywhere (live and
  /// imported). Longest phrase first, mirroring the mobile polish.ts.
  private static let punctuationWords: [(pattern: String, symbol: String)] = [
    ("\\b(?:open paren|open parenthesis)\\b", "("),
    ("\\b(?:close paren|close parenthesis)\\b", ")"),
    ("\\b(?:open quote|quote)\\b", "\u{201C}"),
    ("\\b(?:close quote|unquote|end quote)\\b", "\u{201D}"),
    ("\\b(?:exclamation mark|exclamation point)\\b", "!"),
    ("\\bquestion mark\\b", "?"),
    ("\\b(?:full stop|period)\\b", "."),
    ("\\bcomma\\b", ","),
    ("\\bcolon\\b", ":"),
    ("\\bsemicolon\\b", ";"),
    ("\\b(?:hyphen|dash)\\b", "-"),
  ]

  private static func applyPunctuationWords(_ text: String) -> String {
    var t = text
    for (pattern, symbol) in punctuationWords {
      t = t.replacingOccurrences(
        of: pattern, with: symbol, options: [.regularExpression, .caseInsensitive]
      )
    }
    return t
  }

  private static func tidySpacing(_ text: String) -> String {
    var t = text.replacingOccurrences(of: "[ \\t]+([,.!?;:])", with: "$1", options: .regularExpression)
    t = t.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
    t = t.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
    t = t.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// `allowDestructive` false (imported recordings) keeps "scratch that" and the
  /// delete-last-line/word edits as spoken words instead of executing them.
  static func apply(_ raw: String, allowDestructive: Bool = true) -> String {
    let tokens = applyPunctuationWords(raw).split(whereSeparator: \.isWhitespace).map(String.init)
    var out = ""
    var i = 0

    func key(_ j: Int) -> String {
      guard j < tokens.count else { return "" }
      return tokens[j].lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: strip)
    }
    func match(_ options: [[String]], at j: Int) -> Int? {
      options.first { words in words.indices.allSatisfy { key(j + $0) == words[$0] } }.map { j + $0.count }
    }
    func qualifier(at j: Int) -> Int? {
      var q = j
      if ["that", "what", "which"].contains(key(q)), ["i", "i've"].contains(key(q + 1)) { q += 1 }
      if key(q) == "i've" {
        q += 1
      } else if key(q) == "i" {
        q += key(q + 1) == "have" ? 2 : 1
      } else {
        return match(soFar, at: j)
      }
      guard let end = match(saidVerbs, at: q) else { return match(soFar, at: j) }
      return match(timeWords, at: end) ?? end
    }
    // Fires only at the end, with a qualifier, after ASR punctuation or before "and start over", so "delete everything in Downloads" survives.
    func clearAll(at j: Int) -> Int? {
      let object: Int?
      if key(j) == "start", ["over", "again"].contains(key(j + 1)) {
        object = j + 2
      } else if clearVerbs.contains(key(j)) {
        object = match(clearObjects, at: j + 1)
      } else {
        object = nil
      }
      guard let object else { return nil }
      if let end = qualifier(at: object) { return end }
      if object >= tokens.count { return object }
      if tokens[object - 1].unicodeScalars.last.map(sentenceEnd.contains) == true || key(object).isEmpty { return object }
      if key(object) == "and", key(object + 1) == "start", ["over", "again"].contains(key(object + 2)) { return object + 3 }
      return nil
    }
    func rtrimSpaces() {
      while out.hasSuffix(" ") { out.removeLast() }
    }
    func freshLine() {
      rtrimSpaces()
      if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
    }
    func cancelLastLine() {
      rtrimSpaces()
      while out.hasSuffix("\n") { out.removeLast() }
      if let r = out.range(of: "\n", options: .backwards) {
        out = String(out[..<r.lowerBound]) + "\n"
      } else {
        out = ""
      }
    }
    func cancelLastWord() {
      rtrimSpaces()
      while let last = out.last, last != " ", last != "\n" { out.removeLast() }
      rtrimSpaces()
    }

    while i < tokens.count {
      let k = key(i)

      if (k == "new" || k == "next"), key(i + 1) == "line" || key(i + 1) == "paragraph" {
        rtrimSpaces()
        out += key(i + 1) == "line" ? "\n" : "\n\n"
        i += 2
        continue
      }

      if allowDestructive {
        if let end = clearAll(at: i) {
          out = ""
          i = end
          continue
        }
        if ["scratch", "strike", "cross", "delete"].contains(k), key(i + 1) == "that" {
          cancelLastLine()
          i += 2
          continue
        }
        if ["cancel", "delete", "scratch", "cross"].contains(k) {
          var j = i + 1
          if key(j) == "the" { j += 1 }
          if key(j) == "last", key(j + 1) == "line" {
            cancelLastLine()
            i = j + 2
            continue
          }
          if key(j) == "last", key(j + 1) == "word" {
            cancelLastWord()
            i = j + 2
            continue
          }
        }
      }

      if k == "point" || k == "number", let n = numbers[key(i + 1)] {
        freshLine()
        out += "\(n). "
        i += 2
        continue
      }

      // "bullet" as a noun stays prose: "like bullet points", "the first bullet"
      if k == "bullet", key(i + 1) != "points",
         !["a", "an", "the", "first", "second", "third", "this", "that",
           "each", "every", "my", "your"].contains(i > 0 ? key(i - 1) : "") {
        freshLine()
        out += "- "
        i += key(i + 1) == "point" ? 2 : 1
        continue
      }

      if !out.isEmpty, !out.hasSuffix("\n"), !out.hasSuffix(" ") { out += " " }
      out += tokens[i]
      i += 1
    }
    return tidySpacing(out)
  }

  static func selfTest() {
    func eq(_ input: String, _ want: String, _ line: Int = #line) {
      let got = apply(input)
      precondition(got == want, "line \(line): apply(\(input)) = \(got.debugDescription), want \(want.debugDescription)")
    }
    func eqImport(_ input: String, _ want: String, _ line: Int = #line) {
      let got = apply(input, allowDestructive: false)
      precondition(got == want, "line \(line): apply(\(input), destructive:false) = \(got.debugDescription), want \(want.debugDescription)")
    }
    eq("hello world", "hello world")
    eq("hello next line, world", "hello\nworld")
    eq("hello new paragraph world", "hello\n\nworld")
    eq("shopping point one milk point two eggs", "shopping\n1. milk\n2. eggs")
    eq("Point 1. milk number two eggs", "1. milk\n2. eggs")
    eq("bullet milk bullet point eggs", "- milk\n- eggs")
    eq("first line next line wrong stuff cancel the last line right stuff",
       "first line\nright stuff")
    eq("wrong scratch that right", "right")
    eq("wrong strike that right", "right")
    eq("hello world delete last word", "hello")
    eq("delete last line", "")
    eq("the point of it all", "the point of it all") // "point" without a number is prose
    eq("can you have like bullet points in there", "can you have like bullet points in there")
    eq("the first bullet will be a 470 MB model", "the first bullet will be a 470 MB model")
    eq("hello comma world period", "hello, world.")
    eq("say quote hello unquote please", "say “ hello ” please")
    // Formatting applies to imports; destructive edits do not.
    eqImport("hello comma world", "hello, world")
    eqImport("keep this scratch that text", "keep this scratch that text")
    eq("no no no delete everything that I said till now the meeting is on Friday", "the meeting is on Friday")
    eq("hello world. Delete everything. New text here", "New text here")
    eq("first draft scratch all of that second draft", "first draft scratch all of that second draft")
    eq("first draft, scratch all of that. second draft", "second draft")
    eq("please delete everything in the downloads folder", "please delete everything in the downloads folder")
    eq("wrong stuff start over. right stuff", "right stuff")
    eq("erase everything I said so far okay take two", "okay take two")
    eq("delete everything", "")
    eq("old idea delete everything I've typed new idea", "new idea")
    eq("old idea clear it all and start over new idea", "new idea")
    eq("let's start over the project tomorrow", "let's start over the project tomorrow")
    eq("delete everything before Friday", "delete everything before Friday")
    eq("delete everything I said before. new start", "new start")
    eq("wrong delete everything so far right", "right")
    for input in [
      "no no no delete everything that I said till now the meeting is on Friday",
      "hello world. Delete everything. New text here",
      "first draft, scratch all of that. second draft",
      "wrong stuff start over. right stuff",
      "erase everything I said so far okay take two",
      "delete everything",
    ] {
      eqImport(input, input)
    }
    print("VoiceCommands selftest ok")
  }
}
