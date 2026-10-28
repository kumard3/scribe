import AVFoundation
import Foundation
import React
import Speech

/// Apple's iOS 26+ SpeechAnalyzer, the same engine the Mac app dictates with. The older
/// SFSpeechRecognizer path dropped words at pauses and had no Hinglish mode.
/// Events on "ScribeAppleSpeech": start, result {text, isFinal}, level {value 0...1}, end, error {message}.
@objc(ScribeAppleSpeech)
class ScribeAppleSpeech: RCTEventEmitter {
  private var engine: AVAudioEngine?
  private var live: AnyObject?
  private var hasListeners = false

  override static func requiresMainQueueSetup() -> Bool { false }
  override func supportedEvents() -> [String]! { ["ScribeAppleSpeech"] }
  override func startObserving() { hasListeners = true }
  override func stopObserving() { hasListeners = false }

  private func emit(_ body: [String: Any]) {
    if hasListeners { sendEvent(withName: "ScribeAppleSpeech", body: body) }
  }

  @objc(isAvailable:rejecter:)
  func isAvailable(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
    if #available(iOS 26.0, *) { resolve(SpeechTranscriber.isAvailable) } else { resolve(false) }
  }

  @objc(start:romanize:terms:resolver:rejecter:)
  func start(
    _ locale: String, romanize: Bool, terms: [String],
    resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    guard #available(iOS 26.0, *) else { return reject("unavailable", "Apple speech needs iOS 26", nil) }
    Task {
      do {
        let session = try await LiveAppleSession(locale: locale, romanize: romanize, terms: terms) { [weak self] text, isFinal in
          self?.emit(["type": "result", "text": text, "isFinal": isFinal])
        }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audio.setActive(true)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var lastLevel = Date.distantPast
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
          session.accept(buffer)
          guard Date().timeIntervalSince(lastLevel) > 0.15, let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
          lastLevel = Date()
          var sum: Float = 0
          for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
          let rms = (sum / Float(buffer.frameLength)).squareRoot()
          self?.emit(["type": "level", "value": min(1, max(0.06, rms * 3.4))])
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.live = session
        emit(["type": "start"])
        resolve(nil)
      } catch {
        emit(["type": "error", "message": error.localizedDescription])
        reject("start", error.localizedDescription, error)
      }
    }
  }

  @objc(stop:rejecter:)
  func stop(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
    guard #available(iOS 26.0, *), let session = live as? LiveAppleSession else {
      emit(["type": "end"])
      return resolve(nil)
    }
    live = nil
    Task {
      await session.finish()
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      emit(["type": "end"])
      resolve(nil)
    }
  }

  /// A finished recording, whole, with word timings so speakers can be attributed.
  @objc(transcribeFile:locale:romanize:resolver:rejecter:)
  func transcribeFile(
    _ path: String, locale: String, romanize: Bool,
    resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    guard #available(iOS 26.0, *) else { return reject("unavailable", "Apple speech needs iOS 26", nil) }
    Task {
      do {
        let (text, words) = try await AppleFileTranscription.run(
          path: path.replacingOccurrences(of: "file://", with: ""), locale: locale, romanize: romanize
        )
        resolve(["text": text, "units": words])
      } catch {
        reject("transcribe", error.localizedDescription, error)
      }
    }
  }
}

func speechError(_ message: String) -> NSError {
  NSError(domain: "ScribeAppleSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

@available(iOS 26.0, *)
private func preparedTranscriber(_ id: String, preset: SpeechTranscriber.Preset) async throws -> SpeechTranscriber {
  guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
    throw speechError("\(id) isn't available in Apple speech on this iPhone")
  }
  let transcriber = SpeechTranscriber(locale: locale, preset: preset)
  if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    try await request.downloadAndInstall()
  }
  return transcriber
}

@available(iOS 26.0, *)
final class LiveAppleSession: @unchecked Sendable {
  private let analyzer: SpeechAnalyzer
  private let converter: AnalyzerInputConverter
  private let builder: AsyncStream<AnalyzerInput>.Continuation
  private var analysis: Task<CMTime?, Error>?
  private var results: Task<Void, Never>?

  init(locale: String, romanize: Bool, terms: [String], onText: @escaping (String, Bool) -> Void) async throws {
    let transcriber = try await preparedTranscriber(locale, preset: .progressiveTranscription)
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
      throw speechError("Apple speech assets are unavailable")
    }
    analyzer = SpeechAnalyzer(modules: [transcriber])
    converter = AnalyzerInputConverter(analyzerFormat: format)
    if !terms.isEmpty {
      let context = AnalysisContext()
      context.contextualStrings[.general] = terms
      try await analyzer.setContext(context)
    }
    let (stream, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
    self.builder = builder
    results = Task {
      do {
        for try await result in transcriber.results {
          let text = String(result.text.characters)
          onText(romanize ? Romanizer.mixed(text) : text, result.isFinal)
        }
      } catch {}
    }
    let analyzer = self.analyzer
    analysis = Task { try await analyzer.analyzeSequence(stream) }
  }

  func accept(_ buffer: AVAudioPCMBuffer) {
    if let converted = try? converter.convert(buffer) { builder.yield(AnalyzerInput(buffer: converted)) }
  }

  func finish() async {
    builder.finish()
    do {
      if let last = try await analysis?.value {
        try await analyzer.finalizeAndFinish(through: last)
      } else {
        await analyzer.cancelAndFinishNow()
      }
    } catch {
      await analyzer.cancelAndFinishNow()
    }
    await results?.value
  }
}

@available(iOS 26.0, *)
private enum AppleFileTranscription {
  static func run(path: String, locale: String, romanize: Bool) async throws -> (String, [[String: Any]]) {
    guard let id = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
      throw speechError("\(locale) isn't available in Apple speech on this iPhone")
    }
    let transcriber = SpeechTranscriber(
      locale: id, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange]
    )
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await request.downloadAndInstall()
    }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let collect = Task { () -> ([String], [[String: Any]]) in
      var phrases: [String] = []
      var words: [[String: Any]] = []
      for try await result in transcriber.results {
        let phrase = String(result.text.characters)
        phrases.append(romanize ? Romanizer.mixed(phrase) : phrase)
        for run in result.text.runs {
          guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
          let word = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
          if word.isEmpty { continue }
          words.append(["start": range.start.seconds, "end": range.end.seconds,
                        "text": romanize ? Romanizer.mixed(word) : word])
        }
      }
      return (phrases, words)
    }
    if let last = try await analyzer.analyzeSequence(from: file) {
      try await analyzer.finalizeAndFinish(through: last)
    } else {
      await analyzer.cancelAndFinishNow()
    }
    let (phrases, words) = try await collect.value
    return (phrases.joined(separator: " ").trimmingCharacters(in: .whitespaces), words)
  }
}

@available(iOS 26.0, *)
private final class AnalyzerInputConverter: @unchecked Sendable {
  private let analyzerFormat: AVAudioFormat
  private var converter: AVAudioConverter?
  private var sourceFormat: AVAudioFormat?

  init(analyzerFormat: AVAudioFormat) { self.analyzerFormat = analyzerFormat }

  func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
    if input.format == analyzerFormat { return input }
    if sourceFormat != input.format || converter == nil {
      guard let next = AVAudioConverter(from: input.format, to: analyzerFormat) else {
        throw speechError("Microphone audio format cannot be converted")
      }
      converter = next
      sourceFormat = input.format
    }
    guard let converter else { return nil }
    let ratio = analyzerFormat.sampleRate / max(input.format.sampleRate, 1)
    let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: max(capacity, 1)) else { return nil }
    var supplied = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
      if supplied {
        outStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      outStatus.pointee = .haveData
      return input
    }
    if let conversionError { throw conversionError }
    switch status {
    case .haveData, .inputRanDry: return output.frameLength > 0 ? output : nil
    default: return nil
    }
  }
}
