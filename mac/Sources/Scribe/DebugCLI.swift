import Foundation
import AppKit
import SwiftUI
import AVFoundation
import CSherpa
import CLlama
import Speech
import Darwin
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Headless test hooks: `Scribe --transcribe file.wav <model-id>` (sherpa) and
/// `Scribe --apple-transcribe file.wav <locale>` print the transcript and exit
/// without starting the UI.
enum DebugCLI {
  static func runIfRequested() {
    if CommandLine.arguments.contains("--selftest-commands") {
      VoiceCommands.selfTest()
      Diarizer.selfTest()
      Romanizer.selfTest()
      Paster.selfTest()
      Vocabulary.selfTest()
      PauseChunker.selfTest()
      CorrectionWatcher.selfTest()
      OllamaRuntime.selfTest()
      MeetingPipeline.selfTest()
      exit(0)
    }
    if CommandLine.arguments.contains("--selftest-transcription-safety") {
      transcriptionSafetySelfTest()
      exit(0)
    }
    runMeetingCaptureTestIfRequested()
    runRenderDashboardIfRequested()
    runMeetingProcessIfRequested()
    runNativeWorkerIfRequested()
    runArkasrIfRequested()
    runQwenAsrServeIfRequested()
    runQwenAsrIfRequested()
    runLLMTestIfRequested()
    runOllamaTestIfRequested()
    runAppleStreamIfRequested()
    runAppleIfRequested()
    runTranscribeBatchIfRequested()
    runCleanupCompareIfRequested()
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--transcribe"), args.count > i + 2 else { return }
    let wavPath = args[i + 1]
    let modelId = args[i + 2]
    guard let spec = ModelCatalog.spec(modelId), spec.kind != .appleSystem else {
      FileHandle.standardError.write("unknown model id \(modelId)\n".data(using: .utf8)!)
      exit(2)
    }
    guard let wave = SherpaOnnxReadWave(wavPath) else {
      FileHandle.standardError.write("cannot read \(wavPath)\n".data(using: .utf8)!)
      exit(2)
    }
    defer { SherpaOnnxFreeWave(wave) }
    let provider = argument(after: "--provider")
      ?? Settings.shared.sherpaProvider(for: spec)
    guard let engine = SherpaEngine(
      spec: spec,
      language: argument(after: "--language") ?? Settings.shared.language,
      provider: provider,
    ) else {
      FileHandle.standardError.write("model load failed for \(modelId)\n".data(using: .utf8)!)
      exit(3)
    }
    let samples = [Float](UnsafeBufferPointer(
      start: wave.pointee.samples, count: Int(wave.pointee.num_samples)
    ))
    let rate = Int(wave.pointee.sample_rate)
    let text: String
    if spec.live {
      engine.startStream()
      _ = engine.feed(samples, sampleRate: rate)
      text = engine.finishStream(sampleRate: rate)
    } else {
      text = engine.transcribe(samples, sampleRate: rate)
    }
    print(text)
    exit(text.isEmpty ? 1 : 0)
  }

  /// `Scribe --transcribe-batch <list.txt> <model-id>`: loads the model once and prints one
  /// JSON string per WAV listed, in order and as each finishes (the parent counts lines for progress).
  private static func runTranscribeBatchIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--transcribe-batch"), args.count > i + 2,
          let spec = ModelCatalog.spec(args[i + 2]),
          let list = try? String(contentsOfFile: args[i + 1], encoding: .utf8) else { return }
    guard let engine = SherpaEngine(
      spec: spec,
      language: argument(after: "--language") ?? Settings.shared.language,
      provider: argument(after: "--provider") ?? Settings.shared.sherpaProvider(for: spec),
    ) else {
      FileHandle.standardError.write("model load failed for \(spec.id)\n".data(using: .utf8)!)
      exit(3)
    }
    setvbuf(stdout, nil, _IOLBF, 0)
    for path in list.split(separator: "\n") {
      var text = ""
      if let wave = SherpaOnnxReadWave(String(path)) {
        let samples = [Float](UnsafeBufferPointer(start: wave.pointee.samples, count: Int(wave.pointee.num_samples)))
        let rate = Int(wave.pointee.sample_rate)
        if spec.live {
          engine.startStream()
          _ = engine.feed(samples, sampleRate: rate)
          text = engine.finishStream(sampleRate: rate)
        } else {
          text = engine.transcribe(samples, sampleRate: rate)
        }
        SherpaOnnxFreeWave(wave)
      }
      let line = (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
      print(line)
    }
    exit(0)
  }

  /// `Scribe --cleanup-compare <samples.jsonl> <out.jsonl>`: each JSON-string line goes through the
  /// selected AI Cleanup model and Apple's on-device model with the dictation cleanup instruction,
  /// timed and judged by the same TranscriptCleanupValidator dictation uses.
  private static func runCleanupCompareIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--cleanup-compare"), args.count > i + 2,
          let input = try? String(contentsOfFile: args[i + 1], encoding: .utf8) else { return }
    let samples = input.split(separator: "\n").compactMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) }
    let out = URL(fileURLWithPath: args[i + 2])
    FileManager.default.createFile(atPath: out.path, contents: nil)
    var finished = false
    DispatchQueue.global().async {
      for (n, raw) in samples.enumerated() {
        var row: [String: Any] = ["raw": raw]
        let done = DispatchSemaphore(value: 0)
        var local: String?
        var start = Date()
        LLMRuntime.shared.process(instruction: LLMRuntime.cleanupInstruction, text: raw, maxTokens: 1024) {
          local = $0
          done.signal()
        }
        done.wait()
        row["local_ms"] = Int(Date().timeIntervalSince(start) * 1000)
        row["local"] = local ?? ""
        let l = TranscriptCleanupValidator.choose(raw: raw, cleaned: local)
        row["local_ok"] = l.accepted
        row["local_reason"] = l.reason
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.availability == .available {
          var apple: String?
          var failure = ""
          start = Date()
          Task.detached {
            do {
              let session = LanguageModelSession(instructions: LLMRuntime.cleanupInstruction)
              apple = try await session.respond(to: raw, options: GenerationOptions(temperature: 0.2)).content
            } catch {
              failure = String(describing: error)
            }
            done.signal()
          }
          done.wait()
          row["apple_ms"] = Int(Date().timeIntervalSince(start) * 1000)
          row["apple"] = apple ?? ""
          row["apple_error"] = String(failure.prefix(200))
          let a = TranscriptCleanupValidator.choose(raw: raw, cleaned: apple)
          row["apple_ok"] = a.accepted
          row["apple_reason"] = a.reason
        }
        #endif
        if let data = try? JSONSerialization.data(withJSONObject: row), let handle = try? FileHandle(forWritingTo: out) {
          handle.seekToEndOfFile()
          handle.write(data + Data("\n".utf8))
          try? handle.close()
        }
        FileHandle.standardError.write("cleanup-compare \(n + 1)/\(samples.count)\n".data(using: .utf8)!)
      }
      finished = true
    }
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    exit(0)
  }

  /// `Scribe --llm-test model.gguf`, release memory/format benchmark hook.
  private static func runLLMTestIfRequested() {
    guard let path = argument(after: "--llm-test") else { return }
    guard let engine = LLMEngine(modelPath: path) else {
      FileHandle.standardError.write("LLM load failed\n".data(using: .utf8)!)
      exit(3)
    }
    let result = engine.chat(
      system: LLMRuntime.cleanupInstruction,
      user: "um so i will send the report tomorrow okay",
      maxTokens: 80, temperature: 0.2
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    print(result)
    let line = "Speaker 2: haan Jordan bhai kal client call pe pricing discuss karna hai, deck ready rakhna. "
    let meeting = engine.chat(
      system: MeetingPipeline.summaryInstruction, user: String(repeating: line, count: 80),
      maxTokens: 200, temperature: 0.2
    )
    print("long prompt (\(line.count * 80) chars): \(meeting.prefix(200))")
    let tooLong = engine.chat(system: "", user: String(repeating: line, count: 900), maxTokens: 20, temperature: 0.2)
    exit(result.isEmpty || meeting.isEmpty || !tooLong.isEmpty ? 1 : 0)
  }

  /// `Scribe --ollama-test [model]`, checks the server is reachable and that a
  /// cleanup round-trip comes back as usable text.
  private static func runOllamaTestIfRequested() {
    guard CommandLine.arguments.contains("--ollama-test") else { return }
    var models: [String] = []
    var done = false
    OllamaRuntime.list { models = $0; done = true }
    while !done {
      _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    print("server: \(OllamaRuntime.host)")
    print("models: \(models.isEmpty ? "none" : models.joined(separator: ", "))")
    guard let model = argument(after: "--ollama-test") ?? models.first else { exit(1) }
    print("using:  \(model)")
    var reply: String??
    OllamaRuntime.chat(
      model: model, instruction: LLMRuntime.cleanupInstruction,
      text: "um so i will send the report tomorrow okay", maxTokens: 80
    ) { reply = $0 }
    while reply == nil {
      _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    let text = reply.flatMap { $0 } ?? ""
    print("reply:  \(text)")
    exit(text.isEmpty ? 1 : 0)
  }

  private static func argument(after flag: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
    return args[i + 1]
  }

  private static func transcriptionSafetySelfTest() {
    // A short clip keeps the flat floor; a long one must not be reaped early.
    precondition(TranscriptionLimits.workerTimeout(audioSeconds: 5) == 180)
    precondition(TranscriptionLimits.workerTimeout(audioSeconds: 60) == 240)
    precondition(TranscriptionLimits.workerTimeout(audioSeconds: 20 * 60) == 4800)

    precondition(TranscriptMerger.merge([
      "one two three", "two three four", "four five",
    ]) == "one two three four five")
    precondition(TranscriptMerger.merge([
      "Hello, world.", "world next",
    ]) == "Hello, world. next")
    let input = Array(repeating: Float(0), count: 30)
    let windows = SileroVAD.split(input, max: 10, overlap: 2)
    precondition(windows.map(\.count) == [10, 10, 10, 6])
    precondition(windows.allSatisfy { $0.count <= 10 })
    precondition(SileroVAD.paddedRanges(
      [10..<20, 40..<50], sampleCount: 60, padding: 5
    ) == [5..<25, 35..<55])
    precondition(SileroVAD.paddedRanges(
      [0..<4, 58..<65], sampleCount: 60, padding: 5
    ) == [0..<9, 53..<60])
    // Breath-sized segments must be glued back up to the window budget.
    let packed = SileroVAD.pack(
      [[Float](repeating: 1, count: 4), [Float](repeating: 2, count: 4),
       [Float](repeating: 3, count: 5), [Float](repeating: 4, count: 10)],
      limit: 10
    )
    precondition(packed.map(\.count) == [8, 5, 10], "pack: \(packed.map(\.count))")
    let retrySegments: [[Float]] = [
      Array(repeating: 1, count: 20),
      Array(repeating: 2, count: 4),
      Array(repeating: 3, count: 20),
    ]
    precondition(SileroVAD.retryWindow(
      segments: retrySegments, emptyIndex: 1, max: 12
    ) == Array(repeating: 2, count: 4) + Array(repeating: 3, count: 8))
    let punctuation = TranscriptCleanupValidator.choose(
      raw: "Let's verify RAM usage for GitHub record Jack.",
      cleaned: "Let's verify RAM usage for GitHub record Jack."
    )
    precondition(punctuation.accepted)
    let destructive = TranscriptCleanupValidator.choose(
      raw: "Let's verify RAM usage for GitHub record Jack.",
      cleaned: "The product is probably excellent."
    )
    precondition(!destructive.accepted)
    precondition(destructive.text.contains("RAM"))
    let lostAcronym = TranscriptCleanupValidator.choose(
      raw: "Check the RAM and CPU results now.",
      cleaned: "Check the memory results now."
    )
    precondition(!lostAcronym.accepted)
    // Punctuating and capitalizing is the whole job, and is allowed.
    precondition(TranscriptCleanupValidator.choose(
      raw: "hey john how are you doing today",
      cleaned: "Hey John, how are you doing today?"
    ).accepted)
    // Spoken numbers may become digits.
    precondition(TranscriptCleanupValidator.choose(
      raw: "can we meet at three thirty p m today",
      cleaned: "Can we meet at 3:30 PM today?"
    ).accepted)
    // Hinglish must survive untranslated.
    precondition(TranscriptCleanupValidator.choose(
      raw: "main kal miting mein aaunga",
      cleaned: "Main kal miting mein aaunga."
    ).accepted)
    precondition(!TranscriptCleanupValidator.choose(
      raw: "main kal miting mein aaunga",
      cleaned: "I will come to the meeting tomorrow."
    ).accepted)
    // Dropping a trailing sentence used to pass at the old 72% threshold.
    let truncated = TranscriptCleanupValidator.choose(
      raw: "first we ship the parser then we ship the encoder and after that we review everything",
      cleaned: "First we ship the parser, then we ship the encoder."
    )
    precondition(!truncated.accepted)
    precondition(truncated.text.contains("review everything"))
    let hot = TranscriptCleanupValidator.choose(
      raw: "Chamo 4 E2B on Scribe",
      cleaned: "Gemma 4 E2B on Scribe.",
      hotwords: ["Gemma", "E2B", "Scribe"]
    )
    precondition(hot.accepted, "hotword spelling must pass: \(hot.reason)")
    PauseChunker.selfTest()
    let silence = AudioConditioner.process16k(Array(repeating: 0, count: 16_000))
    precondition(silence.allSatisfy { $0 == 0 })
    let loud = (0..<16_000).map { i in
      Float(sin(2 * Double.pi * 220 * Double(i) / 16_000)) * 0.95
    }
    let conditioned = AudioConditioner.process16k(loud)
    precondition(conditioned.map(abs).max() ?? 0 <= 0.98)
    if Bundle.main.bundleURL.pathExtension == "app" {
      let info = Bundle.main.infoDictionary ?? [:]
      precondition((info["SUPublicEDKey"] as? String)?.count == 44)
      precondition((info["SUFeedURL"] as? String)?.hasPrefix("https://") == true)
      precondition(FileManager.default.fileExists(
        atPath: Bundle.main.privateFrameworksURL?
          .appendingPathComponent("Sparkle.framework").path ?? ""
      ))
    }
    print("transcription safety self-test passed")
  }

  /// End-to-end test hook for the same subprocess boundary used by dictation.
  /// `Scribe --worker-transcribe file.wav <model-id>`
  private static func runNativeWorkerIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--worker-transcribe"), args.count > i + 2 else { return }
    let wavPath = args[i + 1]
    guard let spec = ModelCatalog.spec(args[i + 2]),
          let wave = SherpaOnnxReadWave(wavPath) else {
      FileHandle.standardError.write("invalid worker test input\n".data(using: .utf8)!)
      exit(2)
    }
    let samples = [Float](UnsafeBufferPointer(
      start: wave.pointee.samples, count: Int(wave.pointee.num_samples)
    ))
    let sampleRate = Int(wave.pointee.sample_rate)
    SherpaOnnxFreeWave(wave)

    var done = false
    var exitCode: Int32 = 1
    NativeTranscriptionWorker.shared.transcribe(
      spec: spec, samples: samples, sampleRate: sampleRate,
      language: argument(after: "--language") ?? Settings.shared.language,
      provider: argument(after: "--provider") ?? Settings.shared.sherpaProvider(for: spec)
    ) { result in
      switch result {
      case let .success(text):
        print(text)
        exitCode = text.isEmpty ? 1 : 0
      case let .failure(error):
        FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
        exitCode = 1
      }
      done = true
    }
    while !done {
      _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    exit(exitCode)
  }

  /// `Scribe --arkasr file.wav <model-id>`, headless check for the Audio8
  /// ONNX bundles.
  private static func runArkasrIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--arkasr"), args.count > i + 2 else { return }
    guard let spec = ModelCatalog.spec(args[i + 2]) else {
      FileHandle.standardError.write("unknown model id \(args[i + 2])\n".data(using: .utf8)!)
      exit(2)
    }
    guard let wave = SherpaOnnxReadWave(args[i + 1]) else {
      FileHandle.standardError.write("cannot read \(args[i + 1])\n".data(using: .utf8)!)
      exit(2)
    }
    defer { SherpaOnnxFreeWave(wave) }
    let n = Int(wave.pointee.num_samples)
    let rate = Int(wave.pointee.sample_rate)
    let samples = [Float](UnsafeBufferPointer(start: wave.pointee.samples, count: n))
    let started = Date()
    do {
      let engine = try ArkasrRuntime.make(spec)
      let loaded = Date()
      let text = try engine.transcribe(samples: samples, sampleRate: rate)
      FileHandle.standardError.write(String(
        format: "load %.2fs | transcribe %.2fs | audio %.1fs\n",
        loaded.timeIntervalSince(started), Date().timeIntervalSince(loaded),
        Double(n) / Double(rate)).data(using: .utf8)!)
      print(text)
      exit(text.isEmpty ? 1 : 0)
    } catch {
      FileHandle.standardError.write("arkasr failed: \(error.localizedDescription)\n".data(using: .utf8)!)
      exit(3)
    }
  }

  /// `Scribe --asr-serve model.gguf mmproj.gguf [--asr-instruction "…"]`
  /// Loads once, then transcribes WAV paths from stdin until QUIT/EOF.
  private static func runQwenAsrServeIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--asr-serve"), args.count > i + 2 else { return }
    setbuf(stdout, nil)
    let instruction = argument(after: "--asr-instruction") ?? ""
    let latinOnly: Int32 = args.contains("--latin-only") ? 1 : 0
    guard let h = cllama_asr_load(args[i + 1], args[i + 2]) else {
      FileHandle.standardError.write("asr model load failed\n".data(using: .utf8)!)
      exit(3)
    }
    FileHandle.standardOutput.write("READY\n".data(using: .utf8)!)
    fflush(stdout)
    while let line = readLine(strippingNewline: true) {
      if line == "QUIT" { break }
      guard !line.isEmpty else { continue }
      let text: String
      if let wave = SherpaOnnxReadWave(line) {
        defer { SherpaOnnxFreeWave(wave) }
        let n = Int(wave.pointee.num_samples)
        let rate = Int(wave.pointee.sample_rate)
        let source = [Float](UnsafeBufferPointer(start: wave.pointee.samples, count: n))
        text = transcribeQwenAudio(
          h, samples: source, sampleRate: rate,
          instruction: instruction, latinOnly: latinOnly, vad: false
        )
      } else {
        text = ""
      }
      writeAsrServeResult(text)
    }
    cllama_asr_free(h)
    exit(0)
  }

  private static func writeAsrServeResult(_ text: String) {
    let data = text.data(using: .utf8) ?? Data()
    FileHandle.standardOutput.write("\(data.count)\n".data(using: .utf8)!)
    if !data.isEmpty { FileHandle.standardOutput.write(data) }
    fflush(stdout)
  }

  /// `Scribe --asr file.wav model.gguf mmproj.gguf [--asr-instruction "…"]`,
  /// headless multimodal ASR check and the one-shot worker fallback.
  private static func runQwenAsrIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--asr"), args.count > i + 3 else { return }
    let instruction = argument(after: "--asr-instruction") ?? ""
    let latinOnly: Int32 = args.contains("--latin-only") ? 1 : 0
    guard let wave = SherpaOnnxReadWave(args[i + 1]) else {
      FileHandle.standardError.write("cannot read \(args[i + 1])\n".data(using: .utf8)!)
      exit(2)
    }
    defer { SherpaOnnxFreeWave(wave) }
    guard let h = cllama_asr_load(args[i + 2], args[i + 3]) else {
      FileHandle.standardError.write("asr model load failed\n".data(using: .utf8)!)
      exit(3)
    }
    let n = Int(wave.pointee.num_samples)
    let rate = Int(wave.pointee.sample_rate)
    let source = [Float](UnsafeBufferPointer(start: wave.pointee.samples, count: n))
    let skipVad = args.contains("--asr-no-vad")
    let text = transcribeQwenAudio(
      h, samples: source, sampleRate: rate,
      instruction: instruction, latinOnly: latinOnly, vad: !skipVad
    )
    print(text)
    FileHandle.standardError.write("freeing…\n".data(using: .utf8)!)
    cllama_asr_free(h)
    FileHandle.standardError.write("freed ok\n".data(using: .utf8)!)
    exit(text.isEmpty ? 1 : 0)
  }

  private static func transcribeQwenAudio(
    _ h: OpaquePointer, samples: [Float], sampleRate: Int,
    instruction: String, latinOnly: Int32, vad: Bool
  ) -> String {
    let resampled = SileroVAD.resampleTo16k(samples, from: sampleRate)
    let audio = Settings.shared.conditionAudio
      ? AudioConditioner.process16k(resampled) : resampled
    let windows: [[Float]]
    if vad {
      let maxN = SileroVAD.maxSegmentSamples(for: .qwenAsr)
      let detected = SileroVAD.shared?.segments16k(audio) ?? []
      let base = detected.isEmpty ? [audio] : SileroVAD.pack(detected, limit: maxN)
      windows = base.flatMap {
        SileroVAD.split($0, max: maxN, overlap: SileroVAD.hardSplitOverlapSamples)
      }
    } else {
      windows = audio.isEmpty ? [] : [audio]
    }
    var parts: [String] = []
    for window in windows where !window.isEmpty {
      let c = window.withUnsafeBufferPointer {
        cllama_asr_transcribe(h, $0.baseAddress, Int32(window.count), 16_000, 1024,
                              instruction, latinOnly)
      }
      if let c {
        let cleaned = AsrRuntime.cleanOutput(String(cString: c))
        cllama_free_str(c)
        if !cleaned.isEmpty { parts.append(cleaned) }
      }
    }
    return TranscriptMerger.merge(parts)
  }

  private static func runAppleIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--apple-transcribe"), args.count > i + 2 else { return }
    let wavPath = args[i + 1]
    let localeId = args[i + 2]
    // SFSpeech delivers callbacks on the main queue, pump the run loop
    // instead of blocking, or this deadlocks before NSApplication starts.
    var authed = SFSpeechRecognizer.authorizationStatus() == .authorized
    if !authed {
      var waiting = true
      SFSpeechRecognizer.requestAuthorization { auth in
        authed = auth == .authorized
        waiting = false
      }
      pump(while: { waiting }, timeout: 20)
    }
    guard authed else {
      FileHandle.standardError.write("speech not authorized\n".data(using: .utf8)!)
      exit(2)
    }
    guard let r = SFSpeechRecognizer(locale: Locale(identifier: localeId)), r.isAvailable else {
      FileHandle.standardError.write("recognizer unavailable for \(localeId)\n".data(using: .utf8)!)
      exit(2)
    }
    let req = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: wavPath))
    if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
    req.addsPunctuation = true
    var out = ""
    var finished = false
    r.recognitionTask(with: req) { result, error in
      if let result {
        out = result.bestTranscription.formattedString
        if result.isFinal { finished = true }
      }
      if let error {
        FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
        finished = true
      }
    }
    pump(while: { !finished }, timeout: 60)
    print(out)
    // `open --args` detaches stdout, leave the result somewhere readable
    try? out.write(toFile: "/tmp/scribe-apple-out.txt", atomically: true, encoding: .utf8)
    exit(out.isEmpty ? 1 : 0)
  }

  /// `--apple-stream file.wav <locale>`, feeds the WAV through the streaming
  /// buffer recognizer in real-time-paced chunks, with the SAME commit+restart
  /// logic as live dictation, so it reproduces (and validates the fix for) the
  /// "stops after a few words" server-endpoint cutoff.
  private static func runAppleStreamIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--apple-stream"), args.count > i + 2 else { return }
    let wavPath = args[i + 1]
    let localeId = args[i + 2]

    var authed = SFSpeechRecognizer.authorizationStatus() == .authorized
    if !authed {
      var waiting = true
      SFSpeechRecognizer.requestAuthorization { auth in authed = auth == .authorized; waiting = false }
      pump(while: { waiting }, timeout: 20)
    }
    guard authed, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)),
          recognizer.isAvailable else {
      FileHandle.standardError.write("recognizer unavailable for \(localeId)\n".data(using: .utf8)!)
      exit(2)
    }
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: wavPath)) else {
      FileHandle.standardError.write("cannot read \(wavPath)\n".data(using: .utf8)!)
      exit(2)
    }

    let onDevice = recognizer.supportsOnDeviceRecognition
    FileHandle.standardError.write("onDevice=\(onDevice)\n".data(using: .utf8)!)

    var committed = ""
    var current = ""
    var request: SFSpeechAudioBufferRecognitionRequest?
    var restarts = 0
    let lock = NSLock()

    func startTask() {
      let req = SFSpeechAudioBufferRecognitionRequest()
      req.shouldReportPartialResults = true
      if onDevice { req.requiresOnDeviceRecognition = true }
      req.addsPunctuation = true
      lock.lock(); request = req; lock.unlock()
      _ = recognizer.recognitionTask(with: req) { result, error in
        if let result {
          let seg = result.bestTranscription.formattedString
          lock.lock(); current = seg; lock.unlock()
          if result.isFinal {
            lock.lock()
            if !seg.isEmpty { committed = [committed, seg].filter { !$0.isEmpty }.joined(separator: " ") }
            current = ""
            lock.unlock()
            restarts += 1
            startTask() // continue dictation, this is the fix under test
          }
        }
        if error != nil {
          lock.lock(); let c = committed; lock.unlock()
          if !c.isEmpty && restarts < 6 { restarts += 1; startTask() }
        }
      }
    }
    startTask()

    // Feed the file as 100 ms buffers, paced to wall-clock so the recognizer
    // sees the real pauses and endpoints exactly as it would live.
    let fmt = file.processingFormat
    let chunk = AVAudioFrameCount(fmt.sampleRate / 10)
    while file.framePosition < file.length {
      guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk),
            (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0 else { break }
      lock.lock(); request?.append(buf); lock.unlock()
      pump(while: { true }, timeout: 0.1)
    }
    lock.lock(); request?.endAudio(); lock.unlock()
    pump(while: { true }, timeout: onDevice ? 0.6 : 1.2) // let the last segment land

    lock.lock()
    var out = [committed, current].filter { !$0.isEmpty }.joined(separator: " ")
    lock.unlock()
    if args.contains("roman") { out = Romanizer.hinglish(out) }
    print(out)
    try? out.write(toFile: "/tmp/scribe-apple-out.txt", atomically: true, encoding: .utf8)
    try? "onDevice=\(onDevice) restarts=\(restarts)"
      .write(toFile: "/tmp/scribe-apple-diag.txt", atomically: true, encoding: .utf8)
    exit(out.isEmpty ? 1 : 0)
  }

  private static func pump(while condition: () -> Bool, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while condition() && Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
  }
}

/// `open -W -n Scribe.app --args --meeting-capture-test <seconds> <dir>` records the
/// mic and system audio tracks for N seconds and writes peaks to <dir>/result.txt.
/// Launch via `open` so TCC attributes the prompts to Scribe, not the terminal.
private func runMeetingCaptureTestIfRequested() {
  let args = CommandLine.arguments
  guard let i = args.firstIndex(of: "--meeting-capture-test"), args.count > i + 2,
        let seconds = Double(args[i + 1]) else { return }
  let dir = URL(fileURLWithPath: args[i + 2], isDirectory: true)
  var lines: [String] = []
  defer {
    try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    exit(0)
  }
  do {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mic = try TrackWriter(url: dir.appendingPathComponent("you.caf"))
    let system = try TrackWriter(url: dir.appendingPathComponent("others.caf"))
    guard #available(macOS 14.4, *) else { lines.append("unsupported"); return }
    let tap = SystemAudioTap(writer: system)
    try tap.start()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in mic.append(buffer) }
    try engine.start()
    lines.append("started")
    FileManager.default.createFile(atPath: dir.appendingPathComponent("started").path, contents: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    input.removeTap(onBus: 0)
    engine.stop()
    tap.stop()
    lines.append("micPeak=\(mic.peak) systemPeak=\(system.peak) tapCallbacks=\(tap.callbacks) tapInputPeak=\(tap.inputPeak) tapFormat=\(tap.formatLabel)")
  } catch {
    lines.append("error=\(error.localizedDescription)")
  }
}

/// `Scribe --render-dashboard <dir>` draws every dashboard tab to <dir>/<tab>.png.
private func runRenderDashboardIfRequested() {
  let args = CommandLine.arguments
  guard let i = args.firstIndex(of: "--render-dashboard"), args.count > i + 1 else { return }
  let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  _ = NSApplication.shared
  for tab in DashboardView.Tab.allCases {
    UserDefaults.standard.set(tab.rawValue, forKey: "dashboardTab")
    let host = NSHostingView(rootView: DashboardView())
    host.frame = NSRect(x: 0, y: 0, width: 920, height: 700)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(tab.rawValue).png"))
  }
  let recordings = MeetingRecorder.shared.recordings
  var shots = recordings.first(where: \.hasTranscript).map { m in MeetingDetailView.Mode.allCases.map { (m.id, $0, $0.rawValue) } } ?? []
  if let pending = recordings.first(where: { !$0.hasTranscript }) {
    MeetingRecorder.shared.enqueue(pending.id)
    shots.append((pending.id, .transcript, "queued"))
  }
  do {
    for (meetingDir, mode, name) in shots {
      let host = NSHostingView(rootView: ScrollView { MeetingDetailView(dir: meetingDir, mode: mode).padding(28) }
        .background(Color.black).environment(\.colorScheme, .dark))
      host.frame = NSRect(x: 0, y: 0, width: 760, height: 700)
      let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = host
      RunLoop.main.run(until: Date().addingTimeInterval(0.4))
      guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
      host.cacheDisplay(in: host.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("meeting-\(name).png"))
    }
  }
  UserDefaults.standard.set(DashboardView.Tab.home.rawValue, forKey: "dashboardTab")
  if let screen = NSScreen.main {
    let layout = NotchLayout(screen: screen)
    let host = NSHostingView(rootView: NotchHUDView(meeting: MeetingRecorder.shared, layout: layout))
    host.frame = NSRect(origin: .zero, size: layout.frame.size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
      host.cacheDisplay(in: host.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("notch.png"))
    }
    print("notch: hasNotch=\(layout.hasNotch) notchWidth=\(layout.notchWidth) frame=\(layout.frame)")
  }
  exit(0)
}

/// `Scribe --meeting-process <dir> <model-id>` runs the full meeting pipeline on a
/// recording folder (you.caf + others.caf), fetching the speaker models if missing.
private func runMeetingProcessIfRequested() {
  let args = CommandLine.arguments
  guard let i = args.firstIndex(of: "--meeting-process"), args.count > i + 2,
        let spec = ModelCatalog.spec(args[i + 2]) else { return }
  let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
  if !SupportModelStore.diarInstalled {
    print("downloading speaker models…")
    Task { @MainActor in SupportModelStore.shared.downloadDiarization() }
    let deadline = Date().addingTimeInterval(600)
    while !SupportModelStore.diarInstalled, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
  }
  print("speaker models: \(SupportModelStore.diarInstalled), llm: \(MeetingLLM.backendLabel)")
  var output: MeetingPipeline.Output?
  DispatchQueue.global().async {
    output = MeetingPipeline.run(
      dir: dir, spec: spec, language: Settings.shared.language,
      provider: Settings.shared.sherpaProvider(for: spec), speakerCount: args.count > i + 3 ? Int(args[i + 3]) ?? 0 : 0
    ) { print("  \($0)") }
  }
  while output == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
  let out = output!
  if !out.turns.isEmpty { MeetingDetail(out).save(to: dir) }
  print("NAMES: \(out.names.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })")
  print("TRANSCRIPT:\n" + MeetingPipeline.text(out.turns, names: out.names))
  print("SUMMARY:\n" + (out.summary ?? "(none)"))
  exit(0)
}

