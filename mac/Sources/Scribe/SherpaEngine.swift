import Foundation
import AVFoundation
import CSherpa

/// Wraps the sherpa-onnx C API for downloaded models. Offline kinds buffer
/// audio and transcribe on stop; the online kind streams partial results.
final class SherpaEngine {
  let spec: ModelSpec
  let language: String
  let provider: String
  private var offline: OpaquePointer?
  private var online: OpaquePointer?
  private var onlineStream: OpaquePointer?
  private var committed = ""

  private var keep: [UnsafeMutablePointer<CChar>] = []

  private func c(_ s: String) -> UnsafePointer<CChar> {
    let p = strdup(s)!
    keep.append(p)
    return UnsafePointer(p)
  }

  private func freeStrings() {
    keep.forEach { free($0) }
    keep = []
  }

  init?(spec: ModelSpec, language: String, provider: String) {
    self.spec = spec
    self.language = language
    self.provider = provider
    guard let dir = ModelStore.modelDir(for: spec),
          let tokens = ModelStore.tokensFile(in: ModelStore.dir(for: spec)) else {
      dlog("sherpa init: files missing for \(spec.id)")
      return nil
    }
    defer { freeStrings() }
    let threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

    switch spec.kind {
    case .appleSystem:
      return nil

    case .onlineTransducer, .nemotronTransducer:
      var cfg = SherpaOnnxOnlineRecognizerConfig()
      memset(&cfg, 0, MemoryLayout.size(ofValue: cfg))
      cfg.feat_config.sample_rate = 16000
      cfg.feat_config.feature_dim = 80
      // Nemotron ships int8-only; zipformer ships an fp32 decoder. sherpa
      // auto-detects the online model type (transducer vs nemotron) from the
      // encoder metadata, so no explicit model_type is set.
      let decInt8 = spec.kind == .nemotronTransducer
      guard let enc = ModelStore.find("encoder", in: dir),
            let dec = ModelStore.find("decoder", in: dir, preferInt8: decInt8),
            let join = ModelStore.find("joiner", in: dir) else {
        dlog("sherpa init: transducer files missing for \(spec.id)")
        return nil
      }
      cfg.model_config.transducer.encoder = c(enc.path)
      cfg.model_config.transducer.decoder = c(dec.path)
      cfg.model_config.transducer.joiner = c(join.path)
      cfg.model_config.tokens = c(tokens.path)
      cfg.model_config.num_threads = threads
      cfg.model_config.provider = c(provider)
      cfg.decoding_method = c("greedy_search")
      cfg.enable_endpoint = 1
      cfg.rule1_min_trailing_silence = 2.4
      cfg.rule2_min_trailing_silence = 1.2
      cfg.rule3_min_utterance_length = 30
      online = SherpaOnnxCreateOnlineRecognizer(&cfg)
      if online == nil { dlog("sherpa init: online recognizer failed \(spec.id)"); return nil }

    default:
      var cfg = SherpaOnnxOfflineRecognizerConfig()
      memset(&cfg, 0, MemoryLayout.size(ofValue: cfg))
      cfg.feat_config.sample_rate = 16000
      cfg.feat_config.feature_dim = 80
      cfg.model_config.tokens = c(tokens.path)
      cfg.model_config.num_threads = threads
      cfg.model_config.provider = c(provider)
      cfg.decoding_method = c("greedy_search")

      switch spec.kind {
      case .moonshine:
        if let enc = ModelStore.find("encoder_model", in: dir),
           let merged = ModelStore.find("decoder_model_merged", in: dir) {
          // moonshine v2: encoder + merged decoder only
          cfg.model_config.moonshine.encoder = c(enc.path)
          cfg.model_config.moonshine.merged_decoder = c(merged.path)
        } else if let pre = ModelStore.find("preprocess", in: dir),
                  let enc = ModelStore.find("encode", in: dir),
                  let unc = ModelStore.find("uncached_decode", in: dir),
                  let cac = ModelStore.find("cached_decode", in: dir) {
          cfg.model_config.moonshine.preprocessor = c(pre.path)
          cfg.model_config.moonshine.encoder = c(enc.path)
          cfg.model_config.moonshine.uncached_decoder = c(unc.path)
          cfg.model_config.moonshine.cached_decoder = c(cac.path)
        } else {
          dlog("sherpa init: moonshine files missing for \(spec.id)")
          return nil
        }
      case .nemoCtc:
        guard let model = ModelStore.find("model", in: dir) else {
          dlog("sherpa init: ctc model missing for \(spec.id)")
          return nil
        }
        cfg.model_config.nemo_ctc.model = c(model.path)
      case .nemoTransducer:
        guard let enc = ModelStore.find("encoder", in: dir),
              let dec = ModelStore.find("decoder", in: dir),
              let join = ModelStore.find("joiner", in: dir) else {
          dlog("sherpa init: transducer files missing for \(spec.id)")
          return nil
        }
        cfg.model_config.transducer.encoder = c(enc.path)
        cfg.model_config.transducer.decoder = c(dec.path)
        cfg.model_config.transducer.joiner = c(join.path)
        cfg.model_config.model_type = c("nemo_transducer")
      case .canary:
        guard let enc = ModelStore.find("encoder", in: dir),
              let dec = ModelStore.find("decoder", in: dir) else {
          dlog("sherpa init: canary files missing for \(spec.id)")
          return nil
        }
        cfg.model_config.canary.encoder = c(enc.path)
        cfg.model_config.canary.decoder = c(dec.path)
        cfg.model_config.canary.src_lang = c("en")
        cfg.model_config.canary.tgt_lang = c("en")
        cfg.model_config.canary.use_pnc = 1
      case .whisper:
        // int8 whisper decoders drop Devanagari/multibyte tokens, use fp32
        // when the archive ships it (turbo is int8-only).
        guard let enc = ModelStore.find("encoder", in: dir),
              let dec = ModelStore.find("decoder", in: dir, preferInt8: false) else {
          dlog("sherpa init: whisper files missing for \(spec.id)")
          return nil
        }
        cfg.model_config.whisper.encoder = c(enc.path)
        cfg.model_config.whisper.decoder = c(dec.path)
        cfg.model_config.whisper.language = c(language == "auto" ? "" : language)
        cfg.model_config.whisper.task = c("transcribe")
        cfg.model_config.whisper.tail_paddings = -1
      case .dolphinCtc:
        guard let model = ModelStore.find("model", in: dir) else {
          dlog("sherpa init: dolphin model missing for \(spec.id)")
          return nil
        }
        cfg.model_config.dolphin.model = c(model.path)
      default:
        return nil
      }
      offline = SherpaOnnxCreateOfflineRecognizer(&cfg)
      if offline == nil { dlog("sherpa init: offline recognizer failed \(spec.id)"); return nil }
    }
    dlog("sherpa loaded \(spec.id)")
  }

  deinit {
    if let onlineStream { SherpaOnnxDestroyOnlineStream(onlineStream) }
    if let online { SherpaOnnxDestroyOnlineRecognizer(online) }
    if let offline { SherpaOnnxDestroyOfflineRecognizer(offline) }
  }

  // MARK: offline

  func transcribe(_ samples: [Float], sampleRate: Int) -> String {
    guard offline != nil, !samples.isEmpty else { return "" }

    // Every offline recognizer is fed bounded 16 kHz windows. Never pass the
    // caller's complete recording directly to ONNX: dynamic-shape models can
    // allocate temporary tensors proportional (or worse) to utterance length.
    let resampled = SileroVAD.resampleTo16k(samples, from: sampleRate)
    let audio = Settings.shared.conditionAudio
      ? AudioConditioner.process16k(resampled) : resampled
    guard !audio.isEmpty else { return "" }

    // Non-streaming recognizers decode the whole buffer at once, and Moonshine's
    // attention memory grows ~quadratically with length while its output goes
    // empty past ~10 s. Split at silence with VAD and decode each short segment,
    // exactly as sherpa's Moonshine examples do. If VAD is unavailable, fixed
    // overlapping windows below preserve the same hard memory bound.
    if let vad = SileroVAD.shared {
      let maxN = SileroVAD.maxSegmentSamples
      let segments = vad.segments16k(audio)
      if !segments.isEmpty {
        var parts: [String] = []
        var emptySegments = 0
        var recoveredSegments = 0
        for (index, seg) in segments.enumerated() {
          var segmentParts: [String] = []
          for window in SileroVAD.split(
            seg, max: maxN, overlap: SileroVAD.hardSplitOverlapSamples
          ) {
            let text = decodeOffline(window, sampleRate: 16000)
            if !text.isEmpty { segmentParts.append(text) }
          }
          if segmentParts.isEmpty {
            emptySegments += 1
            // Very short words and acronyms can form their own VAD island. A
            // CTC model may return empty without neighboring acoustic context,
            // so retry once with up to one second from the next segment (or
            // the previous segment for the final island).
            let retry = SileroVAD.retryWindow(
              segments: segments, emptyIndex: index, max: maxN
            )
            let text = decodeOffline(retry, sampleRate: 16000)
            if !text.isEmpty {
              segmentParts.append(text)
              recoveredSegments += 1
            }
          }
          parts.append(contentsOf: segmentParts)
        }
        dlog(
          "vad: \(segments.count) segment(s) → \(parts.count) window(s), " +
          "\(emptySegments) empty / \(recoveredSegments) recovered from \(samples.count) samples"
        )
        return TranscriptMerger.merge(parts)
      }
      // No speech found. Decoding a long silent buffer whole would re-trigger the
      // blowup, so only fall back to a whole-buffer decode when it's short.
      if audio.count > maxN {
        dlog("vad: no speech in \(audio.count)-sample buffer, empty")
        return ""
      }
      return decodeOffline(audio, sampleRate: 16000)
    }

    // The VAD resource is an optimization and a quality improvement, not a
    // safety dependency. If packaging ever omits it again, fixed overlapping
    // windows preserve the memory bound instead of silently restoring the
    // catastrophic whole-recording path.
    let windows = SileroVAD.split(
      audio, max: SileroVAD.maxSegmentSamples,
      overlap: SileroVAD.hardSplitOverlapSamples
    )
    dlog("vad: unavailable, fixed-window fallback \(windows.count) chunk(s)")
    return TranscriptMerger.merge(
      windows.compactMap {
        let text = decodeOffline($0, sampleRate: 16000)
        return text.isEmpty ? nil : text
      }
    )
  }

  private func decodeOffline(_ samples: [Float], sampleRate: Int) -> String {
    guard let offline, !samples.isEmpty else { return "" }
    guard let stream = SherpaOnnxCreateOfflineStream(offline) else { return "" }
    defer { SherpaOnnxDestroyOfflineStream(stream) }
    samples.withUnsafeBufferPointer {
      SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), $0.baseAddress, Int32(samples.count))
    }
    SherpaOnnxDecodeOfflineStream(offline, stream)
    guard let r = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
    defer { SherpaOnnxDestroyOfflineRecognizerResult(r) }
    return r.pointee.text.map { String(cString: $0) } ?? ""
  }

  // MARK: online

  func startStream() {
    guard let online else { return }
    if let onlineStream { SherpaOnnxDestroyOnlineStream(onlineStream) }
    onlineStream = SherpaOnnxCreateOnlineStream(online)
    committed = ""
  }

  /// Feed mic samples; returns the running transcript (committed + partial).
  func feed(_ samples: [Float], sampleRate: Int) -> String {
    guard let online, let onlineStream else { return committed }
    let rec = online
    let stream = onlineStream
    samples.withUnsafeBufferPointer {
      SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), $0.baseAddress, Int32(samples.count))
    }
    while SherpaOnnxIsOnlineStreamReady(rec, stream) == 1 {
      SherpaOnnxDecodeOnlineStream(rec, stream)
    }
    var partial = ""
    if let r = SherpaOnnxGetOnlineStreamResult(rec, stream) {
      partial = r.pointee.text.map { String(cString: $0) } ?? ""
      SherpaOnnxDestroyOnlineRecognizerResult(r)
    }
    if SherpaOnnxOnlineStreamIsEndpoint(rec, stream) == 1 {
      if !partial.isEmpty {
        committed = committed.isEmpty ? partial : "\(committed) \(partial)"
        partial = ""
      }
      SherpaOnnxOnlineStreamReset(rec, stream)
    }
    return partial.isEmpty ? committed : (committed.isEmpty ? partial : "\(committed) \(partial)")
  }

  func finishStream(sampleRate: Int) -> String {
    guard let online, let onlineStream else { return committed }
    let rec = online
    let stream = onlineStream
    let tail = [Float](repeating: 0, count: sampleRate / 2)
    tail.withUnsafeBufferPointer {
      SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), $0.baseAddress, Int32(tail.count))
    }
    SherpaOnnxOnlineStreamInputFinished(stream)
    while SherpaOnnxIsOnlineStreamReady(rec, stream) == 1 {
      SherpaOnnxDecodeOnlineStream(rec, stream)
    }
    var partial = ""
    if let r = SherpaOnnxGetOnlineStreamResult(rec, stream) {
      partial = r.pointee.text.map { String(cString: $0) } ?? ""
      SherpaOnnxDestroyOnlineRecognizerResult(r)
    }
    SherpaOnnxDestroyOnlineStream(stream)
    self.onlineStream = nil
    let full = partial.isEmpty ? committed : (committed.isEmpty ? partial : "\(committed) \(partial)")
    committed = ""
    return full
  }
}

/// Caches the loaded recognizer, model loads can take seconds for the
/// bigger Parakeet checkpoints.
final class SherpaEngineCache {
  static let shared = SherpaEngineCache()
  private var engine: SherpaEngine?
  private let lock = NSLock()
  private var evict: DispatchWorkItem?

  // Language and provider are baked into the recognizer config at creation, so a
  // change to either has to rebuild the engine, not reuse the cached one.
  func engine(for spec: ModelSpec, language: String, provider: String) -> SherpaEngine? {
    lock.lock()
    defer { lock.unlock() }
    scheduleEvictLocked()
    if let engine, engine.spec.id == spec.id, engine.language == language,
       engine.provider == provider { return engine }
    engine = nil // release the old model's memory before loading the next
    engine = SherpaEngine(spec: spec, language: language, provider: provider)
    return engine
  }

  // The big Parakeet checkpoints hold ~0.5-1.5 GB resident. Keep only a short
  // warm cache; offline jobs normally run in the isolated worker and unload on
  // exit, while live recognizers retain their own strong reference.
  private func scheduleEvictLocked() {
    evict?.cancel()
    let w = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.engine = nil
      self.lock.unlock()
      dlog("sherpa engine evicted after idle")
    }
    evict = w
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: w)
  }

  func unload() {
    lock.lock()
    defer { lock.unlock() }
    engine = nil
  }
}

/// Silero-VAD segmentation for the offline (non-streaming) recognizers. Long
/// audio is split into short speech segments before decoding so the recognizer
/// never sees more than a few seconds at once, bounding memory and keeping
/// Moonshine inside the ~10 s window past which it returns empty text.
final class SileroVAD {
  /// nil when the model can't be found/loaded; callers use bounded windows.
  static let shared: SileroVAD? = SileroVAD()

  // Moonshine tiny/base stop returning text past ~10 s (measured), so cap
  // continuous-speech segments below that.
  static let maxSegmentSeconds = 8
  static var maxSegmentSamples: Int { maxSegmentSeconds * 16000 }
  static let hardSplitOverlapSamples = 4_000 // 250 ms protects boundary words
  static let speechPaddingSamples = 4_800 // 300 ms protects VAD-cut word edges

  private let vad: OpaquePointer
  private let lock = NSLock()

  private init?() {
    guard let path = SileroVAD.modelPath() else {
      dlog("vad: silero_vad.onnx not found, long-audio segmentation disabled")
      return nil
    }
    var cfg = SherpaOnnxVadModelConfig()
    memset(&cfg, 0, MemoryLayout.size(ofValue: cfg))
    let model = strdup(path)
    let provider = strdup("cpu")
    defer { free(model); free(provider) } // sherpa copies the config strings
    cfg.silero_vad.model = UnsafePointer(model)
    cfg.silero_vad.threshold = 0.5
    cfg.silero_vad.min_silence_duration = 0.3
    cfg.silero_vad.min_speech_duration = 0.1
    cfg.silero_vad.max_speech_duration = Float(SileroVAD.maxSegmentSeconds)
    cfg.silero_vad.window_size = 512
    cfg.sample_rate = 16000
    cfg.num_threads = 1
    cfg.provider = UnsafePointer(provider)
    guard let v = SherpaOnnxCreateVoiceActivityDetector(&cfg, 30) else {
      dlog("vad: create failed")
      return nil
    }
    vad = v
    dlog("vad: silero loaded from \(path)")
  }

  deinit { SherpaOnnxDestroyVoiceActivityDetector(vad) }

  /// Split 16 kHz mono samples into speech segments.
  func segments16k(_ samples: [Float]) -> [[Float]] {
    guard !samples.isEmpty else { return [] }
    lock.lock()
    defer { lock.unlock() }
    SherpaOnnxVoiceActivityDetectorReset(vad)
    var ranges: [Range<Int>] = []
    let window = 512
    samples.withUnsafeBufferPointer { buf in
      guard let base = buf.baseAddress else { return }
      var i = 0
      while i + window <= samples.count {
        SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, base + i, Int32(window))
        i += window
        drain(&ranges)
      }
      if i < samples.count {
        SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, base + i, Int32(samples.count - i))
      }
    }
    SherpaOnnxVoiceActivityDetectorFlush(vad)
    drain(&ranges)
    return Self.paddedRanges(
      ranges, sampleCount: samples.count, padding: Self.speechPaddingSamples
    ).map { Array(samples[$0]) }
  }

  private func drain(_ out: inout [Range<Int>]) {
    while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
      guard let seg = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
      let start = max(0, Int(seg.pointee.start))
      let n = Int(seg.pointee.n)
      if n > 0 { out.append(start..<(start + n)) }
      SherpaOnnxDestroySpeechSegment(seg)
      SherpaOnnxVoiceActivityDetectorPop(vad)
    }
  }

  /// Expand VAD ranges into the original waveform rather than trusting the
  /// detector's already-trimmed sample copy. This keeps consonants immediately
  /// before/after the detected region and is deterministic enough to self-test.
  static func paddedRanges(
    _ ranges: [Range<Int>], sampleCount: Int,
    padding: Int = speechPaddingSamples
  ) -> [Range<Int>] {
    guard sampleCount > 0 else { return [] }
    return ranges.compactMap { range in
      let lower = Swift.max(0, Swift.min(range.lowerBound, sampleCount))
      let upper = Swift.max(lower, Swift.min(range.upperBound, sampleCount))
      guard upper > lower else { return nil }
      return Swift.max(0, lower - padding)..<Swift.min(sampleCount, upper + padding)
    }
  }

  /// Add neighboring acoustic context for a VAD segment whose first decode was
  /// empty. The hard maximum still applies, preserving the memory bound.
  static func retryWindow(
    segments: [[Float]], emptyIndex: Int, max: Int
  ) -> [Float] {
    guard segments.indices.contains(emptyIndex), max > 0 else { return [] }
    let current = segments[emptyIndex]
    let context = 16_000
    var retry: [Float]
    if segments.indices.contains(emptyIndex + 1) {
      retry = current + segments[emptyIndex + 1].prefix(context)
    } else if emptyIndex > 0 {
      retry = Array(segments[emptyIndex - 1].suffix(context)) + current
    } else {
      retry = current
    }
    if retry.count > max {
      // Keep the current island plus the nearest available context.
      return Array(retry.prefix(max))
    }
    return retry
  }

  /// Hard-cap segment length, silero's max_speech_duration nudges a split but
  /// doesn't guarantee one, so chop any run-on segment before it reaches the
  /// recognizer.
  static func split(_ seg: [Float], max: Int, overlap: Int = 0) -> [[Float]] {
    guard seg.count > max else { return [seg] }
    let safeOverlap = Swift.max(0, Swift.min(overlap, max / 2))
    let stride = max - safeOverlap
    var out: [[Float]] = []
    var i = 0
    while i < seg.count {
      let end = Swift.min(i + max, seg.count)
      out.append(Array(seg[i..<end]))
      if end == seg.count { break }
      i += stride
    }
    return out
  }

  /// Resample mono PCM to the 16 kHz the VAD and every ASR model expect.
  static func resampleTo16k(_ samples: [Float], from rate: Int) -> [Float] {
    if rate == 16000 || samples.isEmpty { return samples }
    guard
      let inFmt = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(rate),
        channels: 1, interleaved: false),
      let outFmt = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000,
        channels: 1, interleaved: false),
      let conv = AVAudioConverter(from: inFmt, to: outFmt),
      let inBuf = AVAudioPCMBuffer(
        pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(samples.count))
    else { return samples }
    inBuf.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in
      inBuf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
    }
    let cap = AVAudioFrameCount(Double(samples.count) * 16000 / Double(rate)) + 4096
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else {
      return samples
    }
    var supplied = false
    var err: NSError?
    let status = conv.convert(to: outBuf, error: &err) { _, inStatus in
      if supplied { inStatus.pointee = .endOfStream; return nil }
      supplied = true
      inStatus.pointee = .haveData
      return inBuf
    }
    guard status != .error, err == nil, outBuf.frameLength > 0,
          let out = outBuf.floatChannelData?[0] else {
      dlog("vad: resample \(rate)→16000 failed: \(err?.localizedDescription ?? "?")")
      return samples
    }
    return Array(UnsafeBufferPointer(start: out, count: Int(outBuf.frameLength)))
  }

  private static func modelPath() -> String? {
    let fm = FileManager.default
    var candidates: [URL] = []
    if let env = ProcessInfo.processInfo.environment["SCRIBE_VAD_MODEL"] {
      candidates.append(URL(fileURLWithPath: env))
    }
    if let res = Bundle.main.resourceURL {
      candidates.append(res.appendingPathComponent("silero_vad.onnx"))
    }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    candidates.append(
      exe.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/silero_vad.onnx"))
    candidates.append(
      ModelStore.root.deletingLastPathComponent().appendingPathComponent("silero_vad.onnx"))
    return candidates.first { fm.fileExists(atPath: $0.path) }?.path
  }
}
