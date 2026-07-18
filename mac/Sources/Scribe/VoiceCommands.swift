import Foundation

/// Deterministic spoken-command pass over a finished transcript. No model —
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
///
/// ponytail: commands edit only the current dictation buffer — editing text
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

  static func apply(_ raw: String) -> String {
    let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
    var out = ""
    var i = 0

    func key(_ j: Int) -> String {
      guard j < tokens.count else { return "" }
      return tokens[j].lowercased().trimmingCharacters(in: strip)
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

    while i < tokens.count {
      let k = key(i)

      if (k == "new" || k == "next"), key(i + 1) == "line" || key(i + 1) == "paragraph" {
        rtrimSpaces()
        out += key(i + 1) == "line" ? "\n" : "\n\n"
        i += 2
        continue
      }

      if k == "scratch", key(i + 1) == "that" {
        cancelLastLine()
        i += 2
        continue
      }
      if k == "cancel" || k == "delete" {
        var j = i + 1
        if key(j) == "the" { j += 1 }
        if key(j) == "last", key(j + 1) == "line" {
          cancelLastLine()
          i = j + 2
          continue
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
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func selfTest() {
    func eq(_ input: String, _ want: String, _ line: Int = #line) {
      let got = apply(input)
      assert(got == want, "line \(line): apply(\(input)) = \(got.debugDescription), want \(want.debugDescription)")
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
    eq("delete last line", "")
    eq("the point of it all", "the point of it all") // "point" without a number is prose
    eq("can you have like bullet points in there", "can you have like bullet points in there")
    eq("the first bullet will be a 470 MB model", "the first bullet will be a 470 MB model")
    print("VoiceCommands selftest ok")
  }
}
