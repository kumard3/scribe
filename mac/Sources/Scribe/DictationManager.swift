import Foundation
import AVFoundation
import Speech
import AppKit
import ObjCCatch

func dlog(_ s: String) {
  let url = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Scribe.log")
  let line = "\(Date()) \(s)\n"
  if let h = try? FileHandle(forWritingTo: url) {
    h.seekToEndOfFile()
    try? h.write(contentsOf: line.data(using: .utf8)!)
    try? h.close()
  } else {
    try? line.write(to: url, atomically: true, encoding: .utf8)
  }
}

/// On-device dictation. The active model decides the engine: Apple's
/// SFSpeechRecognizer (default), or a downloaded sherpa-onnx model —
/// streaming (live partials) or offline (transcribe on release).
final class DictationManager: ObservableObject {
  static let shared = DictationManager()

  enum Phase { case idle, listening, transcribing, postProcessing, inserted }

  @Published var isRecording = false
  @Published var lastText = ""
  @Published var level: Float = 0
  @Published var phase: Phase = .idle
  @Published var status = "Ready"
  @Published var history: [String] =
    (UserDefaults.standard.stringArray(forKey: "history") ?? [])

  private var engine = AVAudioEngine()
  private var recognizer: SFSpeechRecognizer?
  private var recognizerLocale = ""
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var wantsStop = false
  // Session buffer. Apple's recognizer hands us REPLACEMENTS (the whole current
  // utterance each time), and on a pause it throws that utterance away and
  // starts fresh — on macOS 26 on-device it does this silently, with no
  // isFinal. So we bank each finished utterance into appleCommitted the moment
  // a pause is detected (from mic silence); appleSegment is the live, not-yet-
  // banked utterance. lastText is always appleCommitted + appleSegment, so a
  // pause or stop can never wipe what came before.
  private var appleCommitted = ""
  private var appleSegment = ""
  private var appleGen = 0          // task generation; stale callbacks are ignored after a restart
  private var appleSilentFrames = 0 // trailing mic-silence (audio-thread only)
  private var appleErrorRestarts = 0

  private var sherpa: SherpaEngine?
  private var sherpaSamples: [Float] = []
  private var hwRate = 16000
  private var onBufferCurrent: ((AVAudioPCMBuffer) -> Void)?
  private var configObserver: NSObjectProtocol?
  private var poppedSinceStart = false
  private let sherpaQueue = DispatchQueue(label: "ai.scribe.sherpa")
  // ~15 min at 48 kHz; past this we stop buffering rather than grow unbounded
  private let maxBufferedSamples = 48_000 * 900

  func toggle() { isRecording ? stop() : start() }

  func start() {
    let spec = Settings.shared.activeModel
    dlog("start() isRecording=\(isRecording) model=\(spec.id)")
    wantsStop = false
    if spec.kind == .appleSystem {
      SFSpeechRecognizer.requestAuthorization { auth in
        DispatchQueue.main.async {
          dlog("speech auth=\(auth.rawValue)")
          guard auth == .authorized else {
            self.set("Enable Speech Recognition in System Settings"); return
          }
          self.requestMic { granted in
            dlog("mic granted=\(granted)")
            guard granted else { self.set("Enable Microphone in System Settings"); return }
            self.beginApple(spec)
          }
        }
      }
    } else {
      requestMic { granted in
        dlog("mic granted=\(granted)")
        guard granted else { self.set("Enable Microphone in System Settings"); return }
        self.beginSherpa(spec)
      }
    }
  }

  private func requestMic(_ done: @escaping (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      done(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    default:
      done(false)
    }
  }

  // MARK: - engine plumbing shared by both paths

  // macOS keeps the input device — and a Bluetooth headset pinned in HFP — claimed
  // until the AVAudioEngine instance is dropped; stop() alone does not release it.
  private func releaseEngine() {
    if let configObserver {
      NotificationCenter.default.removeObserver(configObserver)
      self.configObserver = nil
    }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    engine.reset() // settle the graph — dealloc mid-config-change throws (uncatchable)
    engine = AVAudioEngine()
  }

  // Releasing the device means every start renegotiates the input (Bluetooth
  // headsets flip HFP on/off), which fires a configuration change right after
  // engine.start() — and AVAudioEngine stops delivering buffers on config
  // change without auto-restarting. Rebuild the capture or we record silence.
  //
  // Reconfigure the SAME engine in place. Deallocating an engine whose graph
  // is mid-configuration-change throws from AUGraph teardown — an uncatchable
  // C++ exception that aborts the app. Dealloc only happens in stop(), when
  // the engine is settled.
  private func restartCapture() {
    guard isRecording, let onBuffer = onBufferCurrent else { return }
    dlog("audio config change — restarting capture")
    if let configObserver {
      NotificationCenter.default.removeObserver(configObserver)
      self.configObserver = nil
    }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    guard let rate = startEngine(onBuffer: onBuffer) else { return }
    if rate != hwRate {
      if sherpa != nil {
        dlog("hw rate changed \(hwRate) → \(rate), dropping \(sherpaSamples.count) buffered samples")
        sherpaSamples.removeAll()
      }
      hwRate = rate
    }
  }

  /// Installs the mic tap and starts the engine. Returns the hardware sample
  /// rate, or nil after reporting the failure via status.
  private func startEngine(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) -> Int? {
    engine.reset() // drop any stale graph state from previous runs / device switches
    let input = engine.inputNode
    // inputFormat is the real hardware format. outputFormat can report a stale
    // default (1ch 44.1kHz) that makes installTap throw "format mismatch", so
    // the tap must be installed with the hardware format. 0 Hz = no usable mic.
    let hw = input.inputFormat(forBus: 0)
    dlog("startEngine hw=\(hw.sampleRate)Hz ch=\(hw.channelCount)")
    guard hw.sampleRate > 0, hw.channelCount > 0 else {
      set("Mic unavailable — re-enable Microphone for Scribe in System Settings")
      return nil
    }
    input.removeTap(onBus: 0)
    // installTap raises ObjC NSExceptions Swift can't catch — route through
    // the ObjCCatch shim so a bad audio state can't kill the app.
    // The "Pop" cue fires on the FIRST delivered buffer, not on engine.start()
    // — with Bluetooth the capture renegotiates for ~1s after start, and a cue
    // before audio actually flows makes users talk into a dead window.
    poppedSinceStart = false
    let exception = ScribeTryCatch {
      input.installTap(onBus: 0, bufferSize: 1024, format: hw) { [weak self] buffer, _ in
        guard let self else { return }
        if !self.poppedSinceStart {
          self.poppedSinceStart = true
          DispatchQueue.main.async { NSSound(named: "Pop")?.play() }
        }
        onBuffer(buffer)
        if let ch = buffer.floatChannelData?[0] {
          let n = Int(buffer.frameLength)
          var sum: Float = 0
          for i in 0..<n { sum += ch[i] * ch[i] }
          let rms = n > 0 ? sqrtf(sum / Float(n)) : 0
          DispatchQueue.main.async { self.level = min(1, rms * 14) }
        }
      }
      self.engine.prepare()
    }
    if let exception {
      dlog("installTap exception: \(exception.reason ?? "?")")
      releaseEngine()
      set("Mic error: \(exception.reason ?? exception.name.rawValue)")
      return nil
    }
    do {
      try engine.start()
      dlog("engine started")
    } catch {
      dlog("engine.start error: \(error)")
      releaseEngine()
      set("Audio engine error: \(error.localizedDescription)")
      return nil
    }
    onBufferCurrent = onBuffer
    configObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in self?.restartCapture() }
    return Int(hw.sampleRate)
  }

  private func markListening() {
    lastText = ""
    isRecording = true
    phase = .listening
    set("Listening…")
    HUD.shared.show()
    if wantsStop {
      wantsStop = false
      stop()
    }
  }

  // MARK: - Apple path

  private func beginApple(_ spec: ModelSpec) {
    guard !isRecording else { return }
    if recognizer == nil || recognizerLocale != spec.locale {
      recognizer = SFSpeechRecognizer(locale: Locale(identifier: spec.locale))
      recognizerLocale = spec.locale
      dlog("apple recognizer locale=\(spec.locale) onDevice=\(recognizer?.supportsOnDeviceRecognition ?? false)")
    }
    guard let recognizer, recognizer.isAvailable else {
      set("\(spec.label) isn’t available on this Mac")
      return
    }

    sherpa = nil
    appleCommitted = ""
    appleSegment = ""
    appleSilentFrames = 0
    appleErrorRestarts = 0
    // One tap feeds whatever self.request currently points at, so restarting
    // the recognition task mid-recording is seamless — the engine never stops.
    guard let rate = startEngine(onBuffer: { [weak self] buffer in
      self?.request?.append(buffer)
      self?.detectApplePause(buffer)
    }) else { return }
    hwRate = rate

    startAppleTask(recognizer)
    markListening()
  }

  /// Banks the current utterance after ~1.2 s of trailing mic silence — a real
  /// pause boundary, so we restart the recognizer on OUR terms instead of
  /// letting it silently drop the utterance. Runs on the audio thread.
  private func detectApplePause(_ buffer: AVAudioPCMBuffer) {
    guard let ch = buffer.floatChannelData?[0] else { return }
    let n = Int(buffer.frameLength)
    var sum: Float = 0
    for i in 0..<n { sum += ch[i] * ch[i] }
    let rms = n > 0 ? sqrtf(sum / Float(n)) : 0
    if rms < 0.01 { appleSilentFrames += n } else { appleSilentFrames = 0 }
    if appleSilentFrames >= Int(Float(hwRate) * 1.2) {
      appleSilentFrames = 0
      DispatchQueue.main.async { [weak self] in
        guard let self, self.isRecording, !self.appleSegment.isEmpty,
              let recognizer = self.recognizer, recognizer.isAvailable else { return }
        dlog("apple pause — banking \(self.appleSegment.count) chars")
        self.appleAdvance(afterError: false)
      }
    }
  }

  /// Creates a fresh recognition request + task. The mic tap keeps running and
  /// feeds the new request, so this can be called repeatedly to stitch
  /// endpoint-split segments into one continuous dictation.
  private func startAppleTask(_ recognizer: SFSpeechRecognizer) {
    task?.cancel() // stop the old task; its trailing callbacks are gen-fenced below
    appleGen += 1
    let gen = appleGen
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
    req.addsPunctuation = true
    request = req

    task = recognizer.recognitionTask(with: req) { [weak self] result, error in
      guard let self else { return }
      let segment = result?.bestTranscription.formattedString
      let isFinal = result?.isFinal ?? false
      DispatchQueue.main.async {
        guard gen == self.appleGen else { return } // ignore a cancelled task's late callbacks
        if let segment {
          self.appleErrorRestarts = 0
          // Backstop for a pause we didn't catch via silence: the recognizer
          // replaced the utterance with a shorter, different one — bank the old.
          if self.isUtteranceReset(previous: self.appleSegment, now: segment) {
            self.appleCommitted = [self.appleCommitted, self.appleSegment]
              .filter { !$0.isEmpty }.joined(separator: " ")
            dlog("apple utterance reset; committed=\(self.appleCommitted.count)")
          }
          self.appleSegment = segment
          let raw = [self.appleCommitted, self.appleSegment]
            .filter { !$0.isEmpty }.joined(separator: " ")
          self.lastText = self.applyRomanization(raw)
          if isFinal { self.appleAdvance(afterError: false) }
        }
        if let error {
          dlog("apple recognition error: \(error.localizedDescription)")
          self.appleAdvance(afterError: true)
        }
      }
    }
  }

  /// True when `now` is a brand-new utterance rather than a continuation of
  /// `previous`. SFSpeechRecognizer only revises the tail of the current
  /// transcription, so a shorter string whose head no longer matches means the
  /// recognizer dropped the old utterance and started fresh.
  private func isUtteranceReset(previous: String, now: String) -> Bool {
    guard previous.split(separator: " ").count >= 4 else { return false }
    guard now.count < previous.count else { return false }
    return !previous.lowercased().hasPrefix(now.lowercased())
  }

  /// Hinglish-Roman mode keeps appleCommitted in raw Devanagari and romanizes
  /// only the visible/pasted text, so accumulation stays on whole words.
  private func applyRomanization(_ raw: String) -> String {
    Settings.shared.activeModel.romanize ? Romanizer.hinglish(raw) : raw
  }

  /// The current utterance finished (isFinal, length cap, or error). Commit the
  /// live segment and, while still recording, start the next task so dictation
  /// keeps going.
  private func appleAdvance(afterError: Bool) {
    if !appleSegment.isEmpty {
      appleCommitted = [appleCommitted, appleSegment].filter { !$0.isEmpty }.joined(separator: " ")
      appleSegment = ""
    }
    guard isRecording, let recognizer, recognizer.isAvailable else { return }
    if afterError {
      // Only auto-recover once we've actually transcribed something, and cap
      // it so a dead network (server languages) can't spin forever.
      guard !appleCommitted.isEmpty else {
        dlog("apple error before any text — not restarting")
        return
      }
      appleErrorRestarts += 1
      guard appleErrorRestarts <= 6 else {
        set("Speech engine stopped — this language may need internet. Try a downloaded model.")
        return
      }
    }
    dlog("apple task restart committed=\(appleCommitted.count) err=\(appleErrorRestarts)")
    startAppleTask(recognizer)
  }

  // MARK: - sherpa path

  private func beginSherpa(_ spec: ModelSpec) {
    guard !isRecording else { return }
    guard ModelStore.tokensFile(in: ModelStore.dir(for: spec)) != nil else {
      set("\(spec.label) isn’t downloaded — get it in the Dashboard")
      return
    }
    request = nil
    task = nil
    set("Loading \(spec.label)…")
    sherpaQueue.async { [weak self] in
      let loaded = SherpaEngineCache.shared.engine(
        for: spec,
        language: Settings.shared.language,
        provider: Settings.shared.sherpaProvider,
      )
      DispatchQueue.main.async {
        guard let self else { return }
        guard let loaded else {
          self.set("Couldn’t load \(spec.label) — re-download it in the Dashboard")
          return
        }
        guard !self.isRecording else { return }
        self.sherpa = loaded
        self.sherpaSamples = []
        if spec.live {
          self.sherpaQueue.async { loaded.startStream() }
        }
        guard let rate = self.startEngine(onBuffer: { [weak self] buffer in
          self?.consumeSherpa(buffer)
        }) else { return }
        self.hwRate = rate
        self.markListening()
      }
    }
  }

  private func consumeSherpa(_ buffer: AVAudioPCMBuffer) {
    guard let ch = buffer.floatChannelData?[0] else { return }
    let samples = [Float](UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
    sherpaQueue.async { [weak self] in
      guard let self, let sherpa = self.sherpa else { return }
      if sherpa.spec.live {
        let text = sherpa.feed(samples, sampleRate: self.hwRate)
        DispatchQueue.main.async { self.lastText = text }
      } else if self.sherpaSamples.count < self.maxBufferedSamples {
        self.sherpaSamples.append(contentsOf: samples)
      }
    }
  }

  // MARK: - stop

  func stop() {
    dlog("stop() isRecording=\(isRecording)")
    guard isRecording else {
      // Hotkey released before the engine finished starting.
      wantsStop = true
      return
    }
    releaseEngine()
    isRecording = false
    level = 0

    if let sherpa {
      if sherpa.spec.live {
        set("Ready")
        let rate = hwRate
        sherpaQueue.async { [weak self] in
          let text = sherpa.finishStream(sampleRate: rate)
          DispatchQueue.main.async { self?.finish(with: text) }
        }
      } else {
        phase = .transcribing
        set("Transcribing…")
        let rate = hwRate
        sherpaQueue.async { [weak self] in
          guard let self else { return }
          let samples = self.sherpaSamples
          self.sherpaSamples = []
          let text = sherpa.transcribe(samples, sampleRate: rate)
          dlog("sherpa transcribed \(text.count) chars from \(samples.count) samples")
          DispatchQueue.main.async {
            self.set("Ready")
            self.finish(with: text)
          }
        }
      }
      self.sherpa = nil
      return
    }

    request?.endAudio()
    task?.finish()
    task = nil
    request = nil
    set("Ready")
    // Give the recognizer time to flush its final segment (which carries the
    // last word or two still in flight) before we read lastText. The server
    // path used for hi-IN needs a round trip, so this is generous.
    let delay = (recognizer?.supportsOnDeviceRecognition ?? true) ? 0.2 : 0.5
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      self.finish(with: self.lastText)
    }
  }

  private func finish(with text: String) {
    let finalText = VoiceCommands.apply(text)
    dlog("finish text=\(finalText.count) chars")
    lastText = finalText
    guard !finalText.isEmpty else {
      set("No speech detected — check the mic and the model in Dashboard → Models")
      phase = .idle
      HUD.shared.hide()
      return
    }

    // Optional on-device AI cleanup before insertion (Gemma 4). Runs off the
    // main thread; falls back to the raw text on any failure.
    let llm = ModelCatalog.llmModel
    if Settings.shared.autoCleanLLM,
       let path = ModelStore.ggufFile(in: ModelStore.dir(for: llm))?.path {
      phase = .postProcessing
      set("Cleaning up…")
      LLMRuntime.shared.process(
        modelPath: path, instruction: LLMRuntime.cleanupInstruction,
        text: finalText, maxTokens: 1024
      ) { cleaned in
        self.insertAndFinalize(cleaned ?? finalText)
      }
      return
    }
    insertAndFinalize(finalText)
  }

  private func insertAndFinalize(_ text: String) {
    lastText = text
    let pasted = Paster.insert(text)
    if !pasted {
      set("Copied to clipboard — grant Accessibility for auto-paste")
    }
    if Settings.shared.saveHistory {
      history.insert(text, at: 0)
      if history.count > 50 { history.removeLast(history.count - 50) }
      UserDefaults.standard.set(history, forKey: "history")
    }
    phase = .inserted
    NSSound(named: "Pop")?.play()
    HUD.shared.hide(after: 0.9)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
      if self.phase == .inserted { self.phase = .idle }
    }
  }

  private func set(_ s: String) {
    DispatchQueue.main.async { self.status = s }
  }
}
