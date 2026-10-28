import ActivityKit
import AppIntents
import AVFoundation
import Foundation
import React
import Speech
import UIKit

/// A Flow session: the mic stays open in the background (UIBackgroundModes audio) so the
/// keyboard and the Action Button can start and stop dictation without opening Bolkit.
/// Audio only reaches a transcriber between start and stop.
@MainActor
final class FlowEngine {
  static let shared = FlowEngine()

  enum Source { case keyboard, intent }

  private let capture = Capture()
  private var engine: AVAudioEngine?
  private var activity: Activity<DictationActivityAttributes>?
  private var state = FlowState()
  private var source = Source.keyboard
  private var request: String?
  private var since = Date()
  private var generation = 0
  private var making: Task<FlowTranscriber, Error>?
  private var heartbeat: Timer?
  private var idle: Timer?

  var isRecording: Bool { state.phase == .listening }

  private init() {
    FlowShared.observe(FlowShared.start) {
      guard let id = FlowShared.takeRequest(FlowShared.start) else { return }
      Task { @MainActor in try? await FlowEngine.shared.begin(.keyboard, request: id) }
    }
    FlowShared.observe(FlowShared.stop) {
      guard FlowShared.takeRequest(FlowShared.stop) != nil else { return }
      Task { @MainActor in await FlowEngine.shared.stopOrEnd() }
    }
    FlowShared.observe(FlowShared.cancel) {
      guard FlowShared.takeRequest(FlowShared.cancel) != nil else { return }
      Task { @MainActor in FlowEngine.shared.cancel() }
    }
    let center = NotificationCenter.default
    center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
      guard (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
      else { return }
      Task { @MainActor in
        await FlowEngine.shared.stop()
        FlowEngine.shared.end()
      }
    }
    center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { note in
      let changed = note.object as? AVAudioEngine
      Task { @MainActor in FlowEngine.shared.restart(changed) }
    }
    for stale in Activity<DictationActivityAttributes>.activities {
      Task { await stale.end(nil, dismissalPolicy: .immediate) }
    }
    FlowShared.write(state)
  }

  func begin(_ from: Source, request: String? = nil) async throws {
    guard state.phase == .idle || state.phase == .off else { return }
    try await prepare(from)
    source = from
    self.request = request
    since = Date()
    generation = capture.arm()
    let gen = generation
    let make = Task { try await FlowEngine.makeTranscriber() }
    making = make
    idle?.invalidate()
    state.error = nil
    set(.listening)
    Task {
      do {
        capture.attach(try await make.value, gen)
      } catch {
        guard gen == generation, state.phase == .listening else { return }
        capture.disarm()
        making = nil
        state.error = error.localizedDescription
        set(.idle)
        armIdle()
      }
    }
  }

  func prepare(_ from: Source = .keyboard) async throws {
    guard engine == nil else { return }
    do {
      try await open(from)
    } catch {
      state.error = error.localizedDescription
      publish(notify: true)
      throw error
    }
    armIdle()
  }

  @discardableResult
  func stop() async -> String? {
    guard state.phase == .listening, let make = making else { return nil }
    making = nil
    set(.transcribing)
    var text = ""
    do {
      let transcriber = try await make.value
      capture.attach(transcriber, generation)
      capture.disarm()
      text = VoiceCommands.apply(await transcriber.finish()).trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      capture.disarm()
      state.error = error.localizedDescription
    }
    state.resultID = UUID().uuidString
    state.resultText = text
    state.resultRequest = request
    state.resultAt = Date()
    if source == .intent, !text.isEmpty { UIPasteboard.general.string = text }
    set(.idle)
    armIdle()
    return text
  }

  func cancel() {
    guard state.phase == .listening else { return }
    discard()
    set(.idle)
    armIdle()
  }

  func end() {
    guard engine != nil || activity != nil || state.phase != .off else { return }
    discard()
    idle?.invalidate()
    heartbeat?.invalidate()
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    if let activity { Task { await activity.end(nil, dismissalPolicy: .immediate) } }
    activity = nil
    set(.off)
  }

  private func stopOrEnd() async {
    if state.phase == .listening { await stop() } else if state.phase == .idle { end() }
  }

  private func discard() {
    capture.disarm()
    if let make = making {
      Task { if let transcriber = try? await make.value { _ = await transcriber.finish() } }
    }
    making = nil
  }

  private func open(_ from: Source) async throws {
    let session = AVAudioSession.sharedInstance()
    if session.recordPermission == .undetermined {
      _ = await withCheckedContinuation { done in session.requestRecordPermission { done.resume(returning: $0) } }
    }
    guard session.recordPermission == .granted else { throw FlowError("Allow the microphone for Bolkit in Settings") }
    if ActivityAuthorizationInfo().areActivitiesEnabled {
      activity = try? Activity.request(
        attributes: DictationActivityAttributes(),
        content: ActivityContent(state: .init(phase: .idle, since: Date()), staleDate: nil)
      )
    }
    if from == .intent, activity == nil { throw FlowError("Turn on Live Activities for Bolkit in Settings") }
    do {
      try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
      try session.setActive(true)
      let engine = AVAudioEngine()
      FlowEngine.tap(engine, capture)
      engine.prepare()
      try engine.start()
      self.engine = engine
    } catch {
      end()
      throw FlowError("Bolkit couldn't open the microphone: \(error.localizedDescription)")
    }
    heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
      Task { @MainActor in FlowEngine.shared.publish(notify: false) }
    }
    set(.idle)
  }

  private func restart(_ changed: AVAudioEngine?) {
    guard let engine, changed === engine else { return }
    engine.inputNode.removeTap(onBus: 0)
    FlowEngine.tap(engine, capture)
    engine.prepare()
    do { try engine.start() } catch { end() }
  }

  private func armIdle() {
    idle?.invalidate()
    let seconds = max(FlowSettings.load().idleMinutes * 60, 1)
    idle = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
      Task { @MainActor in FlowEngine.shared.end() }
    }
  }

  private func set(_ phase: FlowPhase) {
    state.phase = phase
    publish(notify: true)
    guard let activity, phase != .off else { return }
    let content = ActivityContent(state: DictationActivityAttributes.ContentState(phase: phase, since: since), staleDate: nil)
    Task { await activity.update(content) }
  }

  private func publish(notify: Bool) {
    state.beat = state.phase == .off ? .distantPast : Date()
    FlowShared.write(state)
    if notify { FlowShared.post(FlowShared.changed) }
  }

  private nonisolated static func tap(_ engine: AVAudioEngine, _ capture: Capture) {
    let input = engine.inputNode
    input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
      capture.feed(buffer)
    }
  }

  private nonisolated static func makeTranscriber() async throws -> FlowTranscriber {
    let settings = FlowSettings.load()
    let locale = settings.hinglish ? "hi-IN" : "en-US"
    if #available(iOS 26.0, *), SpeechTranscriber.isAvailable {
      return try await AppleFlowTranscriber(locale: locale, romanize: settings.hinglish, terms: settings.terms)
    }
    return try await LegacyFlowTranscriber(locale: locale, romanize: settings.hinglish, terms: settings.terms)
  }
}

struct FlowError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

private struct FlowSettings {
  var terms: [String]
  var hinglish: Bool
  var idleMinutes: Double

  private static let base = [
    "Bolkit", "Gemma", "E2B", "E4B", "chunking", "on-device", "whisper.cpp", "Hinglish", "Oriserve", "Apex", "Swift",
  ]

  static func load() -> FlowSettings {
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("settings.json")
    let json = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
    var seen = Set<String>()
    let terms = (base + (json["vocab"] as? [String] ?? []))
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    return FlowSettings(
      terms: terms,
      hinglish: json["dictationStyle"] as? String == "hinglish",
      idleMinutes: json["flowIdleMinutes"] as? Double ?? 5
    )
  }
}

protocol FlowTranscriber: AnyObject, Sendable {
  func accept(_ buffer: AVAudioPCMBuffer)
  func finish() async -> String
}

/// Holds mic audio that arrives before the transcriber is ready, so the first word isn't lost.
private final class Capture: @unchecked Sendable {
  private let lock = NSLock()
  private var generation = 0
  private var armed = false
  private var sink: FlowTranscriber?
  private var pending: [AVAudioPCMBuffer] = []

  func arm() -> Int {
    lock.lock()
    defer { lock.unlock() }
    generation += 1
    armed = true
    sink = nil
    pending = []
    return generation
  }

  func attach(_ transcriber: FlowTranscriber, _ gen: Int) {
    lock.lock()
    defer { lock.unlock() }
    guard armed, gen == generation, sink == nil else { return }
    pending.forEach(transcriber.accept)
    pending = []
    sink = transcriber
  }

  func disarm() {
    lock.lock()
    defer { lock.unlock() }
    armed = false
    sink = nil
    pending = []
  }

  func feed(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard armed else { return }
    if let sink {
      sink.accept(buffer)
    } else if let copy = Capture.clone(buffer) {
      pending.append(copy)
    }
  }

  private static func clone(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
    copy.frameLength = buffer.frameLength
    let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
    let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for (s, d) in zip(src, dst) {
      guard let from = s.mData, let to = d.mData else { continue }
      memcpy(to, from, Int(min(s.mDataByteSize, d.mDataByteSize)))
    }
    return copy
  }
}

private final class Finals: @unchecked Sendable {
  private let lock = NSLock()
  private var parts: [String] = []

  func append(_ text: String) {
    lock.lock()
    parts.append(text)
    lock.unlock()
  }

  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
  }
}

@available(iOS 26.0, *)
private final class AppleFlowTranscriber: FlowTranscriber, @unchecked Sendable {
  private let session: LiveAppleSession
  private let finals: Finals

  init(locale: String, romanize: Bool, terms: [String]) async throws {
    let finals = Finals()
    session = try await LiveAppleSession(locale: locale, romanize: romanize, terms: terms) { text, isFinal in
      if isFinal { finals.append(text) }
    }
    self.finals = finals
  }

  func accept(_ buffer: AVAudioPCMBuffer) { session.accept(buffer) }

  func finish() async -> String {
    await session.finish()
    return finals.text
  }
}

private final class LegacyFlowTranscriber: FlowTranscriber, @unchecked Sendable {
  private let request = SFSpeechAudioBufferRecognitionRequest()
  private let romanize: Bool
  private let lock = NSLock()
  private var task: SFSpeechRecognitionTask?
  private var latest = ""
  private var done = false
  private var waiter: CheckedContinuation<Void, Never>?

  init(locale: String, romanize: Bool, terms: [String]) async throws {
    self.romanize = romanize
    if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
      _ = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
    }
    guard SFSpeechRecognizer.authorizationStatus() == .authorized,
          let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
          recognizer.supportsOnDeviceRecognition
    else { throw speechError("On-device speech recognition isn't available for \(locale)") }
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false
    request.contextualStrings = terms
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      self?.update(result?.bestTranscription.formattedString, final: error != nil || result?.isFinal == true)
    }
  }

  private func update(_ text: String?, final: Bool) {
    lock.lock()
    if let text { latest = text }
    var resume: CheckedContinuation<Void, Never>?
    if final, !done {
      done = true
      resume = waiter
      waiter = nil
    }
    lock.unlock()
    resume?.resume()
  }

  func accept(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }

  func finish() async -> String {
    request.endAudio()
    await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
      lock.lock()
      if done {
        lock.unlock()
        resume.resume()
        return
      }
      waiter = resume
      lock.unlock()
    }
    lock.lock()
    defer { lock.unlock() }
    return romanize ? Romanizer.mixed(latest) : latest
  }
}

@objc(BolkitFlow)
class BolkitFlowModule: NSObject {
  @objc static func requiresMainQueueSetup() -> Bool { false }

  @objc func end() {
    Task { @MainActor in FlowEngine.shared.end() }
  }

  @objc(status:rejecter:)
  func status(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
    let state = FlowShared.read()
    let error: Any = state.error ?? NSNull()
    resolve(["phase": state.alive ? state.phase.rawValue : "off", "error": error])
  }
}

@available(iOS 18.0, *)
struct QuickDictationIntent: AudioRecordingIntent, LiveActivityIntent {
  static let title: LocalizedStringResource = "Quick dictation to clipboard"
  static let description: IntentDescription? = IntentDescription("Run once to start listening, run again to stop. The text is copied to the clipboard.")

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let flow = FlowEngine.shared
    if flow.isRecording { return .result(value: await flow.stop() ?? "") }
    try await flow.begin(.intent)
    return .result(value: "")
  }
}

@available(iOS 18.0, *)
struct StartDictationIntent: AudioRecordingIntent, LiveActivityIntent {
  static let title: LocalizedStringResource = "Start dictation"
  static let description: IntentDescription? = IntentDescription("Starts on-device dictation in the background.")

  @MainActor
  func perform() async throws -> some IntentResult {
    try await FlowEngine.shared.begin(.intent)
    return .result()
  }
}

@available(iOS 18.0, *)
struct StopDictationIntent: AudioRecordingIntent {
  static let title: LocalizedStringResource = "Stop dictation"
  static let description: IntentDescription? = IntentDescription("Stops dictation, copies the text to the clipboard and returns it.")

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    .result(value: await FlowEngine.shared.stop() ?? "")
  }
}

@available(iOS 18.0, *)
struct BolkitShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: QuickDictationIntent(),
      phrases: ["Quick dictation with \(.applicationName)", "Dictate with \(.applicationName)"],
      shortTitle: "Quick dictation",
      systemImageName: "mic.fill"
    )
    AppShortcut(
      intent: StartDictationIntent(),
      phrases: ["Start dictation with \(.applicationName)"],
      shortTitle: "Start dictation",
      systemImageName: "mic"
    )
    AppShortcut(
      intent: StopDictationIntent(),
      phrases: ["Stop dictation with \(.applicationName)"],
      shortTitle: "Stop dictation",
      systemImageName: "stop.fill"
    )
  }
}
