import Foundation
import CSherpa
import CLlama
import Speech
import Darwin

/// Headless test hooks: `Scribe --transcribe file.wav <model-id>` (sherpa) and
/// `Scribe --apple-transcribe file.wav <locale>` print the transcript and exit
/// without starting the UI.
enum DebugCLI {
  static func runIfRequested() {
    if CommandLine.arguments.contains("--selftest-commands") {
      VoiceCommands.selfTest()
      Diarizer.selfTest()
      Romanizer.selfTest()
      exit(0)
    }
    if CommandLine.arguments.contains("--selftest-transcription-safety") {
      transcriptionSafetySelfTest()
      exit(0)
    }
    runNativeWorkerIfRequested()
    runQwenAsrIfRequested()
    runLLMTestIfRequested()
    runAppleStreamIfRequested()
    runAppleIfRequested()
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

  /// `Scribe --llm-test model.gguf`, release memory/format benchmark hook.
  private static func runLLMTestIfRequested() {
    guard let path = argument(after: "--llm-test") else { return }
    guard let engine = LLMEngine(modelPath: path) else {
      FileHandle.standardError.write("LLM load failed\n".data(using: .utf8)!)
      exit(3)
    }
    let prompt = "<|im_start|>system\n" + LLMRuntime.cleanupInstruction +
      "<|im_end|>\n<|im_start|>user\n" +
      "um so i will send the report tomorrow okay<|im_end|>\n<|im_start|>assistant\n"
    let result = engine.generate(prompt: prompt, maxTokens: 80, temperature: 0.2)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    print(result)
    exit(result.isEmpty ? 1 : 0)
  }

  private static func argument(after flag: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
    return args[i + 1]
  }

  private static func transcriptionSafetySelfTest() {
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

  /// `Scribe --asr file.wav model.gguf mmproj.gguf`, headless Srota check.
  private static func runQwenAsrIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--asr"), args.count > i + 3 else { return }
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
    let resampled = SileroVAD.resampleTo16k(source, from: rate)
    let audio = Settings.shared.conditionAudio
      ? AudioConditioner.process16k(resampled) : resampled
    let maxN = SileroVAD.maxSegmentSamples
    let detected = SileroVAD.shared?.segments16k(audio) ?? []
    let base = detected.isEmpty ? [audio] : detected
    let windows = base.flatMap {
      SileroVAD.split($0, max: maxN, overlap: SileroVAD.hardSplitOverlapSamples)
    }
    var parts: [String] = []
    for window in windows where !window.isEmpty {
      let c = window.withUnsafeBufferPointer {
        cllama_asr_transcribe(h, $0.baseAddress, Int32(window.count), 16_000, 1024)
      }
      if let c {
        let cleaned = AsrRuntime.cleanOutput(String(cString: c))
        cllama_free_str(c)
        if !cleaned.isEmpty { parts.append(cleaned) }
      }
    }
    let text = TranscriptMerger.merge(parts)
    print(text)
    FileHandle.standardError.write("freeing…\n".data(using: .utf8)!)
    cllama_asr_free(h)
    FileHandle.standardError.write("freed ok\n".data(using: .utf8)!)
    exit(text.isEmpty ? 1 : 0)
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
