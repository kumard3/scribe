import Foundation

/// Deterministic overlap repair shared by bounded ASR backends.
///
/// Audio windows overlap so a word cut at a hard boundary appears completely
/// in at least one window. This removes the longest word suffix/prefix match
/// without trying to rewrite model output.
enum TranscriptMerger {
  static func merge(_ parts: [String], maxOverlapWords: Int = 16) -> String {
    var result = ""
    for raw in parts {
      let next = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !next.isEmpty else { continue }
      guard !result.isEmpty else { result = next; continue }

      let left = result.split(whereSeparator: \.isWhitespace).map(String.init)
      let right = next.split(whereSeparator: \.isWhitespace).map(String.init)
      let limit = min(maxOverlapWords, left.count, right.count)
      var matched = 0
      if limit > 0 {
        for n in stride(from: limit, through: 1, by: -1) {
          let a = left.suffix(n).map(normalize)
          let b = right.prefix(n).map(normalize)
          if a == b { matched = n; break }
        }
      }
      let tail = right.dropFirst(matched).joined(separator: " ")
      if !tail.isEmpty { result += " " + tail }
    }
    return result
  }

  private static func normalize(_ word: String) -> String {
    word.lowercased().trimmingCharacters(in: .punctuationCharacters)
  }
}

/// A small model is allowed to punctuate a transcript, but it is never allowed
/// to silently replace the speaker's words. This deterministic gate keeps the
/// raw ASR result whenever cleanup drops content, invents too much content, or
/// damages numbers/acronyms.
enum TranscriptCleanupValidator {
  struct Decision {
    let text: String
    let accepted: Bool
    let reason: String
  }

  private static let removableFillers: Set<String> = [
    "ah", "er", "erm", "hmm", "like", "okay", "ok", "um", "uh",
  ]

  static func choose(raw: String, cleaned: String?) -> Decision {
    let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let candidate = cleaned?.trimmingCharacters(in: .whitespacesAndNewlines),
          !candidate.isEmpty else {
      return Decision(text: raw, accepted: false, reason: "cleanup returned empty")
    }
    guard !raw.isEmpty else {
      return Decision(text: candidate, accepted: true, reason: "raw transcript was empty")
    }

    let ratio = Double(candidate.count) / Double(max(raw.count, 1))
    guard (0.68...1.45).contains(ratio) else {
      return Decision(text: raw, accepted: false, reason: "length ratio \(format(ratio))")
    }

    let rawTokens = tokens(raw)
    let cleanedTokens = tokens(candidate)
    guard !cleanedTokens.isEmpty else {
      return Decision(text: raw, accepted: false, reason: "cleanup had no words")
    }

    // A cleanup pass must preserve every number and acronym. Matching is
    // case-insensitive so adding normal sentence capitalization is harmless.
    let protected = protectedTokens(raw)
    let cleanedCounts = counts(cleanedTokens)
    for (token, required) in counts(protected) where (cleanedCounts[token] ?? 0) < required {
      return Decision(text: raw, accepted: false, reason: "lost number/acronym \(token)")
    }

    let rawContent = rawTokens.filter { !removableFillers.contains($0) }
    let cleanedContent = cleanedTokens.filter { !removableFillers.contains($0) }
    if rawContent.count >= 4 {
      let shared = multisetIntersectionCount(rawContent, cleanedContent)
      let coverage = Double(shared) / Double(rawContent.count)
      let novelty = Double(max(0, cleanedContent.count - shared))
        / Double(max(cleanedContent.count, 1))
      guard coverage >= 0.72 else {
        return Decision(text: raw, accepted: false, reason: "word coverage \(format(coverage))")
      }
      guard novelty <= 0.32 else {
        return Decision(text: raw, accepted: false, reason: "new-word ratio \(format(novelty))")
      }
    }

    return Decision(text: candidate, accepted: true, reason: "word-preserving cleanup")
  }

  private static func tokens(_ text: String) -> [String] {
    text.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }
      .map {
        $0.lowercased()
          .replacingOccurrences(of: "’", with: "'")
          .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
      }
      .filter { !$0.isEmpty }
  }

  private static func protectedTokens(_ text: String) -> [String] {
    text.split { !$0.isLetter && !$0.isNumber }.compactMap { part in
      let token = String(part)
      if token.contains(where: \.isNumber) { return token.lowercased() }
      let letters = token.filter(\.isLetter)
      if letters.count >= 2, letters == letters.uppercased() {
        return token.lowercased()
      }
      return nil
    }
  }

  private static func counts(_ tokens: [String]) -> [String: Int] {
    tokens.reduce(into: [:]) { $0[$1, default: 0] += 1 }
  }

  private static func multisetIntersectionCount(_ a: [String], _ b: [String]) -> Int {
    var available = counts(b)
    var shared = 0
    for token in a where (available[token] ?? 0) > 0 {
      available[token, default: 0] -= 1
      shared += 1
    }
    return shared
  }

  private static func format(_ value: Double) -> String {
    String(format: "%.2f", value)
  }
}

enum TranscriptionLimits {
  static let sampleRate = 16_000
  static let workerTimeoutSeconds: TimeInterval = 180
  static let maxCapturedSeconds = 15 * 60

  /// Hard resident-memory ceiling for every native transcription subprocess.
  /// A model that cannot run inside the product budget fails safely instead of
  /// swapping or taking down the user's machine.
  static func workerMemoryLimit(for spec: ModelSpec) -> UInt64 {
    _ = spec
    // Apex measured 817 MB RSS through the packaged worker on a 60-second
    // stress clip. The remaining ~100 MB is reserved for Scribe and macOS.
    return 900_000_000
  }
}
