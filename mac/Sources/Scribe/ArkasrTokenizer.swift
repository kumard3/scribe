import Foundation

/// Byte-level BPE *decoder* for the Audio8 / ARK bundles. The prompt is a fixed
/// token sequence (see `ArkasrEngine.promptSuffix`), so nothing here ever needs
/// to encode text and merges.txt is not downloaded.
struct ArkasrTokenizer {
  private let idToToken: [Int: String]
  private static let unicodeToByte: [Character: UInt8] = {
    var bytes: [UInt8] = []
    for b in UInt8(ascii: "!")...UInt8(ascii: "~") { bytes.append(b) }
    for b in UInt8(0xA1)...UInt8(0xAC) { bytes.append(b) }
    for b in UInt8(0xAE)...UInt8(0xFF) { bytes.append(b) }
    var map: [Character: UInt8] = [:]
    for b in bytes { map[Character(UnicodeScalar(b))] = b }
    var next = 256
    for b in 0...255 {
      let byte = UInt8(b)
      if !bytes.contains(byte) {
        map[Character(UnicodeScalar(next)!)] = byte
        next += 1
      }
    }
    return map
  }()

  init(vocabURL: URL) throws {
    let data = try Data(contentsOf: vocabURL)
    guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Ort.Error(message: "vocab.json is not an object")
    }
    var map: [Int: String] = [:]
    map.reserveCapacity(dict.count)
    for (token, id) in dict {
      if let i = id as? Int { map[i] = token }
    }
    idToToken = map
  }

  /// Joins the byte-level pieces and decodes once, so a multi-byte character
  /// split across two tokens still comes out intact.
  func decode(_ ids: [Int]) -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(ids.count * 2)
    for id in ids {
      guard let token = idToToken[id] else { continue }
      if token.hasPrefix("<|") && token.hasSuffix("|>") { continue }
      for ch in token {
        if let b = Self.unicodeToByte[ch] { bytes.append(b) }
      }
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// Mirrors `normalize_prediction_text` in the bundle's reference runtime.
  static func normalize(_ raw: String) -> String {
    var text = raw
    for marker in ["<|user|>", "<|assistant|>", "<|im_end|>"] {
      if let r = text.range(of: marker) { text = String(text[..<r.lowerBound]) }
    }
    if let r = text.range(of: "<|text|>") { text = String(text[r.upperBound...]) }
    if let r = text.range(of: "<asr_text>") { text = String(text[r.upperBound...]) }
    text = text.replacingOccurrences(
      of: #"^\s*language\s+[A-Za-z]+\s+"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(
      of: #"<\|[^>]+\|>"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(
      of: #"\s+"#, with: " ", options: .regularExpression)
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.replacingOccurrences(
      of: #"^[\s,.;:!?-]+"#, with: "", options: .regularExpression)
  }
}
