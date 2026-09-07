import Foundation
import AVFoundation
import Speech
import AppKit
import ObjCCatch
import FluidAudio

func dlog(_ s: String) {
  NSLog("Scribe %@", s)
  let url = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Scribe.log")
  let line = "\(Date()) \(s)\n"
  guard let data = line.data(using: .utf8) else { return }
  if FileManager.default.fileExists(atPath: url.path),
     let h = try? FileHandle(forWritingTo: url) {
    defer { try? h.close() }
    h.seekToEndOfFile()
    try? h.write(contentsOf: data)
  } else {
    try? data.write(to: url)
  }
}

/// On-device dictation. The active model decides the engine: Apple's
/// SFSpeechRecognizer (default), or a downloaded sherpa-onnx model,
/// streaming (live partials) or offline (transcribe on release).
final class DictationManager: ObservableObject, @unchecked Sendable {
  static let shared = DictationManager()

  enum Phase { case idle, listening, transcribing, postProcessing, inserted }

  @Published var isRecording = false
  @Published var lastText = ""
  @Published var lastPendingText = ""
  @Published var lastRawText = ""
  @Published var level: Float = 0
  @Published var phase: Phase = .idle
  @Published var status = "Ready"
  @Published var history: [String] =
    (UserDefaults.standard.stringArray(forKey: "history") ?? [])

  private var engine = AVAudioEngine()
  private var recognizer: SFSpeechRecognizer?
  private var modernAppleSession: AnyObject?
  private var recognizerLocale = ""
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var wantsStop = false
  // Session buffer. Apple's recognizer hands us REPLACEMENTS (the whole current
  // utterance each time), and on a pause it throws that utterance away and
  // starts fresh, on macOS 26 on-device it does this silently, with no
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
  private var qwenSpec: ModelSpec?
  private var offlineSpec: ModelSpec?
  private var fluidSpec: ModelSpec?
  private var arkasrSpec: ModelSpec?
  private var sherpaSamples: [Float] = []
  private var hitCaptureLimit = false
  private var hwRate = 16000
  // Incremental qwenAsr state, owned by sherpaQueue. Chunks of consumed audio
  // are transcribed in short-lived workers while recording continues; only
  // their text survives here, so memory stays flat no matter how long the
  // dictation runs and a crashed or leaked job leaves nothing resident.
  private var qwenGen = 0             // bumped on finalize/restart; stale job results are dropped
  private var qwenChunkInFlight = false
  private var qwenFinalized = false
  private var qwenFinishPending = false
  private var qwenFinishSpec: ModelSpec?
  private var qwenCommitted = ""      // merged transcript of chunks already consumed
  private var qwenEverChunked = false
  private var whisperSpec: ModelSpec?
  private var whisperChunker = PauseChunker()
  private var whisperGen = 0
  private var whisperChunkInFlight = false
  private var whisperFinalized = false
  private var whisperFinishPending = false
  private var whisperFinishSpec: ModelSpec?
  private var whisperCommitted = ""
  private var whisperPendingRaw = ""
  private var whisperReady: [[Float]] = []
  private var onBufferCurrent: ((AVAudioPCMBuffer) -> Void)?
  private var configObserver: NSObjectProtocol?
  private var poppedSinceStart = false
  private var maxLevel: Float = 0
  private var silenceRestarts = 0
  private var applePendingBuffers: [AVAudioPCMBuffer] = []
  private let appleBufLock = NSLock()
  private var appleWaitingToFinish = false
  private var applePrepareGen = 0
  private var appleSessionLocale = ""
  private var transcribeWatch: DispatchWorkItem?
  private let sherpaQueue = DispatchQueue(label: "ai.scribe.sherpa")
  // Past 15 minutes we stop buffering rather than grow without a bound. Use
  // the actual hardware rate because microphones may run at 44.1, 48 or 96 kHz.
  private var maxBufferedSamples: Int {
    max(hwRate, TranscriptionLimits.sampleRate) * TranscriptionLimits.maxCapturedSeconds
  }

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
        switch spec.kind {
        case .qwenAsr: self.beginQwen(spec)
        case .whisperCpp: self.beginWhisperCpp(spec)
        case .fluidParakeet: self.beginFluid(spec)
        case .arkasrOnnx, .arkOnnx: self.beginArkasr(spec)
        default: self.beginSherpa(spec)
        }
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

  // macOS keeps the input device, and a Bluetooth headset pinned in HFP, claimed
  // until the AVAudioEngine instance is dropped; stop() alone does not release it.
  private func releaseEngine() {
    if let configObserver {
      NotificationCenter.default.removeObserver(configObserver)
      self.configObserver = nil
    }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    engine.reset() // settle the graph, dealloc mid-config-change throws (uncatchable)
    engine = AVAudioEngine()
  }

  // Releasing the device means every start renegotiates the input (Bluetooth
  // headsets flip HFP on/off), which fires a configuration change right after
  // engine.start(), and AVAudioEngine stops delivering buffers on config
  // change without auto-restarting. Rebuild the capture or we record silence.
  //
  // Reconfigure the SAME engine in place. Deallocating an engine whose graph
  // is mid-configuration-change throws from AUGraph teardown, an uncatchable
  // C++ exception that aborts the app. Dealloc only happens in stop(), when
  // the engine is settled.
  private func restartCapture() {
    guard isRecording, let onBuffer = onBufferCurrent else { return }
    dlog("audio config change, restarting capture")
    if let configObserver {
      NotificationCenter.default.removeObserver(configObserver)
      self.configObserver = nil
    }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    guard let rate = startEngine(onBuffer: onBuffer) else { return }
    if rate != hwRate {
      if sherpa != nil || qwenSpec != nil || offlineSpec != nil || arkasrSpec != nil
          || whisperSpec != nil {
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
      set("Mic unavailable, re-enable Microphone for Scribe in System Settings")
      return nil
    }
    input.removeTap(onBus: 0)
    // installTap raises ObjC NSExceptions Swift can't catch, route through
    // the ObjCCatch shim so a bad audio state can't kill the app.
    // The "Pop" cue fires on the FIRST delivered buffer, not on engine.start()
    //, with Bluetooth the capture renegotiates for ~1s after start, and a cue
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
          DispatchQueue.main.async {
            self.level = min(1, rms * 14)
            self.maxLevel = max(self.maxLevel, rms)
          }
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

  // After the Bluetooth HFP flip the renegotiated input occasionally comes up
  // muted, frames arrive but they're all zeros (flat waveform, empty
  // transcript). Watchdog: if nothing above the noise floor ~1.5s in, restart
  // capture once or twice.
  private func armSilenceWatchdog() {
    let attempt = silenceRestarts
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self, self.isRecording, self.silenceRestarts == attempt else { return }
      if self.maxLevel < 0.0005, self.silenceRestarts < 2 {
        self.silenceRestarts += 1
        dlog("input silent (peak rms \(self.maxLevel)), restarting capture (\(self.silenceRestarts))")
        self.restartCapture()
        self.armSilenceWatchdog()
      }
    }
  }

  private func markListening() {
    lastText = ""
    lastPendingText = ""
    lastRawText = ""
    isRecording = true
    phase = .listening
    set("Listening…")
    HUD.shared.show()
    maxLevel = 0
    silenceRestarts = 0
    sherpaQueue.async { self.hitCaptureLimit = false }
    armSilenceWatchdog()
    if wantsStop {
      wantsStop = false
      stop()
    }
  }

  // MARK: - Apple path

  private func beginApple(_ spec: ModelSpec) {
    guard !isRecording else { return }
    // Only one heavy runtime may remain resident. Apple recognition does not
    // need either downloaded-model backend.
    SherpaEngineCache.shared.unload()
    AsrRuntime.shared.release()
    LLMRuntime.shared.release()
    if #available(macOS 26.0, *) {
      beginModernApple(spec)
      return
    }
    beginLegacyApple(spec)
  }

  @available(macOS 26.0, *)
  private func beginModernApple(_ spec: ModelSpec) {
    appleWaitingToFinish = false
    appleBufLock.lock()
    applePendingBuffers.removeAll()
    appleBufLock.unlock()
    applePrepareGen += 1
    let prepareGen = applePrepareGen
    let onText: (String) -> Void = { [weak self] text in
      DispatchQueue.main.async {
        guard let self else { return }
        self.lastText = spec.romanize ? Romanizer.hinglish(text) : text
      }
    }
    appleSessionLocale = spec.locale
    if let cached = ModernSpeechSession.cached(for: spec.locale) {
      dlog("apple analyzer cache hit locale=\(spec.locale)")
      cached.startTurn(onUpdate: onText)
      modernAppleSession = cached
      guard let rate = startEngine(onBuffer: { [weak self] buffer in
        (self?.modernAppleSession as? ModernSpeechSession)?.accept(buffer)
      }) else {
        modernAppleSession = nil
        return
      }
      hwRate = rate
      markListening()
      return
    }
    guard let rate = startEngine(onBuffer: { [weak self] buffer in
      self?.routeModernAppleBuffer(buffer)
    }) else { return }
    hwRate = rate
    markListening()
    Task { [weak self] in
      guard let self else { return }
      let t0 = Date()
      do {
        let session = try await ModernSpeechSession(locale: spec.locale)
        dlog(String(format: "apple analyzer prepared in %.2fs", Date().timeIntervalSince(t0)))
        await MainActor.run {
          guard self.applePrepareGen == prepareGen else { return }
          self.attachModernSession(session, onText: onText)
        }
      } catch {
        dlog("SpeechAnalyzer setup error: \(error.localizedDescription); falling back")
        await MainActor.run {
          guard self.applePrepareGen == prepareGen else { return }
          if self.isRecording {
            self.attachLegacyAppleWhileRecording(spec)
          } else if self.appleWaitingToFinish {
            self.appleWaitingToFinish = false
            self.set("Ready")
            self.finish(with: self.lastText)
          }
        }
      }
    }
  }

  @available(macOS 26.0, *)
  private func routeModernAppleBuffer(_ buffer: AVAudioPCMBuffer) {
    if let session = modernAppleSession as? ModernSpeechSession {
      session.accept(buffer)
      return
    }
    if let request {
      request.append(buffer)
      detectApplePause(buffer)
      return
    }
    guard let copy = Self.copyPCM(buffer) else { return }
    appleBufLock.lock()
    applePendingBuffers.append(copy)
    appleBufLock.unlock()
  }

  @available(macOS 26.0, *)
  private func attachModernSession(_ session: ModernSpeechSession, onText: @escaping (String) -> Void) {
    appleBufLock.lock()
    let pending = applePendingBuffers
    applePendingBuffers.removeAll()
    appleBufLock.unlock()
    session.startTurn(onUpdate: onText)
    for buf in pending { session.accept(buf) }
    modernAppleSession = session
    if appleWaitingToFinish {
      appleWaitingToFinish = false
      finishModernApple(session)
    }
  }

  @available(macOS 26.0, *)
  private func finishModernApple(_ session: ModernSpeechSession) {
    modernAppleSession = nil
    phase = .transcribing
    set("Finishing…")
    let locale = appleSessionLocale
    session.finish { [weak self] text in
      guard let self else { return }
      ModernSpeechSession.store(session, locale: locale)
      self.set("Ready")
      self.finish(with: text)
    }
  }

  private func attachLegacyAppleWhileRecording(_ spec: ModelSpec) {
    if recognizer == nil || recognizerLocale != spec.locale {
      recognizer = SFSpeechRecognizer(locale: Locale(identifier: spec.locale))
      recognizerLocale = spec.locale
    }
    guard let recognizer, recognizer.isAvailable else {
      set("\(spec.label) isn’t available on this Mac")
      return
    }
    appleBufLock.lock()
    let pending = applePendingBuffers
    applePendingBuffers.removeAll()
    appleBufLock.unlock()
    startAppleTask(recognizer)
    for buf in pending { request?.append(buf) }
  }

  private static func copyPCM(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let out = AVAudioPCMBuffer(
      pcmFormat: buffer.format, frameCapacity: buffer.frameLength
    ) else { return nil }
    out.frameLength = buffer.frameLength
    guard let src = buffer.floatChannelData, let dst = out.floatChannelData else { return out }
    let n = Int(buffer.frameLength)
    for ch in 0..<Int(buffer.format.channelCount) {
      dst[ch].update(from: src[ch], count: n)
    }
    return out
  }

  private func beginLegacyApple(_ spec: ModelSpec) {
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
    // the recognition task mid-recording is seamless, the engine never stops.
    guard let rate = startEngine(onBuffer: { [weak self] buffer in
      self?.request?.append(buffer)
      self?.detectApplePause(buffer)
    }) else { return }
    hwRate = rate

    startAppleTask(recognizer)
    markListening()
  }

  /// Banks the current utterance after ~1.2 s of trailing mic silence, a real
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
        dlog("apple pause, banking \(self.appleSegment.count) chars")
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
    req.addsPunctuation = !Settings.shared.activeModel.romanize
      && !Settings.shared.activeModel.locale.lowercased().hasPrefix("hi")
    req.contextualStrings = Vocabulary.biasTerms
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
          // replaced the utterance with a shorter, different one, bank the old.
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
        dlog("apple error before any text, not restarting")
        return
      }
      appleErrorRestarts += 1
      guard appleErrorRestarts <= 6 else {
        set("Speech engine stopped, this language may need internet. Try a downloaded model.")
        return
      }
    }
    dlog("apple task restart committed=\(appleCommitted.count) err=\(appleErrorRestarts)")
    startAppleTask(recognizer)
  }

  // MARK: - sherpa path

  private func beginSherpa(_ spec: ModelSpec) {
    guard !isRecording else { return }
    AsrRuntime.shared.release()
    LLMRuntime.shared.release()
    guard ModelStore.tokensFile(in: ModelStore.dir(for: spec)) != nil else {
      set("\(spec.label) isn’t downloaded, get it in the Dashboard")
      return
    }
    request = nil
    task = nil
    let language = Settings.shared.language
    let provider = Settings.shared.sherpaProvider(for: spec)

    // Offline native inference runs after release in a short-lived worker.
    // The UI process owns only microphone PCM, so an ONNX/CoreML exception or
    // allocator spike cannot crash Scribe or remain resident afterward.
    if !spec.live {
      offlineSpec = spec
      sherpaSamples = []
      guard let rate = startEngine(onBuffer: { [weak self] buffer in
        self?.consumeSherpa(buffer)
      }) else { return }
      hwRate = rate
      markListening()
      return
    }

    // Live models stream into the engine as audio arrives, so the load has
    // to finish before capture starts.
    set("Loading \(spec.label)…")
    sherpaQueue.async { [weak self] in
      let loaded = SherpaEngineCache.shared.engine(
        for: spec, language: language, provider: provider,
      )
      DispatchQueue.main.async {
        guard let self else { return }
        guard let loaded else {
          self.set("Couldn’t load \(spec.label), re-download it in the Dashboard")
          return
        }
        guard !self.isRecording else { return }
        self.sherpa = loaded
        self.sherpaSamples = []
        self.sherpaQueue.async { loaded.startStream() }
        guard let rate = self.startEngine(onBuffer: { [weak self] buffer in
          self?.consumeSherpa(buffer)
        }) else { return }
        self.hwRate = rate
        self.markListening()
      }
    }
  }

  // MARK: - qwen-asr path (Srota)

  private func beginQwen(_ spec: ModelSpec) {
    guard !isRecording else { return }
    SherpaEngineCache.shared.unload()
    let mlx = MLXRuntime.gemmaAsrUsesMlx(spec)
    if !mlx { LLMRuntime.shared.release() }
    let dir = ModelStore.dir(for: spec)
    let model = dir.appendingPathComponent(spec.fileName)
    let mmproj = dir.appendingPathComponent(spec.mmprojFileName)
    let ggufReady = FileManager.default.fileExists(atPath: model.path)
      && FileManager.default.fileExists(atPath: mmproj.path)
    guard mlx || ggufReady else {
      set("\(spec.label) isn’t downloaded, get it in the Dashboard")
      return
    }
    request = nil
    task = nil
    qwenSpec = spec
    sherpaSamples = []
    AsrRuntime.shared.warm(
      modelPath: dir.appendingPathComponent(spec.fileName).path,
      mmprojPath: dir.appendingPathComponent(spec.mmprojFileName).path
    )
    set("Loading Gemma…")
    sherpaQueue.async { [weak self] in
      guard let self else { return }
      self.qwenGen += 1
      self.qwenChunkInFlight = false
      self.qwenFinalized = false
      self.qwenFinishPending = false
      self.qwenFinishSpec = nil
      self.qwenCommitted = ""
      self.qwenEverChunked = false
      DiagnosticAudioStore.endSession()
    }
    guard let rate = startEngine(onBuffer: { [weak self] buffer in
      self?.consumeQwen(buffer)
    }) else { return }
    hwRate = rate
    markListening()
  }

  private func beginFluid(_ spec: ModelSpec) {
    guard !isRecording else { return }
    SherpaEngineCache.shared.unload()
    AsrRuntime.shared.release()
    LLMRuntime.shared.release()
    recognizer = nil
    request = nil
    task = nil
    fluidSpec = spec
    sherpaSamples = []
    guard let rate = startEngine(onBuffer: { [weak self] buffer in
      self?.consumeSherpa(buffer)
    }) else { return }
    hwRate = rate
    markListening()
  }

  private func beginArkasr(_ spec: ModelSpec) {
    guard !isRecording else { return }
    guard ModelStore.bundleInstalled(spec) else {
      set("\(spec.label) isn’t downloaded, get it in the Dashboard")
      return
    }
    SherpaEngineCache.shared.unload()
    AsrRuntime.shared.release()
    LLMRuntime.shared.release()
    recognizer = nil
    request = nil
    task = nil
    arkasrSpec = spec
    sherpaSamples = []
    guard let rate = startEngine(onBuffer: { [weak self] buffer in
      self?.consumeSherpa(buffer)
    }) else { return }
    hwRate = rate
    markListening()
  }

  private func beginWhisperCpp(_ spec: ModelSpec) {
    guard !isRecording else { return }
    let model = ModelStore.dir(for: spec).appendingPathComponent(spec.fileName)
    guard FileManager.default.fileExists(atPath: model.path) else {
      set("\(spec.label) isn’t downloaded, get it in the Dashboard")
      return
    }
    SherpaEngineCache.shared.unload()
    AsrRuntime.shared.release()
    recognizer = nil
    request = nil
    task = nil
    whisperSpec = spec
    sherpaSamples = []
    lastPendingText = ""
    guard let rate = startEngine(onBuffer: { [weak self] buffer in
      self?.consumeWhisper(buffer)
    }) else { return }
    hwRate = rate
    sherpaQueue.async { [weak self] in
      guard let self else { return }
      self.whisperGen += 1
      self.whisperChunkInFlight = false
      self.whisperFinalized = false
      self.whisperFinishPending = false
      self.whisperFinishSpec = nil
      self.whisperCommitted = ""
      self.whisperPendingRaw = ""
      self.whisperReady = []
      var pause = Settings.shared.chunkPauseMs
      if pause < 400 { pause = 400 }
      if pause > 700 { pause = 700 }
      self.whisperChunker = PauseChunker(sampleRate: rate, pauseMs: pause)
      DiagnosticAudioStore.endSession()
    }
    markListening()
  }

  private func consumeWhisper(_ buffer: AVAudioPCMBuffer) {
    guard let ch = buffer.floatChannelData?[0] else { return }
    let samples = [Float](UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
    sherpaQueue.async { [weak self] in
      guard let self else { return }
      DiagnosticAudioStore.stream(samples, sampleRate: self.hwRate)
      self.appendCaptured(samples)
      let chunks = self.whisperChunker.feed(samples)
      if !chunks.isEmpty { self.whisperReady.append(contentsOf: chunks) }
      self.maybeSpawnWhisperChunk()
    }
  }

  private func maybeSpawnWhisperChunk() {
    guard let spec = whisperSpec, isRecording || whisperFinishPending,
          !whisperChunkInFlight, !whisperFinalized else { return }
    guard !whisperReady.isEmpty else { return }
    let slice = whisperReady.removeFirst()
    whisperChunkInFlight = true
    let gen = whisperGen
    NativeTranscriptionWorker.shared.transcribe(
      spec: spec, samples: slice, sampleRate: hwRate,
      language: WhisperDecode.language(for: spec), provider: "cpu",
      saveDiagnostic: false,
      timeout: TranscriptionLimits.chunkWorkerTimeout(
        audioSeconds: Double(slice.count) / Double(max(hwRate, 1)))
    ) { [weak self] result in
      guard let self else { return }
      self.sherpaQueue.async {
        guard self.whisperGen == gen else { return }
        self.whisperChunkInFlight = false
        if case .success(let raw) = result {
          let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
          if !text.isEmpty { self.acceptWhisperRaw(text, spec: spec) }
        } else if case .failure(let error) = result {
          dlog("whisper chunk failed: \(error.localizedDescription)")
        }
        if self.whisperFinishPending, self.whisperReady.isEmpty, let finishSpec = self.whisperFinishSpec {
          self.whisperFinishSpec = nil
          self.whisperFinishPending = false
          self.finalizeWhisper(spec: finishSpec)
        } else {
          self.maybeSpawnWhisperChunk()
        }
      }
    }
  }

  /// sherpaQueue. Raw ASR is shown immediately; Gemma only rewrites this chunk.
  private func acceptWhisperRaw(_ text: String, spec: ModelSpec) {
    whisperPendingRaw = TranscriptMerger.merge([whisperPendingRaw, text], maxOverlapWords: 4)
    let committed = whisperCommitted
    let pending = whisperPendingRaw
    let gen = whisperGen
    DispatchQueue.main.async {
      self.lastText = committed
      self.lastPendingText = pending
    }
    guard Settings.shared.autoCleanLLM, LLMRuntime.isAvailable else {
      whisperCommitted = TranscriptMerger.merge([whisperCommitted, text], maxOverlapWords: 4)
      whisperPendingRaw = ""
      let shown = whisperCommitted
      DispatchQueue.main.async {
        self.lastText = shown
        self.lastPendingText = ""
      }
      return
    }
    let raw = text
    LLMRuntime.shared.process(
      instruction: LLMRuntime.chunkCleanupInstruction(
        previous: committed, hotwords: Vocabulary.biasTerms),
      text: raw, maxTokens: 256
    ) { [weak self] cleaned in
      guard let self else { return }
      self.sherpaQueue.async {
        guard self.whisperGen == gen else { return }
        let decision = TranscriptCleanupValidator.choose(
          raw: raw, cleaned: cleaned, hotwords: Vocabulary.biasTerms)
        self.whisperCommitted = TranscriptMerger.merge(
          [self.whisperCommitted, decision.text], maxOverlapWords: 4)
        if self.whisperPendingRaw == pending {
          self.whisperPendingRaw = ""
        }
        let shown = self.whisperCommitted
        let rest = self.whisperPendingRaw
        DispatchQueue.main.async {
          self.lastText = shown
          self.lastPendingText = rest
        }
      }
    }
  }

  private func finalizeWhisper(spec: ModelSpec) {
    whisperGen += 1
    whisperFinalized = true
    whisperFinishPending = false
    whisperFinishSpec = nil
    if let last = whisperChunker.flush() { whisperReady.append(last) }
    DiagnosticAudioStore.endSession()
    dlog("whisper finalize: \(whisperReady.count) leftover chunk(s), \(whisperCommitted.count) chars")
    if !whisperReady.isEmpty {
      whisperFinalized = false
      whisperFinishPending = true
      whisperFinishSpec = spec
      maybeSpawnWhisperChunk()
      return
    }
    let text = TranscriptMerger.merge([whisperCommitted, whisperPendingRaw], maxOverlapWords: 4)
    whisperPendingRaw = ""
    sherpaSamples.removeAll()
    DispatchQueue.main.async {
      self.lastPendingText = ""
      self.set("Ready")
      self.finish(with: text, alreadyCleaned: Settings.shared.autoCleanLLM && LLMRuntime.isAvailable)
    }
  }

  private func consumeQwen(_ buffer: AVAudioPCMBuffer) {
    guard let ch = buffer.floatChannelData?[0] else { return }
    let samples = [Float](UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
    sherpaQueue.async { [weak self] in
      guard let self else { return }
      DiagnosticAudioStore.stream(samples, sampleRate: self.hwRate)
      self.appendCaptured(samples)
      self.maybeSpawnQwenChunk()
    }
  }

  /// Called only on sherpaQueue. Fires a background worker once enough new
  /// audio has accumulated past the tail window; the slice keeps an overlap
  /// with the previous chunk so TranscriptMerger can stitch boundary words.
  private func maybeSpawnQwenChunk() {
    guard let spec = qwenSpec, isRecording, !qwenChunkInFlight, !qwenFinalized else { return }
    let rate = max(hwRate, 1)
    let tailSamples = Int(Double(rate) * QwenStreaming.tailSeconds)
    let chunkSamples = Int(Double(rate) * (qwenEverChunked
      ? QwenStreaming.chunkSeconds : QwenStreaming.firstChunkSeconds))
    guard sherpaSamples.count >= tailSamples + chunkSamples else { return }
    let cut = sherpaSamples.count - tailSamples
    let slice = Array(sherpaSamples[0..<cut])
    let keep = max(0, cut - Int(Double(rate) * QwenStreaming.overlapSeconds))
    qwenChunkInFlight = true
    let gen = qwenGen
    transcribeQwen(
      spec: spec, samples: slice, sampleRate: hwRate,
      timeout: TranscriptionLimits.chunkWorkerTimeout(
        audioSeconds: Double(slice.count) / Double(rate))
    ) { [weak self] result in
      guard let self else { return }
      self.sherpaQueue.async {
        guard self.qwenGen == gen else { return } // dictation restarted or finalized mid-job
        self.qwenChunkInFlight = false
        if case .success(let raw) = result {
          // Consume even when the text came back empty (a silent stretch);
          // only failures keep their audio for a later retry. The diagnostic
          // stream already captured this audio live in consumeQwen.
          let removeCount = min(keep, self.sherpaSamples.count)
          self.sherpaSamples.removeFirst(removeCount)
          let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
          if !text.isEmpty {
            self.qwenCommitted = TranscriptMerger.merge([self.qwenCommitted, text])
            self.qwenEverChunked = true
            let preview = self.applyRomanization(self.qwenCommitted)
            DispatchQueue.main.async { self.lastText = preview }
          }
        } else if case .failure(let error) = result {
          dlog("background chunk failed, audio kept for next window: \(error.localizedDescription)")
        }
        if self.qwenFinishPending, let finishSpec = self.qwenFinishSpec {
          self.qwenFinishSpec = nil
          self.qwenFinishPending = false
          self.finalizeQwen(spec: finishSpec)
        } else {
          self.maybeSpawnQwenChunk()
        }
      }
    }
  }

  /// Called only on sherpaQueue. Transcribes whatever was never consumed by a
  /// background chunk and stitches it onto the committed text.
  private func finalizeQwen(spec: ModelSpec) {
    qwenGen += 1
    let gen = qwenGen
    qwenFinalized = true
    qwenFinishPending = false
    qwenFinishSpec = nil
    let backlog = sherpaSamples
    sherpaSamples.removeAll()
    DiagnosticAudioStore.endSession()
    let committedSoFar = qwenCommitted
    dlog("qwen finalize: \(backlog.count) samples tail, \(committedSoFar.count) chars committed")
    let rate = max(hwRate, 1)
    let finish: (String) -> Void = { text in
      DispatchQueue.main.async {
        self.set("Ready")
        self.finish(with: text)
      }
    }
    guard !backlog.isEmpty else {
      if committedSoFar.isEmpty {
        DispatchQueue.main.async {
          self.set("No speech detected, check the mic and the model in Dashboard → Models")
          self.phase = .idle
          HUD.shared.hide()
        }
      } else {
        finish(committedSoFar)
      }
      return
    }
    transcribeQwen(
      spec: spec, samples: backlog, sampleRate: hwRate,
      timeout: TranscriptionLimits.chunkWorkerTimeout(
        audioSeconds: Double(backlog.count) / Double(rate))
    ) { [weak self] result in
      guard let self else { return }
      self.sherpaQueue.async {
        guard self.qwenGen == gen, self.qwenFinalized else { return }
        switch result {
        case .success(let raw):
          let merged = TranscriptMerger.merge([committedSoFar, raw])
          finish(merged.isEmpty ? committedSoFar : merged)
        case .failure(let error):
          dlog("qwen tail failed: \(error.localizedDescription)")
          if committedSoFar.isEmpty {
            DispatchQueue.main.async {
              self.set("\(error.localizedDescription), use Retry last recording")
              self.phase = .idle
              HUD.shared.hide()
            }
          } else {
            dlog("qwen tail failed, inserting committed chunks only")
            finish(committedSoFar)
          }
        }
      }
    }
  }

  private func transcribeQwen(
    spec: ModelSpec, samples: [Float], sampleRate: Int,
    timeout: TimeInterval,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    if MLXRuntime.gemmaAsrUsesMlx(spec) {
      NativeTranscriptionWorker.shared.transcribe(
        spec: spec, samples: samples, sampleRate: sampleRate,
        language: Settings.shared.language, provider: "cpu",
        saveDiagnostic: false, timeout: timeout, completion: completion
      )
      return
    }
    let dir = ModelStore.dir(for: spec)
    AsrRuntime.shared.transcribe(
      modelPath: dir.appendingPathComponent(spec.fileName).path,
      mmprojPath: dir.appendingPathComponent(spec.mmprojFileName).path,
      instruction: ModelCatalog.asrPrompt(for: spec),
      samples: samples, sampleRate: sampleRate
    ) { text in
      if let text, !text.isEmpty {
        completion(.success(text))
      } else {
        NativeTranscriptionWorker.shared.transcribe(
          spec: spec, samples: samples, sampleRate: sampleRate,
          language: Settings.shared.language, provider: "cpu",
          saveDiagnostic: false, timeout: timeout, completion: completion
        )
      }
    }
  }

  private func armTranscribeWatch() {
    transcribeWatch?.cancel()
    let w = DispatchWorkItem { [weak self] in
      guard let self, self.phase == .transcribing else { return }
      dlog("transcribe watchdog fired")
      self.sherpaQueue.async {
        self.qwenGen += 1
        self.qwenFinalized = true
        self.qwenFinishPending = false
        let text = self.qwenCommitted
        DispatchQueue.main.async {
          guard self.phase == .transcribing else { return }
          if text.isEmpty {
            self.set("Timed out, audio kept, use Retry last recording")
            self.phase = .idle
            HUD.shared.hide()
          } else {
            self.set("Ready")
            self.finish(with: text)
          }
        }
      }
    }
    transcribeWatch = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 35, execute: w)
  }

  private func consumeSherpa(_ buffer: AVAudioPCMBuffer) {
    guard let ch = buffer.floatChannelData?[0] else { return }
    let samples = [Float](UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
    sherpaQueue.async { [weak self] in
      guard let self else { return }
      if let sherpa = self.sherpa, sherpa.spec.live {
        let text = sherpa.feed(samples, sampleRate: self.hwRate)
        DispatchQueue.main.async { self.lastText = text }
      } else {
        // Offline capture buffers independently of the engine, which may
        // still be warming on this queue.
        self.appendCaptured(samples)
      }
    }
  }

  /// Called only on sherpaQueue.
  private func appendCaptured(_ samples: [Float]) {
    let remaining = maxBufferedSamples - sherpaSamples.count
    guard remaining > 0 else {
      // Dropping audio silently made a long recording look like it simply
      // stopped transcribing halfway.
      if !hitCaptureLimit {
        hitCaptureLimit = true
        set("\(TranscriptionLimits.maxCapturedSeconds / 60) min limit reached, "
          + "stop now to transcribe what was captured")
      }
      return
    }
    sherpaSamples.append(contentsOf: samples.prefix(remaining))
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

    if #available(macOS 26.0, *) {
      if let session = modernAppleSession as? ModernSpeechSession {
        finishModernApple(session)
        return
      }
      if applePrepareGen != 0, modernAppleSession == nil, request == nil {
        appleWaitingToFinish = true
        phase = .transcribing
        set("Finishing…")
        return
      }
    }

    if let spec = fluidSpec {
      fluidSpec = nil
      phase = .transcribing
      set("Transcribing…")
      let rate = hwRate
      let version: AsrModelVersion = spec.id.contains("v3") ? .v3 : .v2
      sherpaQueue.async { [weak self] in
        guard let self else { return }
        let samples = self.sherpaSamples
        self.sherpaSamples = []
        if Settings.shared.keepLatestRecording {
          DiagnosticAudioStore.saveLatest(samples: samples, sampleRate: rate)
        }
        Task {
          do {
            let text = try await FluidEngine.shared.transcribe(
              samples, sampleRate: rate, version: version
            )
            dlog("fluid transcribed \(text.count) chars from \(samples.count) samples")
            await MainActor.run {
              self.set("Ready")
              self.finish(with: text)
            }
          } catch {
            dlog("fluid failed: \(error.localizedDescription)")
            await MainActor.run {
              self.set("\(error.localizedDescription), audio kept, use Retry last recording")
              self.phase = .idle
              HUD.shared.hide()
            }
          }
        }
      }
      return
    }

    if let spec = arkasrSpec {
      arkasrSpec = nil
      phase = .transcribing
      set("Transcribing…")
      let rate = hwRate
      sherpaQueue.async { [weak self] in
        guard let self else { return }
        let samples = self.sherpaSamples
        self.sherpaSamples = []
        if Settings.shared.keepLatestRecording {
          DiagnosticAudioStore.saveLatest(samples: samples, sampleRate: rate)
        }
        ArkasrRuntime.shared.transcribe(spec: spec, samples: samples, sampleRate: rate) { result in
          switch result {
          case let .success(text):
            dlog("arkasr transcribed \(text.count) chars from \(samples.count) samples")
            self.set("Ready")
            self.finish(with: text)
          case let .failure(error):
            dlog("arkasr failed: \(error.localizedDescription)")
            self.set("\(error.localizedDescription), audio kept, use Retry last recording")
            self.phase = .idle
            HUD.shared.hide()
          }
        }
      }
      return
    }

    if let spec = whisperSpec {
      whisperSpec = nil
      phase = .transcribing
      set("Finishing…")
      sherpaQueue.async { [weak self] in
        guard let self else { return }
        if self.whisperChunkInFlight || !self.whisperReady.isEmpty {
          self.whisperFinishSpec = spec
          self.whisperFinishPending = true
          self.maybeSpawnWhisperChunk()
          return
        }
        self.finalizeWhisper(spec: spec)
      }
      return
    }

    if let spec = offlineSpec {
      offlineSpec = nil
      phase = .transcribing
      set("Transcribing…")
      let rate = hwRate
      let language = Settings.shared.language
      let provider = Settings.shared.sherpaProvider(for: spec)
      let peak = maxLevel
      sherpaQueue.async { [weak self] in
        guard let self else { return }
        let samples = self.sherpaSamples
        self.sherpaSamples = []
        dlog("offline stop: \(samples.count) samples @\(rate)Hz peak rms \(peak)")
        NativeTranscriptionWorker.shared.transcribe(
          spec: spec, samples: samples, sampleRate: rate,
          language: language, provider: provider
        ) { result in
          switch result {
          case let .success(text):
            dlog("worker transcribed \(text.count) chars from \(samples.count) samples")
            self.set("Ready")
            self.finish(with: text)
          case let .failure(error):
            dlog("worker failed: \(error.localizedDescription)")
            self.set(error.localizedDescription)
            self.phase = .idle
            HUD.shared.hide()
          }
        }
      }
      return
    }

    if let spec = qwenSpec {
      qwenSpec = nil
      phase = .transcribing
      set("Finishing…")
      armTranscribeWatch()
      sherpaQueue.async { [weak self] in
        guard let self else { return }
        // A chunk job is mid-flight: let it land (it consumes its audio and
        // updates the committed text), then finalize from its completion.
        if self.qwenChunkInFlight {
          self.qwenFinishSpec = spec
          self.qwenFinishPending = true
          return
        }
        self.finalizeQwen(spec: spec)
      }
      return
    }

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

  private func finish(with text: String, alreadyCleaned: Bool = false) {
    // Un-punctuated engines (streaming Zipformer, CTC) get on-device punctuation
    // restored before the spoken-command pass. Runs off the main thread.
    let kind = Settings.shared.activeModel.kind
    if PunctuationRuntime.needsPunctuation(kind), SupportModelStore.punctInstalled,
       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      phase = .postProcessing
      set("Adding punctuation…")
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let punctuated = PunctuationRuntime.shared.punctuate(text)
        DispatchQueue.main.async {
          self?.finishProcessed(with: punctuated, alreadyCleaned: alreadyCleaned)
        }
      }
      return
    }
    finishProcessed(with: text, alreadyCleaned: alreadyCleaned)
  }

  func importedResult(_ text: String) {
    lastRawText = text
    lastText = text
    guard !text.isEmpty else { return }
    if Settings.shared.saveHistory {
      history.insert(text, at: 0)
      if history.count > 50 { history.removeLast(history.count - 50) }
      UserDefaults.standard.set(history, forKey: "history")
    }
  }

  private func finishProcessed(with text: String, alreadyCleaned: Bool = false) {
    transcribeWatch?.cancel()
    transcribeWatch = nil
    var finalText = VoiceCommands.apply(text, allowDestructive: true)
    finalText = Romanizer.normalizeScript(finalText)
    dlog("finish text=\(finalText.count) chars")
    lastRawText = finalText
    lastText = finalText
    lastPendingText = ""
    guard !finalText.isEmpty else {
      set("No speech detected, check the mic and the model in Dashboard → Models")
      phase = .idle
      HUD.shared.hide()
      return
    }

    // Optional AI cleanup before insertion. Skip when live chunks already went
    // through Gemma so a second pass cannot rewrite earlier utterances.
    if !alreadyCleaned, Settings.shared.autoCleanLLM, LLMRuntime.isAvailable {
      phase = .postProcessing
      set("Cleaning up…")
      SherpaEngineCache.shared.unload()
      // Srota and Gemma both use llama.cpp/Metal. Free the ASR model first;
      // their independent queues previously allowed both multi-GB models to
      // remain resident for five minutes.
      AsrRuntime.shared.release {
        LLMRuntime.shared.process(
          instruction: LLMRuntime.cleanupInstruction,
          text: finalText, maxTokens: 1024
        ) { cleaned in
          let decision = TranscriptCleanupValidator.choose(raw: finalText, cleaned: cleaned)
          dlog(
            "cleanup \(decision.accepted ? "accepted" : "rejected"): " +
            "\(decision.reason), raw \(finalText.count) / candidate \(cleaned?.count ?? 0) chars"
          )
          self.insertAndFinalize(decision.text)
        }
      }
      return
    }
    insertAndFinalize(finalText)
  }

  private func insertAndFinalize(_ text: String) {
    lastText = text
    Paster.insert(text) { outcome in
      if case .copiedOnly(let why) = outcome { self.set(why) }
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
