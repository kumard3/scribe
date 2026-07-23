import AVFoundation
import Foundation
import Speech

/// macOS 26's long-form, on-device speech pipeline. Apple's model runs outside
/// Scribe's address space and replaces the short-utterance SFSpeechRecognizer
/// path on supported systems.
@available(macOS 26.0, *)
final class ModernSpeechSession: @unchecked Sendable {
  private let transcriber: SpeechTranscriber
  private let analyzer: SpeechAnalyzer
  private let converter: ModernAnalyzerInputConverter
  private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
  private let inputSequence: AsyncStream<AnalyzerInput>
  private let stateLock = NSLock()

  private var finalized: [String] = []
  private var volatile = ""
  private var resultTask: Task<Void, Never>?
  private var analysisTask: Task<CMTime?, Error>?
  private var finished = false
  private let onUpdate: (String) -> Void

  init(locale identifier: String, onUpdate: @escaping (String) -> Void) async throws {
    guard let locale = await SpeechTranscriber.supportedLocale(
      equivalentTo: Locale(identifier: identifier)
    ) else {
      throw NSError(
        domain: "Scribe.ModernSpeech", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "This language is not available in Apple Transcription"]
      )
    }
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await request.downloadAndInstall()
    }
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    else {
      throw NSError(
        domain: "Scribe.ModernSpeech", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Apple Transcription assets are unavailable"]
      )
    }
    self.transcriber = transcriber
    self.analyzer = SpeechAnalyzer(modules: [transcriber])
    self.converter = ModernAnalyzerInputConverter(analyzerFormat: format)
    (self.inputSequence, self.inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
    self.onUpdate = onUpdate
    try await analyzer.prepareToAnalyze(in: format)
  }

  func start() {
    resultTask = Task { [weak self] in
      guard let self else { return }
      do {
        for try await result in transcriber.results {
          let text = String(result.text.characters)
          let visible = stateLock.withLock {
            if result.isFinal {
              if !text.isEmpty { self.finalized.append(text) }
              self.volatile = ""
            } else {
              self.volatile = text
            }
            return self.visibleTextLocked()
          }
          onUpdate(visible)
        }
      } catch {
        dlog("SpeechAnalyzer results error: \(error.localizedDescription)")
      }
    }
    analysisTask = Task { try await analyzer.analyzeSequence(inputSequence) }
  }

  /// Called only by AVAudioEngine's capture callback.
  func accept(_ buffer: AVAudioPCMBuffer) {
    let shouldIgnore = stateLock.withLock { finished }
    guard !shouldIgnore else { return }
    do {
      if let converted = try converter.convert(buffer) {
        inputBuilder.yield(AnalyzerInput(buffer: converted))
      }
    } catch {
      dlog("SpeechAnalyzer convert error: \(error.localizedDescription)")
    }
  }

  func finish(completion: @escaping (String) -> Void) {
    let wasAlreadyFinished = stateLock.withLock {
      if finished { return true }
      finished = true
      return false
    }
    guard !wasAlreadyFinished else { return }

    Task { [weak self] in
      guard let self else { return }
      do {
        inputBuilder.finish()
        let lastTime = try await analysisTask?.value
        if let lastTime { try await analyzer.finalizeAndFinish(through: lastTime) }
        else { await analyzer.cancelAndFinishNow() }
        await resultTask?.value
      } catch {
        dlog("SpeechAnalyzer finish error: \(error.localizedDescription)")
        await analyzer.cancelAndFinishNow()
      }
      let text = stateLock.withLock { self.visibleTextLocked() }
      DispatchQueue.main.async { completion(text) }
    }
  }

  private func visibleTextLocked() -> String {
    (finalized + (volatile.isEmpty ? [] : [volatile])).joined(separator: " ")
  }
}

/// Converts arbitrary microphone PCM into the exact format selected by
/// SpeechAnalyzer. `AnalyzerInputConverter` existed in early SDK examples but
/// is not part of the released macOS 26 SDK, so keep this small adapter local.
@available(macOS 26.0, *)
private final class ModernAnalyzerInputConverter: @unchecked Sendable {
  private let analyzerFormat: AVAudioFormat
  private var converter: AVAudioConverter?
  private var sourceFormat: AVAudioFormat?

  init(analyzerFormat: AVAudioFormat) {
    self.analyzerFormat = analyzerFormat
  }

  /// AVAudioEngine invokes this serially on its render callback.
  func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
    if input.format == analyzerFormat { return input }
    if sourceFormat != input.format || converter == nil {
      guard let next = AVAudioConverter(from: input.format, to: analyzerFormat) else {
        throw NSError(
          domain: "Scribe.ModernSpeech", code: 3,
          userInfo: [NSLocalizedDescriptionKey: "Microphone audio format cannot be converted"]
        )
      }
      converter = next
      sourceFormat = input.format
    }
    guard let converter else { return nil }
    let ratio = analyzerFormat.sampleRate / max(input.format.sampleRate, 1)
    let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
    guard let output = AVAudioPCMBuffer(
      pcmFormat: analyzerFormat, frameCapacity: max(capacity, 1)
    ) else {
      throw CocoaError(.coderInvalidValue)
    }
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
    case .haveData, .inputRanDry:
      return output.frameLength > 0 ? output : nil
    case .endOfStream:
      return nil
    case .error:
      throw NSError(
        domain: "Scribe.ModernSpeech", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Microphone audio conversion failed"]
      )
    @unknown default:
      return nil
    }
  }
}
