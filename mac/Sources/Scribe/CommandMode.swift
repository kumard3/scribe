import Foundation

/// Select text, hold the Command Mode shortcut and say what to change. The AI Cleanup
/// model rewrites the selection and the rewrite replaces it.
enum CommandMode {
  typealias LLM = (_ system: String, _ user: String, _ done: @escaping (String?) -> Void) -> Void

  static let selectFirst = "Select text first"
  static let needsModel = "Command Mode needs an AI model, set one up in AI Cleanup"

  static let systemPrompt = """
    You edit text. The user selected some text and spoke an instruction. Apply the instruction \
    to the selected text. Output only the rewritten text: no preamble, no quotes around it, no \
    explanation, no notes, and never repeat the instruction. If the instruction names a \
    language, write in that language. Otherwise keep the language of the selected text.
    """

  static func prompt(instruction: String, selection: String) -> (system: String, user: String) {
    (systemPrompt, "INSTRUCTION: \(instruction)\n\nSELECTED TEXT:\n\(selection)")
  }

  /// nil when there is nothing to rewrite.
  static func usable(_ selection: String?) -> String? {
    guard let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return selection
  }

  /// Completion gets the replacement for the selection, or nil when there was nothing to
  /// rewrite or the model returned nothing usable. The model is never asked without a selection.
  static func run(instruction: String, selection: String?, llm: LLM, completion: @escaping (String?) -> Void) {
    let spoken = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let selection = usable(selection), !spoken.isEmpty else { return completion(nil) }
    let p = prompt(instruction: spoken, selection: selection)
    llm(p.system, p.user) { output in
      guard let rewrite = clean(output, instruction: spoken, selection: selection) else { return completion(nil) }
      // A double-click selection often carries the trailing space; keep it.
      let lead = selection.prefix { $0.isWhitespace }
      let trail = selection.reversed().prefix { $0.isWhitespace }.reversed()
      completion(String(lead) + rewrite + String(trail))
    }
  }

  private static let preambles = [
    #"^(?:(?:sure|okay|ok|certainly|of course|absolutely|alright)[!.,]?\s+)?here(?:'s|’s| is| are)\b[^\n:]*:\s*"#,
    #"^(?:sure|okay|ok|certainly|of course|absolutely|alright)[!.]?\s*\n+"#,
    #"^(?:the\s+)?(?:rewritten|revised|edited|updated|translated|shortened|final|improved|new)?\s*(?:selected text|text|version|output|result|translation)\s*:\s*"#,
    #"^instruction\s*:[^\n]*\n+"#,
  ]
  private static let chatter =
    #"^(?:let me know|i hope|hope this|feel free|note:|\(note|i've |i have |i kept|i made|i removed|i shortened|i translated|this version|if you'd like|if you want)"#
  private static let refusal = #"^(?:i['’]m sorry|i am sorry|sorry, i|i can['’]t|i cannot|as an ai)"#
  private static let quotePairs: [(Character, Character)] = [
    ("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'"), ("\u{2018}", "\u{2019}"), ("«", "»"), ("`", "`"),
  ]

  /// Strips what small models wrap a rewrite in: code fences, "Here is the rewritten text:",
  /// echoed prompt labels or instruction, wrapping quotes and a closing "Let me know" line.
  static func clean(_ output: String?, instruction: String, selection: String) -> String? {
    var t = (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var previous = ""
    while t != previous {
      previous = t
      if t.hasPrefix("```"), t.hasSuffix("```"), t.count >= 6 {
        t = String(t.dropFirst(3).dropLast(3))
        if let newline = t.firstIndex(of: "\n"), !t[..<newline].contains(" ") { t = String(t[t.index(after: newline)...]) }
      }
      for p in preambles {
        t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
      }
      let echoed = instruction.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
      if !echoed.isEmpty, let r = t.range(of: echoed, options: [.caseInsensitive, .anchored]),
         r.upperBound == t.endIndex || ":.\n-".contains(t[r.upperBound]) {
        t = String(t[r.upperBound...].drop { ":.-".contains($0) || $0.isWhitespace })
      }
      t = t.trimmingCharacters(in: .whitespacesAndNewlines)
      if let first = t.first, let last = t.last, t.count >= 2,
         let pair = quotePairs.first(where: { $0.0 == first && $0.1 == last }),
         !t.dropFirst().dropLast().contains(pair.0),
         selection.trimmingCharacters(in: .whitespacesAndNewlines).first != first {
        t = String(t.dropFirst().dropLast())
      }
      var paragraphs = t.components(separatedBy: "\n\n")
      if paragraphs.count > 1, let tail = paragraphs.last?.trimmingCharacters(in: .whitespacesAndNewlines),
         tail.range(of: chatter, options: [.regularExpression, .caseInsensitive]) != nil,
         selection.range(of: String(tail.prefix(20)), options: .caseInsensitive) == nil {
        paragraphs.removeLast()
        t = paragraphs.joined(separator: "\n\n")
      }
      t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !t.isEmpty else { return nil }
    let words = TranscriptCleanupValidator.tokens
    guard words(t) != words(instruction) else { return nil }
    if t.range(of: refusal, options: [.regularExpression, .caseInsensitive]) != nil,
       selection.range(of: refusal, options: [.regularExpression, .caseInsensitive]) == nil {
      return nil
    }
    return t
  }

  static func selfTest() {
    let base = "The meeting is on Friday at noon, please come."
    let p = prompt(instruction: "make this shorter", selection: base)
    precondition(p.system == systemPrompt && p.system.contains("Output only the rewritten text"))
    precondition(p.user == "INSTRUCTION: make this shorter\n\nSELECTED TEXT:\n\(base)", p.user)

    func check(_ output: String?, _ want: String?, instruction: String = "make this shorter",
               selection: String? = nil, _ line: Int = #line) {
      let selection = selection ?? base
      var sent: (String, String)?
      var got: String?? = .none
      run(instruction: instruction, selection: selection, llm: { system, user, done in
        sent = (system, user)
        done(output)
      }) { got = .some($0) }
      let expected = prompt(instruction: instruction, selection: selection)
      precondition(sent?.0 == expected.system && sent?.1 == expected.user, "line \(line): prompt not sent")
      precondition(got == .some(want), "line \(line): \(output.debugDescription) -> \(String(describing: got))")
    }
    let short = "Meeting Friday at noon."
    check(short, short)
    check("\"\(short)\"", short)
    check("\u{201C}\(short)\u{201D}", short)
    check("Sure! Here is the shorter version:\n\n\u{201C}\(short)\u{201D}", short)
    check("Here's the rewritten text: \(short)", short)
    check("Rewritten text:\n\(short)", short)
    check("Okay.\n\(short)", short)
    check("Make this shorter: \(short)", short)
    check("INSTRUCTION: make this shorter\n\nSELECTED TEXT:\n\(short)", short)
    check("```\n\(short)\n```", short)
    check("```text\n\(short)\n```", short)
    check("\(short)\n\nLet me know if you want it even shorter.", short)
    check("\"\(short)\"\n\nI kept the time and the day.", short)
    check("- Meeting: Friday\n- Time: noon", "- Meeting: Friday\n- Time: noon", instruction: "turn this into bullet points")
    check("मीटिंग शुक्रवार दोपहर को है।", "मीटिंग शुक्रवार दोपहर को है।", instruction: "translate to Hindi")
    check("\"yes\" and \"no\"", "\"yes\" and \"no\"")
    check("\"Quoted, shorter\"", "\"Quoted, shorter\"", selection: "\"Quoted text that was longer\"")
    check("Hi there", " Hi there ", selection: " Hello there my friend ")
    check("Thanks.\n\nLet me know if you need anything.", "Thanks.\n\nLet me know if you need anything.",
          instruction: "fix the grammar", selection: "thanks\n\nlet me know if you need anything")
    check("", nil)
    check(nil, nil)
    check("   \n ", nil)
    check("\"\"", nil)
    check("Make this shorter.", nil)
    check("make this shorter", nil)
    check("I'm sorry, I can't help with that.", nil)

    for empty in [nil, "", "  \n "] as [String?] {
      var asked = false
      var got: String?? = .none
      run(instruction: "make this shorter", selection: empty, llm: { _, _, done in
        asked = true
        done("x")
      }) { got = .some($0) }
      precondition(!asked && got == .some(nil), "no selection must not reach the model")
      precondition(usable(empty) == nil)
    }
    precondition(usable("hi") == "hi")
    var asked = false
    run(instruction: "  ", selection: base, llm: { _, _, done in asked = true; done("x") }) { precondition($0 == nil) }
    precondition(!asked, "no instruction must not reach the model")
    print("CommandMode selftest ok")
  }
}
