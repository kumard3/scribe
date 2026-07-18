import Foundation
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
        // int8 whisper decoders drop Devanagari/multibyte tokens — use fp32
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

/// Caches the loaded recognizer — model loads can take seconds for the
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

  // The big Parakeet checkpoints hold ~0.5-1.5 GB resident; drop the cache
  // after idle — callers keep their own strong reference mid-transcription,
  // so an in-flight decode is never torn down.
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
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 300, execute: w)
  }

  func unload() {
    lock.lock()
    defer { lock.unlock() }
    engine = nil
  }
}
