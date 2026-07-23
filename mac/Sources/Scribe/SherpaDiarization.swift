import Foundation
import CSherpa

struct SpeakerSegment {
  let start: Double
  let end: Double
  let speaker: Int
}

struct SpeakerTurn {
  let speaker: Int
  var text: String
}

/// On-device speaker diarization (who-said-what) for imported recordings. Wraps
/// sherpa-onnx OfflineSpeakerDiarization: pyannote segmentation + speaker
/// embedding + fast clustering. Runs on a background thread; a whole file is
/// held in memory native-side.
enum Diarizer {
  /// `numSpeakers <= 0` lets the clusterer decide. A user-set count is strongly
  /// preferred: auto-clustering over-segments long calls badly.
  static func diarize(samples: [Float], sampleRate: Int, numSpeakers: Int) -> [SpeakerSegment] {
    guard let seg = SupportModelStore.diarSegPath(),
          let emb = SupportModelStore.diarEmbPath() else {
      dlog("diarize: models missing")
      return []
    }
    var cfg = SherpaOnnxOfflineSpeakerDiarizationConfig()
    memset(&cfg, 0, MemoryLayout.size(ofValue: cfg))
    let segC = strdup(seg)
    let embC = strdup(emb)
    let provider = strdup("cpu")
    defer { free(segC); free(embC); free(provider) }
    cfg.segmentation.pyannote.model = UnsafePointer(segC)
    cfg.segmentation.num_threads = 2
    cfg.segmentation.provider = UnsafePointer(provider)
    cfg.embedding.model = UnsafePointer(embC)
    cfg.embedding.num_threads = 2
    cfg.embedding.provider = UnsafePointer(provider)
    cfg.clustering.num_clusters = numSpeakers > 0 ? Int32(numSpeakers) : -1
    cfg.clustering.threshold = 0.5
    cfg.min_duration_on = 0.3
    cfg.min_duration_off = 0.5

    guard let sd = SherpaOnnxCreateOfflineSpeakerDiarization(&cfg) else {
      dlog("diarize: create failed")
      return []
    }
    defer { SherpaOnnxDestroyOfflineSpeakerDiarization(sd) }

    let rate = Int(SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(sd))
    let audio = SileroVAD.resampleTo16k(samples, from: sampleRate)
    guard !audio.isEmpty, rate == 16000 else {
      dlog("diarize: unexpected model rate \(rate)")
      return []
    }
    let result = audio.withUnsafeBufferPointer {
      SherpaOnnxOfflineSpeakerDiarizationProcess(sd, $0.baseAddress, Int32(audio.count))
    }
    guard let result else { return [] }
    defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }

    let n = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
    guard n > 0,
          let arr = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else { return [] }
    defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(arr) }
    var out: [SpeakerSegment] = []
    out.reserveCapacity(n)
    for i in 0..<n {
      let s = arr[i]
      out.append(SpeakerSegment(start: Double(s.start), end: Double(s.end), speaker: Int(s.speaker)))
    }
    dlog("diarize: \(out.count) segment(s), \(Set(out.map(\.speaker)).count) speaker(s)")
    return out
  }

  static func speakerLabel(_ speaker: Int) -> String { "Speaker \(speaker + 1)" }

  /// Attributes plain transcript text to speakers. The Mac offline path returns
  /// no per-word timings, so words are distributed across the diarization turns
  /// proportionally to each turn's duration (mirrors the mobile fallback).
  static func buildSpeakerTurns(text: String, segments: [SpeakerSegment]) -> [SpeakerTurn] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !segments.isEmpty else {
      return trimmed.isEmpty ? [] : [SpeakerTurn(speaker: 0, text: trimmed)]
    }
    let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return [] }

    let ordered = segments.sorted { $0.start < $1.start }
    let totalDur = max(ordered.reduce(0.0) { $0 + max(0, $1.end - $1.start) }, 1e-9)
    var turns: [SpeakerTurn] = []
    var idx = 0
    for (i, d) in ordered.enumerated() {
      let share = max(0, d.end - d.start) / totalDur
      let count = i == ordered.count - 1
        ? words.count - idx
        : Int((share * Double(words.count)).rounded())
      let end = min(words.count, idx + max(0, count))
      guard end > idx else { continue }
      let slice = words[idx..<end].joined(separator: " ")
      idx = end
      if let last = turns.last, last.speaker == d.speaker {
        turns[turns.count - 1].text += " " + slice
      } else {
        turns.append(SpeakerTurn(speaker: d.speaker, text: slice))
      }
    }
    if idx < words.count, !turns.isEmpty {
      turns[turns.count - 1].text += " " + words[idx...].joined(separator: " ")
    }
    return turns
  }

  static func turnsToText(_ turns: [SpeakerTurn]) -> String {
    if turns.count <= 1 { return turns.first?.text ?? "" }
    return turns.map { "\(speakerLabel($0.speaker)): \($0.text)" }.joined(separator: "\n\n")
  }

  static func selfTest() {
    let segs = [
      SpeakerSegment(start: 0, end: 2, speaker: 0),
      SpeakerSegment(start: 2, end: 4, speaker: 1),
    ]
    let turns = buildSpeakerTurns(text: "one two three four", segments: segs)
    assert(turns.count == 2)
    assert(turns[0].speaker == 0 && turns[1].speaker == 1)
    assert(turnsToText(turns) == "Speaker 1: one two\n\nSpeaker 2: three four",
           "got \(turnsToText(turns).debugDescription)")
    assert(turnsToText(buildSpeakerTurns(text: "solo words", segments: [])) == "solo words")
    print("Diarizer selftest ok")
  }
}
