import Foundation
import CSherpa
import CLlama
import Speech

/// Headless test hooks: `Scribe --transcribe file.wav <model-id>` (sherpa) and
/// `Scribe --apple-transcribe file.wav <locale>` print the transcript and exit
/// without starting the UI.
enum DebugCLI {
  static func runIfRequested() {
    if CommandLine.arguments.contains("--selftest-commands") {
      VoiceCommands.selfTest()
      Romanizer.selfTest()
      exit(0)
    }
    runQwenAsrIfRequested()
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
    guard let engine = SherpaEngine(
      spec: spec,
      language: Settings.shared.language,
      provider: Settings.shared.sherpaProvider,
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

  /// `Scribe --asr file.wav model.gguf mmproj.gguf` — headless Srota check.
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
    let rate = wave.pointee.sample_rate
    let c = cllama_asr_transcribe(h, wave.pointee.samples, Int32(n), Int32(rate), 1024)
    let text = c.map { String(cString: $0) } ?? ""
    if let c { cllama_free_str(c) }
    print(AsrRuntime.cleanOutput(text))
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
    // SFSpeech delivers callbacks on the main queue — pump the run loop
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
    // `open --args` detaches stdout — leave the result somewhere readable
    try? out.write(toFile: "/tmp/scribe-apple-out.txt", atomically: true, encoding: .utf8)
    exit(out.isEmpty ? 1 : 0)
  }

  /// `--apple-stream file.wav <locale>` — feeds the WAV through the streaming
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
            startTask() // continue dictation — this is the fix under test
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
