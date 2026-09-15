import AppKit
import AVFoundation

/// "Record meeting": the user's mic and everything the Mac plays go to two tracks,
/// so the transcript can label "You" and "Others" without diarization.
final class MeetingRecorder: ObservableObject {
  static let shared = MeetingRecorder()

  static var supported: Bool {
    if #available(macOS 14.4, *) { return true }
    return false
  }

  static var root: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Scribe/Meetings", isDirectory: true)
  }

  @Published private(set) var isRecording = false
  @Published private(set) var elapsed: TimeInterval = 0
  @Published private(set) var isTranscribing = false
  @Published private(set) var recordings: [MeetingItem] = []
  @Published private(set) var youLevel: Float = 0
  @Published private(set) var othersLevel: Float = 0

  struct MeetingItem: Identifiable {
    let id: URL
    let date: Date
    let duration: TimeInterval
    let hasTranscript: Bool
    var transcriptURL: URL { id.appendingPathComponent("transcript.txt") }
  }

  private var folder: URL?
  private var startedAt: Date?
  private var timer: Timer?
  private var levelTimer: Timer?
  private let engine = AVAudioEngine()
  private var micWriter: TrackWriter?
  private var systemWriter: TrackWriter?
  private var tap: AnyObject?

  var elapsedLabel: String {
    let s = Int(elapsed)
    return s >= 3600
      ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
      : String(format: "%02d:%02d", s / 60, s % 60)
  }

  init() { refreshRecordings() }

  func toggle() { isRecording ? stop() : start() }

  func refreshRecordings() {
    let fm = FileManager.default
    let dirs = (try? fm.contentsOfDirectory(
      at: Self.root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
    )) ?? []
    recordings = dirs.compactMap { dir -> MeetingItem? in
      let you = dir.appendingPathComponent("you.caf")
      guard let size = (try? fm.attributesOfItem(atPath: you.path))?[.size] as? Int else { return nil }
      let date = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
      return MeetingItem(
        id: dir, date: date,
        duration: Double(size) / Double(TranscriptionLimits.sampleRate * 2),
        hasTranscript: fm.fileExists(atPath: dir.appendingPathComponent("transcript.txt").path)
      )
    }
    .sorted { $0.date > $1.date }
  }

  func openTranscript(_ item: MeetingItem) { NSWorkspace.shared.open(item.transcriptURL) }

  func reveal(_ item: MeetingItem) { NSWorkspace.shared.activateFileViewerSelecting([item.id]) }

  func transcribeAgain(_ item: MeetingItem) {
    guard !isRecording, !isTranscribing else { return }
    transcribe(item.id, heardSystem: true)
  }

  func start() {
    let d = DictationManager.shared
    guard !isRecording, !isTranscribing else { return }
    guard Self.supported else { d.status = "Meeting recording needs macOS 14.4 or later."; return }
    guard !d.isRecording else { d.status = "Stop dictation before recording a meeting."; return }
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      DispatchQueue.main.async {
        guard granted else { d.status = "Enable Microphone for Scribe in System Settings."; return }
        self.begin()
      }
    }
  }

  private func begin() {
    let d = DictationManager.shared
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd_HHmm-ss"
    let dir = Self.root.appendingPathComponent(stamp.string(from: Date()), isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let mic = try TrackWriter(url: dir.appendingPathComponent("you.caf"))
      let system = try TrackWriter(url: dir.appendingPathComponent("others.caf"))

      if #available(macOS 14.4, *) {
        let t = SystemAudioTap(writer: system)
        try t.start()
        tap = t
      }

      let input = engine.inputNode
      input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in
        mic.append(buffer)
      }
      engine.prepare()
      try engine.start()

      micWriter = mic
      systemWriter = system
      folder = dir
      startedAt = Date()
      elapsed = 0
      isRecording = true
      refreshRecordings()
      timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        guard let self, let startedAt = self.startedAt else { return }
        self.elapsed = Date().timeIntervalSince(startedAt)
      }
      levelTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
        guard let self else { return }
        self.youLevel = self.micWriter?.level ?? 0
        self.othersLevel = self.systemWriter?.level ?? 0
      }
      d.status = "Recording meeting. Use headphones for clean You/Others labels."
      NotchHUD.shared.show()
    } catch {
      teardown()
      d.status = error.localizedDescription
    }
  }

  func stop() {
    guard isRecording, let dir = folder else { return }
    let heardSystem = (systemWriter?.peak ?? 0) > 0.0005
    teardown()
    isRecording = false
    NotchHUD.shared.hide()
    // AVAudioFile finalizes the CAF on deinit; let in-flight audio callbacks release the writers first.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      self.transcribe(dir, heardSystem: heardSystem)
    }
  }

  private func teardown() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    if #available(macOS 14.4, *) { (tap as? SystemAudioTap)?.stop() }
    tap = nil
    timer?.invalidate()
    timer = nil
    levelTimer?.invalidate()
    levelTimer = nil
    youLevel = 0
    othersLevel = 0
    micWriter = nil
    systemWriter = nil
  }

  func revealRecordings() {
    try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
    NSWorkspace.shared.open(folder ?? Self.root)
  }

  // MARK: - processing

  private func transcribe(_ dir: URL, heardSystem: Bool) {
    let d = DictationManager.shared
    let systemHint = heardSystem ? "" :
      " No system audio was captured: allow Scribe under System Settings > Privacy & Security > System Audio Recording."
    let spec = Settings.shared.activeModel
    guard spec.kind != .appleSystem, spec.kind != .llm, AudioImport.installed(spec) else {
      d.status = "Meeting saved. Download a model in the Dashboard to transcribe it." + systemHint
      refreshRecordings()
      return
    }
    isTranscribing = true
    d.phase = .transcribing
    d.status = "Preparing meeting transcript…"
    HUD.shared.show()
    let language = Settings.shared.language
    let provider = Settings.shared.sherpaProvider(for: spec)
    let speakers = Settings.shared.diarizeSpeakers

    DispatchQueue.global(qos: .userInitiated).async {
      let out = MeetingPipeline.run(
        dir: dir, spec: spec, language: language, provider: provider, speakerCount: speakers
      ) { d.status = $0 }
      let transcript = MeetingPipeline.text(out.turns, names: out.names)
      let file = (out.summary.map { "SUMMARY\n\($0)\n\nTRANSCRIPT\n" } ?? "") + transcript
      try? file.write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
      if let summary = out.summary {
        try? summary.write(to: dir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
      }
      DispatchQueue.main.async {
        self.isTranscribing = false
        d.phase = .idle
        HUD.shared.hide()
        self.refreshRecordings()
        guard !out.turns.isEmpty else {
          d.status = "Meeting saved, but no speech was detected." + systemHint
          return
        }
        d.importedResult(transcript)
        d.status = "Meeting transcript ready." + systemHint
        AudioImport.presentSpeakers(out.turns, source: "Meeting", names: out.names)
      }
    }
  }
}
