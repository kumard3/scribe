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
        return "On. Bolkit uses it first for meeting names and summaries (English and other supported languages, not Hindi)."
      case .unavailable(.deviceNotEligible):
        return "This Mac doesn't support Apple Intelligence. Bolkit uses the model below instead."
      case .unavailable(.appleIntelligenceNotEnabled):
        return "Turn on Apple Intelligence in System Settings and Bolkit will use it for meeting names and summaries."
      case .unavailable(.modelNotReady):
        return "Not ready yet. Set your Mac and Siri to the same language (System Settings > Siri > Language), then let Apple Intelligence download."
      default:
        return "Not available right now. Bolkit uses the model below instead."
      }
    }
    #endif
    return "Needs macOS 26 or later. Bolkit uses the model below instead."
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

  struct Piece {
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
    let mic = AudioImport.decode(dir.appendingPathComponent("you.caf"))?.samples ?? []
    let others = AudioImport.decode(dir.appendingPathComponent("others.caf"))?.samples ?? []
    saveMix(you: mic, others: others, to: dir.appendingPathComponent("meeting.m4a"))

    let limit = SileroVAD.maxSegmentSamples(for: spec.kind)
    let you = suppressEcho(mic: mic, system: others)
    var pieces = vadPieces(you, speaker: Self.you, limit: limit)
    var names = [Self.you: "You"]

    var othersPieces: [Piece] = []
    if others.contains(where: { abs($0) > 0.001 }) {
      report("Separating speakers…")
      let sortformer = speakerCount <= SortformerMeeting.maxSpeakers
        ? SortformerMeeting.diarize(samples: others).flatMap { $0.isEmpty ? nil : $0 } : nil
      let segments = sortformer ?? (SupportModelStore.diarInstalled
        ? Diarizer.diarize(samples: others, sampleRate: rate, numSpeakers: speakerCount) : [])
      dlog("meeting speakers: \(sortformer != nil ? "sortformer" : "pyannote"), \(Set(segments.map(\.speaker)).count) speaker(s), \(segments.count) segment(s)")
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

    if spec.kind == .appleSystem, #available(macOS 26.0, *) {
      report("Transcribing your side…")
      place(appleWords(you, locale: spec.locale), into: &pieces) { $0 == Self.you }
      report("Transcribing the call…")
      place(appleWords(others, locale: spec.locale), into: &pieces) { $0 != Self.you }
    } else {
      let clips = pieces.map { Array(($0.speaker == Self.you ? you : others)[$0.range]) }
      do {
        let texts = try NativeTranscriptionWorker.shared.transcribeBatch(
          spec: spec, clips: clips, sampleRate: rate, language: language, provider: provider,
          progress: { report("Transcribing \($0)/\(clips.count)…") }
        )
        for i in pieces.indices { pieces[i].text = texts[i].trimmingCharacters(in: .whitespacesAndNewlines) }
      } catch {
        dlog("meeting batch unavailable (\(error.localizedDescription)), transcribing clip by clip")
        for i in pieces.indices {
          report("Transcribing \(i + 1)/\(pieces.count)…")
          pieces[i].text = transcribe(clips[i], spec: spec, language: language, provider: provider)
        }
      }
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

  static var appleSpeechAvailable: Bool {
    if #available(macOS 26.0, *) { return AppleLongForm.available }
    return false
  }

  /// Apple speech when it's on and available, otherwise the dictation model.
  static var meetingModel: ModelSpec {
    Settings.shared.meetingAppleSpeech && appleSpeechAvailable
      ? ModelCatalog.spec(ModelCatalog.systemId) ?? Settings.shared.activeModel
      : Settings.shared.activeModel
  }

  static func canTranscribe(_ spec: ModelSpec) -> Bool {
    if spec.kind == .appleSystem {
      if #available(macOS 26.0, *) { return AppleLongForm.available }
      return false
    }
    return spec.kind != .llm && AudioImport.installed(spec)
  }

  @available(macOS 26.0, *)
  private static func appleWords(_ samples: [Float], locale: String) -> [AppleLongForm.Word] {
    // SpeechAnalyzer never returns on an empty or silent file (a meeting without system audio hung here).
    guard samples.contains(where: { abs($0) > 0.001 }) else { return [] }
    let done = DispatchSemaphore(value: 0)
    var words: [AppleLongForm.Word] = []
    let task = Task.detached {
      do {
        words = try await AppleLongForm.words(samples: samples, sampleRate: TranscriptionLimits.sampleRate, locale: locale)
      } catch {
        dlog("meeting apple transcribe: \(error.localizedDescription)")
      }
      done.signal()
    }
    let seconds = Double(samples.count) / Double(TranscriptionLimits.sampleRate)
    guard done.wait(timeout: .now() + seconds + 120) == .success else {
      task.cancel()
      dlog("meeting apple transcribe: timed out after \(Int(seconds + 120)) s")
      return []
    }
    return words
  }

  /// Apple's sentence-sized chunks stay whole: each goes to the piece of its track it overlaps most,
  /// or the nearest within a second. Word-by-word placement cut sentences at every diarization boundary.
  @available(macOS 26.0, *)
  static func place(_ words: [AppleLongForm.Word], into pieces: inout [Piece], track: (Int) -> Bool) {
    let rate = Double(TranscriptionLimits.sampleRate)
    let ranges = pieces.map(\.range)
    let candidates = pieces.indices.filter { track(pieces[$0].speaker) }
    var start = 0
    while start < words.count {
      var end = start
      while end < words.count, words[end].phrase == words[start].phrase { end += 1 }
      let chunk = words[start..<end]
      let lo = Int(chunk.first!.start * rate), hi = max(Int(chunk.last!.end * rate), lo + 1)
      func score(_ i: Int) -> Int {
        let overlap = min(hi, ranges[i].upperBound) - max(lo, ranges[i].lowerBound)
        return overlap > 0 ? overlap : -min(abs(ranges[i].lowerBound - hi), abs(lo - ranges[i].upperBound))
      }
      if let best = candidates.max(by: { score($0) < score($1) }), score(best) >= -Int(rate) {
        let text = chunk.map(\.text).joined(separator: " ")
        pieces[best].text += pieces[best].text.isEmpty ? text : " " + text
      }
      start = end
    }
  }

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

  /// Without headphones the mic carries the call at a steady fraction of its level (0.12 measured on a
  /// real call). Mic frames under twice that expected leak, over the last 200 ms of call audio, are
  /// silenced so only your own voice reaches VAD and ASR. With headphones the leak is ~0 and nothing is cut.
  static func suppressEcho(mic: [Float], system: [Float]) -> [Float] {
    let frame = TranscriptionLimits.sampleRate / 100
    let count = min(mic.count, system.count) / frame
    func rms(_ a: [Float], _ f: Int) -> Float {
      var sum: Float = 0
      for i in (f * frame)..<((f + 1) * frame) { sum += a[i] * a[i] }
      return (sum / Float(frame)).squareRoot()
    }
    let em = (0..<count).map { rms(mic, $0) }
    let es = (0..<count).map { rms(system, $0) }
    guard count > 0 else { return mic }
    let loud = max(es.sorted()[count * 8 / 10], 0.01)
    let ratios = (0..<count).filter { es[$0] > loud }.map { em[$0] / es[$0] }.sorted()
    guard ratios.count > 500 else { return mic }
    let leak = ratios[ratios.count / 2]
    var out = mic
    for f in 0..<count {
      let tail = es[max(0, f - 20)...min(count - 1, f + 2)].max() ?? 0
      if em[f] < 2 * leak * tail {
        for i in (f * frame)..<((f + 1) * frame) { out[i] = 0 }
      }
    }
    return out
  }

  /// Without headphones the mic hears the speakers; drop "You" pieces whose words mostly repeat
  /// what the system track said around the same time. One mic piece often spans several system pieces.
  static func dropEcho(_ pieces: [Piece]) -> [Piece] {
    let slack = TranscriptionLimits.sampleRate
    let system = pieces.filter { $0.speaker != you }
    func words(_ s: String) -> Set<String> {
      Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
    return pieces.filter { p in
      guard p.speaker == you else { return true }
      let mine = words(p.text)
      guard !mine.isEmpty else { return false }
      let heard = system
        .filter { $0.range.lowerBound - slack < p.range.upperBound && p.range.lowerBound < $0.range.upperBound + slack }
        .reduce(into: Set<String>()) { $0.formUnion(words($1.text)) }
      return Double(mine.intersection(heard).count) / Double(mine.count) < 0.6
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
      guard (2...30).contains(name.count), name.first?.isUppercase == true,
            !["none", "unknown", "n/a", "not stated"].contains(name.lowercased()),
            !name.lowercased().hasPrefix("speaker"),
            transcript.range(of: name, options: .caseInsensitive) != nil else { continue }
      // "I'll let you know, Jim" is said TO Jim: a speaker who says the name without introducing themselves isn't Jim.
      let label = names[id] ?? ""
      let own = transcript.components(separatedBy: "\n\n").filter { $0.hasPrefix(label + ":") }.joined(separator: " ")
      let intro = "(i'm|i am|this is|my name is|it's) \(NSRegularExpression.escapedPattern(for: name))\\b"
      if own.range(of: name, options: .caseInsensitive) != nil,
         own.range(of: intro, options: [.regularExpression, .caseInsensitive]) == nil { continue }
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
      instruction: "These are summaries of consecutive parts of ONE meeting. Write a single summary of the whole meeting " +
        "with each heading (Key points, Decisions, Action items) exactly once, and short bullet points under each. " +
        "Combine and de-duplicate the bullets. Output only the summary.",
      text: partials.joined(separator: "\n\n"), maxTokens: 900
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
    let s = TranscriptionLimits.sampleRate
    let echoCase = dropEcho([
      Piece(speaker: 1, range: 0..<(4 * s), text: "So this is like this doesn't have to be ready by Friday like this can be later"),
      Piece(speaker: 1, range: (4 * s)..<(6 * s), text: "It's fine."),
      Piece(speaker: 2, range: (6 * s)..<(12 * s), text: "Hey, I just checked because we need to have MOI and MOI is an add-on of Stripe."),
      Piece(speaker: you, range: (1 * s)..<(12 * s), text: "So this and like this doesn't have to be ready by Friday like just can be later it's fine. Yeah yeah I just checked it because we need to have MOI and MOI is an add on of Stripe"),
      Piece(speaker: you, range: (20 * s)..<(22 * s), text: "Polar, the US one"),
    ])
    precondition(echoCase.filter { $0.speaker == you }.map(\.text) == ["Polar, the US one"], "echo: \(echoCase.map(\.text))")
    // 30 s: the call talks for 0-20 s and leaks into the mic at 0.12; you talk alone at 22-25 s and over the call at 10-12 s.
    let rate = TranscriptionLimits.sampleRate
    let call = (0..<(30 * rate)).map { i -> Float in i < 20 * rate ? 0.2 * sin(Float(i) * 0.05) : 0 }
    let mine = (0..<(30 * rate)).map { i -> Float in (22 * rate..<25 * rate).contains(i) || (10 * rate..<12 * rate).contains(i) ? 0.1 * sin(Float(i) * 0.031) : 0 }
    let mic = zip(call, mine).map { 0.12 * $0 + $1 }
    let cleaned = suppressEcho(mic: mic, system: call)
    func energy(_ a: [Float], _ r: Range<Int>) -> Float { a[r].reduce(0) { $0 + $1 * $1 } }
    precondition(energy(cleaned, (2 * rate)..<(8 * rate)) == 0, "echo-only audio must be silenced")
    precondition(energy(cleaned, (22 * rate)..<(25 * rate)) > 0.9 * energy(mic, (22 * rate)..<(25 * rate)), "your voice alone must be kept")
    precondition(energy(cleaned, (10 * rate + rate / 4)..<(12 * rate)) > 0.5 * energy(mic, (10 * rate + rate / 4)..<(12 * rate)), "you over the call must be kept")
    precondition(applyNames(reply: "Speaker 2 = Jordan", transcript: transcript, names: names)[2] == "Speaker 2",
                 "Speaker 2 said 'Thanks Jordan', so Speaker 2 is not Jordan")
    precondition(applyNames(reply: "Speaker 1 = Jim", transcript: "Speaker 1: I will let you know, Jim.\n\nSpeaker 2: Sure.", names: names)[1] == "Speaker 1")
    precondition(applyNames(reply: "Speaker 1 = none\nSpeaker 2 = Unknown", transcript: transcript + " none of it, unknown", names: names) == names)
    print("meeting names: all assertions passed")
  }
}

