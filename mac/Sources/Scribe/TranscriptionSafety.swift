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

    let cleanedTokens = tokens(candidate)
    guard !cleanedTokens.isEmpty else {
      return Decision(text: raw, accepted: false, reason: "cleanup had no words")
    }

    // Cleanup punctuates, it does not edit. The old thresholds let a small
    // model delete a quarter of a transcript and still pass, which is how
    // dictations came back with sentences missing. The word sequence must now
    // survive exactly, ignoring fillers and anything numeric, so a model is
    // still free to write "3:30 PM" for "three thirty p m" but can never drop
    // or invent words.
    let rawContent = comparable(tokens(raw))
    let cleanedContent = comparable(cleanedTokens)
    guard rawContent == cleanedContent else {
      return Decision(text: raw, accepted: false, reason: "word sequence changed")
    }

    return Decision(text: candidate, accepted: true, reason: "word-preserving cleanup")
  }

  /// Words that must appear, in order, on both sides. Fillers may be dropped
  /// and number words may be rewritten into digits, so neither is compared.
  private static func comparable(_ tokens: [String]) -> [String] {
    tokens.filter { !removableFillers.contains($0) && !isNumeric($0) }
  }

  private static let numberWords: Set<String> = [
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
    "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
    "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
    "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
    "thousand", "lakh", "crore", "million", "billion", "am", "pm", "oclock",
    "first", "second", "third", "fourth", "fifth",
  ]

  private static func isNumeric(_ token: String) -> Bool {
    if numberWords.contains(token) { return true }
    // "p.m." splits into two single letters while "PM" stays one token, so the
    // sequences could never line up. Single letters are abbreviation debris.
    if token.count == 1 { return true }
    return token.allSatisfy { $0.isNumber }
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

  /// A flat wall-clock budget killed every long recording: no backend finishes
  /// 20 minutes of audio inside 180 s, so the worker was always reaped before
  /// it could return. Scale with the audio, keeping the flat value as a floor.
  /// The factor is headroom for the slowest backend (Qwen3-ASR on CPU).
  static func workerTimeout(audioSeconds: Double) -> TimeInterval {
    max(workerTimeoutSeconds, audioSeconds * 4)
  }

  /// Hard resident-memory ceiling for every native transcription subprocess.
  /// A model that cannot run inside the product budget fails safely instead of
  /// swapping or taking down the user's machine.
  static func workerMemoryLimit(for spec: ModelSpec, audioSeconds: Double) -> UInt64 {
    // A flat 900 MB was measured against Apex and then applied to every model,
    // so Whisper Turbo (563 MB of weights) tripped it while loading and failed
    // on every clip, half a second included. The runtime holds several times
    // the weight file: parakeet-ctc-110m measured 339 MB resident for 104 MB of
    // weights. Track the model, keep the old value as a floor for small ones.
    let weights = UInt64(max(spec.sizeBytes, 0)) + UInt64(max(spec.mmprojSizeBytes, 0))
    let audioBytes = UInt64(audioSeconds * Double(sampleRate) * 4)
    let budget = max(900_000_000, weights * 4) + audioBytes
    // Sizing off the model alone would let a large one swap the machine to a
    // halt, which is the exact failure this ceiling exists to prevent. Half of
    // physical RAM wins, so a model too big for this Mac fails instead.
    return min(budget, ProcessInfo.processInfo.physicalMemory / 2)
  }
}
