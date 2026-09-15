import AVFoundation
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Text AI for meetings: Apple's on-device model when this Mac has it (macOS 26+,
/// Apple Intelligence on), otherwise whatever the AI Cleanup setting routes to (Gemma, Ollama).
enum MeetingLLM {
  static var appleAvailable: Bool {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) { return SystemLanguageModel.default.availability == .available }
    #endif
    return false
  }

  static var available: Bool { appleAvailable || LLMRuntime.isAvailable }

  /// Plain-language state of Apple's on-device model for the dashboard.
  static var appleStatus: String {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      switch SystemLanguageModel.default.availability {
      case .available:
        return "On. Scribe uses it first for meeting names and summaries (English and other supported languages, not Hindi)."
      case .unavailable(.deviceNotEligible):
        return "This Mac doesn't support Apple Intelligence. Scribe uses the model below instead."
      case .unavailable(.appleIntelligenceNotEnabled):
        return "Turn on Apple Intelligence in System Settings and Scribe will use it for meeting names and summaries."
      case .unavailable(.modelNotReady):
        return "Not ready yet. Set your Mac and Siri to the same language (System Settings > Siri > Language), then let Apple Intelligence download."
      default:
        return "Not available right now. Scribe uses the model below instead."
      }
    }
    #endif
    return "Needs macOS 26 or later. Scribe uses the model below instead."
  }

  static var backendLabel: String {
    appleAvailable ? "Apple on-device model" : LLMRuntime.isAvailable ? "AI Cleanup model" : "none"
  }

  /// Blocking; call off the main thread.
  static func run(instruction: String, text: String, maxTokens: Int32 = 400) -> String? {
    let done = DispatchSemaphore(value: 0)
    var output: String?
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *), appleAvailable {
      Task.detached {
        do {
          let session = LanguageModelSession(instructions: instruction)
          output = try await session.respond(to: text).content
        } catch {
          dlog("meeting llm (apple): \(error)")
        }
        done.signal()
      }
      done.wait()
      if let output, !output.isEmpty { return output }
    }
    #endif
    guard LLMRuntime.isAvailable else { return nil }
    LLMRuntime.shared.process(instruction: instruction, text: text, maxTokens: maxTokens) {
      output = $0
      done.signal()
    }
    done.wait()
    return output?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Recording folder (you.caf + others.caf) to named, speaker-separated transcript,
/// summary and a playable meeting.m4a.
enum MeetingPipeline {
  static let you = 0

  struct Output {
    var turns: [SpeakerTurn]
    var names: [Int: String]
    var summary: String?
  }

  private struct Piece {
    let speaker: Int
    let range: Range<Int>
    var text = ""
  }

  /// Blocking; call off the main thread. `progress` is delivered on the main queue.
  static func run(
    dir: URL, spec: ModelSpec, language: String, provider: String, speakerCount: Int,
    progress: @escaping (String) -> Void
  ) -> Output {
    func report(_ s: String) { DispatchQueue.main.async { progress(s) } }
    let rate = TranscriptionLimits.sampleRate
    let you = AudioImport.decode(dir.appendingPathComponent("you.caf"))?.samples ?? []
    let others = AudioImport.decode(dir.appendingPathComponent("others.caf"))?.samples ?? []
    saveMix(you: you, others: others, to: dir.appendingPathComponent("meeting.m4a"))

    let limit = SileroVAD.maxSegmentSamples(for: spec.kind)
    var pieces = vadPieces(you, speaker: Self.you, limit: limit)
    var names = [Self.you: "You"]

    var othersPieces: [Piece] = []
    if SupportModelStore.diarInstalled, others.contains(where: { abs($0) > 0.001 }) {
      report("Separating speakers…")
      let segments = Diarizer.diarize(samples: others, sampleRate: rate, numSpeakers: speakerCount)
      othersPieces = segments.flatMap { seg -> [Piece] in
        let lo = max(0, Int(seg.start * Double(rate))), hi = min(others.count, Int(seg.end * Double(rate)))
        guard hi > lo else { return [] }
        return split(lo..<hi, limit: limit).map { Piece(speaker: 1 + seg.speaker, range: $0) }
      }
    }
    if othersPieces.isEmpty {
      othersPieces = vadPieces(others, speaker: 1, limit: limit)
    }
    for id in Set(othersPieces.map(\.speaker)) {
      names[id] = Set(othersPieces.map(\.speaker)).count > 1 ? Diarizer.speakerLabel(id - 1) : "Others"
    }
    pieces += othersPieces
    pieces.sort { $0.range.lowerBound < $1.range.lowerBound }

    for i in pieces.indices {
      report("Transcribing \(i + 1)/\(pieces.count)…")
      let samples = Array((pieces[i].speaker == Self.you ? you : others)[pieces[i].range])
      pieces[i].text = transcribe(samples, spec: spec, language: language, provider: provider)
    }

    var turns: [SpeakerTurn] = []
    for p in dropEcho(pieces.filter { !$0.text.isEmpty }) {
      if let last = turns.last, last.speaker == p.speaker {
        turns[turns.count - 1].text += " " + p.text
      } else {
        turns.append(SpeakerTurn(speaker: p.speaker, text: p.text))
      }
    }
    turns = turns.map { SpeakerTurn(speaker: $0.speaker, text: AudioImport.clean($0.text, spec: spec)) }

    var summary: String?
    if !turns.isEmpty, MeetingLLM.available {
      report("Finding speaker names…")
      names = nameSpeakers(turns, names: names)
      report("Summarising…")
      summary = summarize(text(turns, names: names))
    }
    return Output(turns: turns, names: names, summary: summary)
  }

  static func text(_ turns: [SpeakerTurn], names: [Int: String]) -> String {
    turns.map { "\(names[$0.speaker] ?? Diarizer.speakerLabel($0.speaker)): \($0.text)" }.joined(separator: "\n\n")
  }

  // MARK: - steps

  private static func transcribe(_ samples: [Float], spec: ModelSpec, language: String, provider: String) -> String {
    let done = DispatchSemaphore(value: 0)
    var text = ""
    NativeTranscriptionWorker.shared.transcribe(
      spec: spec, samples: samples, sampleRate: TranscriptionLimits.sampleRate,
      language: language, provider: provider, saveDiagnostic: false
    ) { result in
      switch result {
      case let .success(t): text = t.trimmingCharacters(in: .whitespacesAndNewlines)
      case let .failure(error): dlog("meeting transcribe: \(error.localizedDescription)")
      }
      done.signal()
    }
    done.wait()
    return text
  }

  private static func vadPieces(_ samples: [Float], speaker: Int, limit: Int) -> [Piece] {
    let ranges = SileroVAD.shared?.ranges16k(samples)
      ?? stride(from: 0, to: samples.count, by: limit).map { $0..<min(samples.count, $0 + limit) }
    return ranges.flatMap { split($0, limit: limit) }.map { Piece(speaker: speaker, range: $0) }
  }

  private static func split(_ r: Range<Int>, limit: Int) -> [Range<Int>] {
    let minimum = TranscriptionLimits.sampleRate * 2 / 5
    return stride(from: r.lowerBound, to: r.upperBound, by: limit)
      .map { $0..<min(r.upperBound, $0 + limit) }
      .filter { $0.count >= minimum }
  }

  /// Without headphones the mic hears the speakers; drop "You" pieces that repeat an
  /// overlapping piece from the system track.
  private static func dropEcho(_ pieces: [Piece]) -> [Piece] {
    let slack = TranscriptionLimits.sampleRate
    let system = pieces.filter { $0.speaker != you }
    return pieces.filter { p in
      guard p.speaker == you else { return true }
      let words = Set(p.text.lowercased().split(separator: " "))
      guard !words.isEmpty else { return false }
      return !system.contains { s in
        s.range.lowerBound - slack < p.range.upperBound && p.range.lowerBound < s.range.upperBound + slack
          && Double(words.intersection(Set(s.text.lowercased().split(separator: " "))).count) / Double(words.count) >= 0.6
      }
    }
  }

  static let namingInstruction =
    "You label speakers in a meeting transcript. A speaker's real name is known ONLY when the transcript states it: " +
    "they introduce themselves (\"I'm Jordan\", \"this is Jordan\", \"my name is Jordan\") or someone addresses them " +
    "by name and they answer. Never guess or invent names.\n" +
    "Output one line per speaker whose name is stated, exactly like: Speaker 2 = Jordan\n" +
    "Only use labels that appear in the transcript. Output the single word none if no names are stated."

  /// Only accepts names that literally occur in the transcript, so a model guess can't rename anyone.
  static func nameSpeakers(_ turns: [SpeakerTurn], names: [Int: String]) -> [Int: String] {
    let labelled = names.filter { $0.key != you }
    guard !labelled.isEmpty else { return names }
    let transcript = text(turns, names: names)
    guard let reply = MeetingLLM.run(instruction: namingInstruction, text: String(transcript.prefix(8000)), maxTokens: 120) else {
      return names
    }
    return applyNames(reply: reply, transcript: transcript, names: names)
  }

  static func applyNames(reply: String, transcript: String, names: [Int: String]) -> [Int: String] {
    var out = names
    let byLabel = Dictionary(uniqueKeysWithValues: names.filter { $0.key != you }.map { ($0.value.lowercased(), $0.key) })
    for line in reply.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 2, let id = byLabel[parts[0].lowercased()] else { continue }
      let name = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ".\"'`*"))
      guard (2...30).contains(name.count), name.first?.isLetter == true,
            transcript.range(of: name, options: .caseInsensitive) != nil else { continue }
      out[id] = name
    }
    return out
  }

  static let summaryInstruction =
    "Summarise this meeting transcript for the attendees. Use short bullet points under the headings " +
    "Key points, Decisions, Action items (write none when empty). Use speaker names as given. Same language as the transcript. " +
    "Do not add facts. Output only the summary."

  private static func summarize(_ transcript: String) -> String? {
    let chunk = 7000
    guard transcript.count > chunk else {
      return MeetingLLM.run(instruction: summaryInstruction, text: transcript, maxTokens: 500)
    }
    var start = transcript.startIndex
    var partials: [String] = []
    while start < transcript.endIndex {
      let end = transcript.index(start, offsetBy: chunk, limitedBy: transcript.endIndex) ?? transcript.endIndex
      if let s = MeetingLLM.run(instruction: summaryInstruction, text: String(transcript[start..<end]), maxTokens: 400) {
        partials.append(s)
      }
      start = end
    }
    guard !partials.isEmpty else { return nil }
    return MeetingLLM.run(
      instruction: "Merge these partial meeting summaries into one, keeping the same headings. Output only the summary.",
      text: partials.joined(separator: "\n\n"), maxTokens: 500
    )
  }

  /// Both tracks mixed to one AAC file the user can play back.
  private static func saveMix(you: [Float], others: [Float], to url: URL) {
    let count = max(you.count, others.count)
    guard count > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: TrackWriter.format, frameCapacity: AVAudioFrameCount(count)),
          let ch = buffer.floatChannelData else { return }
    for i in 0..<count {
      let a = i < you.count ? you[i] : 0, b = i < others.count ? others[i] : 0
      ch[0][i] = max(-1, min(1, a + b))
    }
    buffer.frameLength = AVAudioFrameCount(count)
    do {
      let file = try AVAudioFile(
        forWriting: url,
        settings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: TrackWriter.format.sampleRate,
          AVNumberOfChannelsKey: 1,
          AVEncoderBitRateKey: 32_000,
        ],
        commonFormat: .pcmFormatFloat32, interleaved: false
      )
      try file.write(from: buffer)
    } catch {
      dlog("meeting mix: \(error.localizedDescription)")
    }
  }

  static func selfTest() {
    let names = [0: "You", 1: "Speaker 1", 2: "Speaker 2"]
    let transcript = "Speaker 1: Hi, I'm Jordan.\n\nSpeaker 2: Thanks Jordan, this is Priya."
    let got = applyNames(reply: "Speaker 1 = Jordan\nSpeaker 2 = Priya\nYou = Kumar", transcript: transcript, names: names)
    assert(got[1] == "Jordan" && got[2] == "Priya" && got[0] == "You", "names applied: \(got)")
    let guessed = applyNames(reply: "Speaker 2 = Alex", transcript: transcript, names: names)
    assert(guessed[2] == "Speaker 2", "a name not in the transcript must be rejected")
    assert(applyNames(reply: "none", transcript: transcript, names: names) == names)
    print("meeting names: all assertions passed")
  }
}

