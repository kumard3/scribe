import Foundation

/// Swift port of applyVoiceCommands in src/util/polish.ts, for dictation that never reaches JS.
enum VoiceCommands {
  private static let now = "(?:so far|till now|until now|up to now|up till now)"
  private static let time = "(?:so far|till now|until now|up to now|up till now|before|above|earlier)"
  private static let qualifier =
    "(?:\\s+(?:(?:that|what|which)\\s+)?i(?:\\s+have|'ve|’ve)?\\s+(?:said|told you|dictated|spoken|spoke|wrote|typed)(?:\\s+\(time))?|\\s+\(now))"
  private static let clearAll = regex(
    "\\b(?:(?:delete|erase|scratch|clear|remove|cancel|forget|undo)\\s+(?:everything|all of that|all of this|all of it|all that|all this|it all)|start\\s+(?:over|again))\\b(\(qualifier))?\\b([.,!?;]*)"
  )
  private static let andStartOver = regex("^\\s*and\\s+start\\s+(?:over|again)\\b[.,!?;]*")
  private static let leading = regex("^[\\s.,!?;:]+")
  private static let scratch = regex("[^.!?\\n]*\\b(?:scratch|strike|delete|cross)\\s+that\\b[.,!?]*")
  private static let lastWord = regex("(?:\\S+)\\s+\\b(?:scratch|delete|cross)\\s+(?:the\\s+)?last word\\b[.,!?]*")
  private static let lastLine = regex("\\b(?:scratch|delete|cross)\\s+(?:this |the |that )?last line\\b[.,!?]*")

  private static func regex(_ pattern: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
  }

  private static func replace(_ re: NSRegularExpression, in text: String) -> String {
    re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
  }

  private static func clear(_ text: String) -> String {
    let ns = text as NSString
    var keepFrom = -1
    for m in clearAll.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      var end = m.range.location + m.range.length
      let rest = ns.substring(from: end)
      let andStart = andStartOver.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length))
      if let andStart { end += andStart.range.length }
      let qualified = m.range(at: 1).location != NSNotFound
      let punctuated = m.range(at: 2).length > 0
      if rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || qualified || punctuated || andStart != nil {
        keepFrom = end
      }
    }
    return keepFrom < 0 ? text : replace(leading, in: ns.substring(from: keepFrom))
  }

  static func apply(_ text: String) -> String {
    let t = replace(lastWord, in: replace(scratch, in: clear(text)))
    guard lastLine.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil else { return t }
    var out: [String] = []
    for line in t.components(separatedBy: "\n") {
      let ns = line as NSString
      if let m = lastLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
        let before = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        if before.isEmpty, !out.isEmpty { out.removeLast() }
        continue
      }
      out.append(line)
    }
    return out.joined(separator: "\n")
  }
}
