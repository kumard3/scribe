import AppKit
import ApplicationServices

/// After Scribe types into a field, the user fixing a word right there is the
/// clearest possible signal that the recognizer got it wrong. Watch the field
/// briefly, diff what changed, and feed the fix back into the vocabulary.
enum CorrectionWatcher {
  private static var element: AXUIElement?
  private static var snapshot = ""
  private static var inserted = ""
  private static let checkpoints: [TimeInterval] = [4, 10, 20]

  static func arm(_ element: AXUIElement, inserted text: String) {
    guard Settings.shared.learnCorrections, !text.isEmpty else { return }
    guard let value = fieldValue(element) else { return }
    self.element = element
    self.snapshot = value
    self.inserted = text
    for delay in checkpoints {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { check() }
    }
  }

  static func disarm() {
    element = nil
    snapshot = ""
    inserted = ""
  }

  private static func check() {
    guard let element, !inserted.isEmpty else { return }
    guard let current = fieldValue(element), current != snapshot else { return }
    guard let (heard, corrected) = changedSpan(from: snapshot, to: current) else { return }
    // Only learn from edits to words we just typed; unrelated typing elsewhere
    // in the document is not a correction of the transcript.
    guard inserted.localizedCaseInsensitiveContains(heard) else {
      snapshot = current
      return
    }
    snapshot = current
    guard Vocabulary.isLearnable(heard: heard, corrected: corrected) else { return }
    Vocabulary.add(corrected)
  }

  private static func fieldValue(_ element: AXUIElement) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element, kAXValueAttribute as CFString, &ref
    ) == .success else { return nil }
    return ref as? String
  }

  /// The text that actually changed, as (before, after), with the shared
  /// prefix and suffix trimmed off and the result widened to word boundaries.
  static func changedSpan(from before: String, to after: String) -> (String, String)? {
    guard before != after else { return nil }
    let b = Array(before), a = Array(after)
    var head = 0
    while head < b.count, head < a.count, b[head] == a[head] { head += 1 }
    var tail = 0
    while tail < b.count - head, tail < a.count - head,
          b[b.count - 1 - tail] == a[a.count - 1 - tail] { tail += 1 }

    let oldSpan = expand(b, from: head, to: b.count - tail)
    let newSpan = expand(a, from: head, to: a.count - tail)
    guard !oldSpan.isEmpty || !newSpan.isEmpty else { return nil }
    return (oldSpan, newSpan)
  }

  /// Grow a character range out to whole words, so "kumr"→"kumar" is learned as
  /// the word rather than as the single letter that changed.
  private static func expand(_ chars: [Character], from start: Int, to end: Int) -> String {
    guard !chars.isEmpty else { return "" }
    var lo = min(max(start, 0), chars.count)
    var hi = min(max(end, lo), chars.count)
    while lo > 0, !chars[lo - 1].isWhitespace { lo -= 1 }
    while hi < chars.count, !chars[hi].isWhitespace { hi += 1 }
    return String(chars[lo..<hi]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func selfTest() {
    var span = changedSpan(from: "call assist able today", to: "call Assistable today")
    assert(span?.0 == "assist able" && span?.1 == "Assistable", "got \(String(describing: span))")

    span = changedSpan(from: "meet kumr at six", to: "meet kumar at six")
    assert(span?.0 == "kumr" && span?.1 == "kumar", "got \(String(describing: span))")

    assert(changedSpan(from: "same", to: "same") == nil)

    // Pure append is not a correction of an existing word.
    span = changedSpan(from: "hello", to: "hello world")
    assert(span?.0 == "hello" || span?.0.isEmpty == true)
    print("CorrectionWatcher selftest ok")
  }
}
