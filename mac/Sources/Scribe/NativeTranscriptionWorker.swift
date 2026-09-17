import AVFoundation
import Foundation
import Darwin

/// Runs native offline inference in a child Scribe process.
///
/// sherpa-onnx, ONNX Runtime, CoreML and llama.cpp can throw exceptions or
/// retain allocator arenas outside Swift's control. A worker boundary makes
/// those failures recoverable and guarantees that all native allocations are
/// returned to macOS when a job finishes.
final class NativeTranscriptionWorker: @unchecked Sendable {
  static let shared = NativeTranscriptionWorker()
  private let queue = DispatchQueue(label: "ai.scribe.native-worker", qos: .userInitiated)
  private var qwenSession: QwenSession?
  private var qwenIdle: DispatchWorkItem?

  enum WorkerError: LocalizedError {
    case executableMissing
    case helperMissing
    case timedOut
    case memoryLimitExceeded(UInt64)
    case failed(Int32, String)
    case emptyResult

    var errorDescription: String? {
      switch self {
      case .executableMissing: return "Bolkit transcription worker is unavailable"
      case .helperMissing: return "The on-device Hinglish runtime is missing, reinstall Bolkit"
      case .timedOut:
        return "Transcription timed out, audio kept, use Retry last recording"
      case let .memoryLimitExceeded(bytes):
        return "Stopped at the \(bytes / 1_000_000) MB memory limit, "
          + "audio kept, use Retry last recording"
      case let .failed(code, detail):
        return detail.isEmpty ? "Transcription worker failed (\(code))" : detail
      case .emptyResult: return "No speech was detected"
      }
    }
  }

  func transcribe(
    spec: ModelSpec, samples: [Float], sampleRate: Int,
    language: String, provider: String,
    saveDiagnostic: Bool = true,
    timeout: TimeInterval? = nil,
    completion finish: @escaping (Result<String, Error>) -> Void
  ) {
    let completion: (Result<String, Error>) -> Void = { finish($0.map(Vocabulary.stripPromptEcho)) }
    if MLXRuntime.gemmaAsrUsesMlx(spec) {
      if saveDiagnostic, Settings.shared.keepLatestRecording {
        DiagnosticAudioStore.saveLatest(samples: samples, sampleRate: sampleRate)
      }
      let seconds = Double(samples.count) / Double(max(sampleRate, 1))
      let maxTokens = Int32(min(512, max(64, Int(seconds * 12))))
      MLXRuntime.shared.transcribe(
        samples: samples, sampleRate: sampleRate,
        instruction: ModelCatalog.asrPrompt(for: spec),
        maxTokens: maxTokens
      ) { text in
        if let text {
          completion(.success(text))
        } else if Self.ggufReady(spec) {
          self.queue.async {
            let result: Result<String, Error>
            do {
              result = .success(try self.run(
                spec: spec, samples: samples, sampleRate: sampleRate,
                language: language, provider: provider,
                saveDiagnostic: false, timeout: timeout
              ))
            } catch {
              result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
          }
        } else {
          completion(.failure(WorkerError.emptyResult))
        }
      }
      return
    }
    queue.async {
      let result: Result<String, Error>
      do {
        if spec.kind == .qwenAsr {
          result = .success(try self.runQwenPersistent(
            spec: spec, samples: samples, sampleRate: sampleRate,
            saveDiagnostic: saveDiagnostic, timeout: timeout
          ))
        } else {
          result = .success(try self.run(
            spec: spec, samples: samples, sampleRate: sampleRate,
            language: language, provider: provider,
            saveDiagnostic: saveDiagnostic, timeout: timeout
          ))
        }
      } catch {
        result = .failure(error)
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  func warmQwen(_ spec: ModelSpec) {
    guard spec.kind == .qwenAsr, !MLXRuntime.gemmaAsrUsesMlx(spec) else { return }
    queue.async {
      do {
        _ = try self.ensureQwenSession(spec)
        self.scheduleQwenIdle()
        dlog("qwen session warmed")
      } catch {
        dlog("qwen session warm failed: \(error.localizedDescription)")
      }
    }
  }

  func releaseQwen() {
    queue.async { self.quitQwenSession() }
  }

  /// Sherpa models only (not whisper.cpp, Qwen/Gemma audio): one child process loads the model once for
  /// all clips. Per-clip workers reloaded a 600 MB model 339 times (42 min) for one meeting. Blocking.
  func transcribeBatch(
    spec: ModelSpec, clips: [[Float]], sampleRate: Int, language: String, provider: String,
    progress: (Int) -> Void
  ) throws -> [String] {
    guard spec.kind != .whisperCpp, spec.kind != .qwenAsr, !MLXRuntime.gemmaAsrUsesMlx(spec) else {
      throw WorkerError.failed(-1, "batch not supported for \(spec.id)")
    }
    guard let executable = Bundle.main.executableURL else { throw WorkerError.executableMissing }
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("scribe-batch-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    var paths: [String] = []
    for (i, clip) in clips.enumerated() {
      let url = dir.appendingPathComponent("\(i).wav")
      try WaveFile.write(samples: clip, sampleRate: sampleRate, to: url)
      paths.append(url.path)
    }
    let list = dir.appendingPathComponent("list.txt")
    try paths.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
    let stdoutURL = dir.appendingPathComponent("out.txt")
    fm.createFile(atPath: stdoutURL.path, contents: nil)
    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    defer { try? stdoutHandle.close() }

    let process = Process()
    process.executableURL = executable
    process.arguments = ["--transcribe-batch", list.path, spec.id, "--language", language, "--provider", provider]
    process.environment = ProcessInfo.processInfo.environment
    let stderrURL = dir.appendingPathComponent("err.txt")
    fm.createFile(atPath: stderrURL.path, contents: nil)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    defer { try? stderrHandle.close() }
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle
    try process.run()

    let longest = Double(clips.map(\.count).max() ?? 0) / Double(max(sampleRate, 1))
    let total = Double(clips.reduce(0) { $0 + $1.count }) / Double(max(sampleRate, 1))
    // ponytail: one loaded model plus the longest clip; measured 1.9 GB peak for Parakeet 0.6B on 30 s clips.
    let memoryLimit = min(ProcessInfo.processInfo.physicalMemory / 2,
                          max(3_000_000_000, TranscriptionLimits.workerMemoryLimit(for: spec, audioSeconds: longest)))
    let deadline = Date().addingTimeInterval(TranscriptionLimits.workerTimeout(audioSeconds: total) + 120)
    var done = 0
    while process.isRunning, Date() < deadline {
      if Self.residentBytes(process.processIdentifier) > memoryLimit {
        Self.stop(process)
        throw WorkerError.memoryLimitExceeded(memoryLimit)
      }
      let lines = ((try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "").filter { $0 == "\n" }.count
      if lines != done { done = lines; progress(done) }
      Thread.sleep(forTimeInterval: 0.2)
    }
    if process.isRunning {
      Self.stop(process)
      throw WorkerError.timedOut
    }
    let texts = ((try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "")
      .split(separator: "\n")
      .map { (try? JSONDecoder().decode(String.self, from: Data($0.utf8))) ?? "" }
    guard process.terminationStatus == 0, texts.count == clips.count else {
      let detail = ((try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "").suffix(400)
      throw WorkerError.failed(process.terminationStatus, "batch returned \(texts.count) of \(clips.count): \(detail)")
    }
    return texts.map(Vocabulary.stripPromptEcho)
  }

  private static func ggufReady(_ spec: ModelSpec) -> Bool {
    let dir = ModelStore.dir(for: spec)
    let fm = FileManager.default
    return fm.fileExists(atPath: dir.appendingPathComponent(spec.fileName).path)
      && fm.fileExists(atPath: dir.appendingPathComponent(spec.mmprojFileName).path)
  }

  private func run(
    spec: ModelSpec, samples: [Float], sampleRate: Int,
    language: String, provider: String,
    saveDiagnostic: Bool = true,
    timeout: TimeInterval? = nil
  ) throws -> String {
    // Saved before transcription, not after: a failed or timed-out run is
    // exactly when the audio still needs to exist. Incremental dictation
    // streams its own full-length copy instead (chunked jobs would otherwise
    // overwrite the file with a fragment).
    if saveDiagnostic, Settings.shared.keepLatestRecording {
      DiagnosticAudioStore.saveLatest(samples: samples, sampleRate: sampleRate)
    }
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-worker-\(UUID().uuidString).wav")
    let stdoutURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-worker-\(UUID().uuidString).stdout")
    let stderrURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-worker-\(UUID().uuidString).stderr")
    defer {
      try? FileManager.default.removeItem(at: temp)
      try? FileManager.default.removeItem(at: stdoutURL)
      try? FileManager.default.removeItem(at: stderrURL)
    }
    if spec.kind == .whisperCpp {
      let resampled = SileroVAD.resampleTo16k(samples, from: sampleRate)
      let audio = Settings.shared.conditionAudio
        ? AudioConditioner.process16k(resampled) : resampled
      try WaveFile.write(samples: audio, sampleRate: 16_000, to: temp)
    } else {
      try WaveFile.write(samples: samples, sampleRate: sampleRate, to: temp)
    }
    _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    defer {
      try? stdoutHandle.close()
      try? stderrHandle.close()
    }

    let process = Process()
    if spec.kind == .whisperCpp {
      let helper = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/Whisper/whisper-cli")
      guard FileManager.default.isExecutableFile(atPath: helper.path) else {
        throw WorkerError.helperMissing
      }
      let model = ModelStore.dir(for: spec).appendingPathComponent(spec.fileName)
      process.executableURL = helper
      process.arguments = [
        "-m", model.path, "-f", temp.path,
        "-l", WhisperDecode.language(for: spec), "-np", "-nt", "-t", "4", "-sns",
      ]
      if let prompt = Vocabulary.whisperPrompt {
        process.arguments? += ["--prompt", prompt]
      }
    } else if spec.kind == .qwenAsr {
      guard let executable = Bundle.main.executableURL else {
        throw WorkerError.executableMissing
      }
      process.executableURL = executable
      let dir = ModelStore.dir(for: spec)
      process.arguments = [
        "--asr", temp.path,
        dir.appendingPathComponent(spec.fileName).path,
        dir.appendingPathComponent(spec.mmprojFileName).path,
      ]
      let instruction = ModelCatalog.asrPrompt(for: spec)
      if !instruction.isEmpty {
        process.arguments? += ["--asr-instruction", instruction]
      }
      if Romanizer.wantsLatinOnly {
        process.arguments? += ["--latin-only"]
      }
    } else {
      guard let executable = Bundle.main.executableURL else {
        throw WorkerError.executableMissing
      }
      process.executableURL = executable
      process.arguments = [
        "--transcribe", temp.path, spec.id,
        "--language", language, "--provider", provider,
      ]
    }
    process.environment = ProcessInfo.processInfo.environment

    // Regular files cannot fill up and block the child. Pipes previously made
    // a verbose native backend deadlock once its diagnostics exceeded ~64 KB.
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle
    try process.run()

    let audioSeconds = Double(samples.count) / Double(max(sampleRate, 1))
    let deadline = Date().addingTimeInterval(
      timeout ?? TranscriptionLimits.workerTimeout(audioSeconds: audioSeconds)
    )
    let memoryLimit = TranscriptionLimits.workerMemoryLimit(
      for: spec, audioSeconds: audioSeconds
    )
    var peakResident: UInt64 = 0
    while process.isRunning, Date() < deadline {
      let resident = Self.residentBytes(process.processIdentifier)
      peakResident = max(peakResident, resident)
      if resident > memoryLimit {
        Self.stop(process)
        throw WorkerError.memoryLimitExceeded(memoryLimit)
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      Self.stop(process)
      throw WorkerError.timedOut
    }
    dlog("worker \(spec.id) peak resident \(peakResident / 1_000_000) MB")

    try? stdoutHandle.close()
    try? stderrHandle.close()
    let output = (try? Data(contentsOf: stdoutURL)) ?? Data()
    let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
    let detail = String(data: errorData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let text = String(data: output, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if process.terminationStatus != 0 {
      if !text.isEmpty { return text }
      throw WorkerError.failed(process.terminationStatus, String(detail.suffix(600)))
    }
    guard !text.isEmpty else { throw WorkerError.emptyResult }
    return text
  }

  private final class QwenSession {
    let process: Process
    let stdinPipe: Pipe
    let stdoutPipe: Pipe
    let stderrHandle: FileHandle
    let key: String
    var pending = Data()
    var stdin: FileHandle { stdinPipe.fileHandleForWriting }
    var stdout: FileHandle { stdoutPipe.fileHandleForReading }

    init(
      process: Process, stdinPipe: Pipe, stdoutPipe: Pipe,
      stderrHandle: FileHandle, key: String
    ) {
      self.process = process
      self.stdinPipe = stdinPipe
      self.stdoutPipe = stdoutPipe
      self.stderrHandle = stderrHandle
      self.key = key
    }
  }

  private func runQwenPersistent(
    spec: ModelSpec, samples: [Float], sampleRate: Int,
    saveDiagnostic: Bool, timeout: TimeInterval?
  ) throws -> String {
    if saveDiagnostic, Settings.shared.keepLatestRecording {
      DiagnosticAudioStore.saveLatest(samples: samples, sampleRate: sampleRate)
    }
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-worker-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: temp) }
    try WaveFile.write(samples: samples, sampleRate: sampleRate, to: temp)
    let audioSeconds = Double(samples.count) / Double(max(sampleRate, 1))
    let deadline = Date().addingTimeInterval(
      timeout ?? TranscriptionLimits.chunkWorkerTimeout(audioSeconds: audioSeconds)
    )
    do {
      let session = try ensureQwenSession(spec)
      try session.stdin.write(contentsOf: Data((temp.path + "\n").utf8))
      let line = try readSessionLine(session, deadline: deadline)
      guard let count = Int(line), count >= 0 else {
        throw WorkerError.failed(-1, "asr session bad header \(line)")
      }
      let body = try readSessionBytes(session, count: count, deadline: deadline)
      let text = String(data: body, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      scheduleQwenIdle()
      guard !text.isEmpty else { throw WorkerError.emptyResult }
      dlog("qwen session transcribed \(text.count) chars from \(samples.count) samples")
      return text
    } catch let error as WorkerError {
      if case .emptyResult = error { throw error }
      if case .timedOut = error { throw error }
      quitQwenSession()
      dlog("qwen session failed, one-shot fallback: \(error.localizedDescription)")
      return try run(
        spec: spec, samples: samples, sampleRate: sampleRate,
        language: Settings.shared.language, provider: "cpu",
        saveDiagnostic: false, timeout: timeout
      )
    } catch {
      quitQwenSession()
      dlog("qwen session failed, one-shot fallback: \(error.localizedDescription)")
      return try run(
        spec: spec, samples: samples, sampleRate: sampleRate,
        language: Settings.shared.language, provider: "cpu",
        saveDiagnostic: false, timeout: timeout
      )
    }
  }

  private func ensureQwenSession(_ spec: ModelSpec) throws -> QwenSession {
    qwenIdle?.cancel()
    let dir = ModelStore.dir(for: spec)
    let model = dir.appendingPathComponent(spec.fileName).path
    let mmproj = dir.appendingPathComponent(spec.mmprojFileName).path
    let instruction = ModelCatalog.asrPrompt(for: spec)
    let latin = Romanizer.wantsLatinOnly
    let key = "\(model)|\(mmproj)|\(latin)|\(instruction)"
    if let existing = qwenSession, existing.key == key, existing.process.isRunning {
      return existing
    }
    quitQwenSession()
    guard let executable = Bundle.main.executableURL else {
      throw WorkerError.executableMissing
    }
    let stderrURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-asr-serve-\(UUID().uuidString).stderr")
    _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let process = Process()
    process.executableURL = executable
    var args = ["--asr-serve", model, mmproj]
    if !instruction.isEmpty {
      args += ["--asr-instruction", instruction]
    }
    if latin { args.append("--latin-only") }
    process.arguments = args
    process.environment = ProcessInfo.processInfo.environment
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrHandle
    try process.run()
    let flags = fcntl(stdoutPipe.fileHandleForReading.fileDescriptor, F_GETFL)
    if flags >= 0 {
      _ = fcntl(stdoutPipe.fileHandleForReading.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }
    let session = QwenSession(
      process: process,
      stdinPipe: stdinPipe,
      stdoutPipe: stdoutPipe,
      stderrHandle: stderrHandle,
      key: key
    )
    let deadline = Date().addingTimeInterval(40)
    var ready = ""
    while Date() < deadline {
      ready = try readSessionLine(session, deadline: deadline)
      if ready == "READY" { break }
    }
    guard ready == "READY" else {
      Self.stop(process)
      throw WorkerError.failed(-1, "asr session handshake \(ready)")
    }
    qwenSession = session
    dlog("qwen session ready pid=\(process.processIdentifier)")
    return session
  }

  private func readSessionLine(_ session: QwenSession, deadline: Date) throws -> String {
    while true {
      if let idx = session.pending.firstIndex(of: 10) {
        let line = session.pending.prefix(upTo: idx)
        session.pending.removeSubrange(...idx)
        return String(data: Data(line), encoding: .utf8) ?? ""
      }
      try fillSession(session, deadline: deadline)
    }
  }

  private func readSessionBytes(
    _ session: QwenSession, count: Int, deadline: Date
  ) throws -> Data {
    if count == 0 { return Data() }
    while session.pending.count < count {
      try fillSession(session, deadline: deadline)
    }
    let out = Data(session.pending.prefix(count))
    session.pending.removeFirst(count)
    return out
  }

  private func fillSession(_ session: QwenSession, deadline: Date) throws {
    if Date() >= deadline {
      throw WorkerError.timedOut
    }
    if !session.process.isRunning {
      throw WorkerError.failed(session.process.terminationStatus, "asr session exited")
    }
    var pfd = pollfd(fd: session.stdout.fileDescriptor, events: Int16(POLLIN), revents: 0)
    let ms = Int32(min(max(deadline.timeIntervalSinceNow * 1000, 1), 250))
    let n = poll(&pfd, 1, ms)
    if n < 0 { throw WorkerError.failed(-1, "asr session poll failed") }
    if n == 0 { return }
    let chunk = session.stdout.availableData
    if chunk.isEmpty {
      if !session.process.isRunning {
        throw WorkerError.failed(session.process.terminationStatus, "asr session exited")
      }
      return
    }
    session.pending.append(chunk)
  }

  private func scheduleQwenIdle() {
    qwenIdle?.cancel()
    let w = DispatchWorkItem { [weak self] in
      self?.quitQwenSession()
      dlog("qwen session evicted after idle")
    }
    qwenIdle = w
    queue.asyncAfter(deadline: .now() + 60, execute: w)
  }

  private func quitQwenSession() {
    qwenIdle?.cancel()
    qwenIdle = nil
    guard let session = qwenSession else { return }
    qwenSession = nil
    try? session.stdin.write(contentsOf: Data("QUIT\n".utf8))
    try? session.stdin.close()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
      if session.process.isRunning { Self.stop(session.process) }
    }
  }

  private static func residentBytes(_ pid: pid_t) -> UInt64 {
    var info = proc_taskinfo()
    let read = withUnsafeMutablePointer(to: &info) { pointer in
      proc_pidinfo(
        pid, PROC_PIDTASKINFO, 0, pointer,
        Int32(MemoryLayout<proc_taskinfo>.size)
      )
    }
    return read == MemoryLayout<proc_taskinfo>.size ? info.pti_resident_size : 0
  }

  private static func stop(_ process: Process) {
    process.terminate()
    Thread.sleep(forTimeInterval: 0.1)
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }
}

enum WaveFile {
  static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
      channels: 1, interleaved: false
    ), let buffer = AVAudioPCMBuffer(
      pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
    ) else {
      throw CocoaError(.fileWriteUnknown)
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      guard let base = source.baseAddress else { return }
      buffer.floatChannelData![0].update(from: base, count: samples.count)
    }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    try file.write(from: buffer)
  }
}

enum DiagnosticAudioStore {
  static var latestURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Scribe/Diagnostics", isDirectory: true)
      .appendingPathComponent("latest-dictation.wav")
  }

  // Streaming session for incremental dictation. sherpaQueue-only: capture is
  // serialized there, so these need no locking of their own.
  private static var sessionHandle: FileHandle?
  private static var sessionURL: URL?
  private static var sessionRate = 0
  private static var sessionDataBytes = 0

  /// Appends to the in-progress dictation recording, starting one lazily and
  /// restarting it whenever the capture rate changes (Bluetooth rebinds).
  static func stream(_ samples: [Float], sampleRate: Int) {
    guard Settings.shared.keepLatestRecording, !samples.isEmpty else { return }
    if sessionHandle == nil || sessionRate != sampleRate {
      discardSession()
      beginSession(sampleRate: sampleRate)
    }
    guard let handle = sessionHandle else { return }
    samples.withUnsafeBytes { buffer in
      try? handle.write(contentsOf: buffer)
      sessionDataBytes += buffer.count
    }
  }

  /// Closes the streaming session and promotes it to latest-dictation.wav.
  static func endSession() {
    guard let handle = sessionHandle, let url = sessionURL else { return }
    sessionHandle = nil
    sessionURL = nil
    let rate = sessionRate
    let dataBytes = sessionDataBytes
    sessionRate = 0
    sessionDataBytes = 0
    try? handle.close()
    guard rate > 0 else { return }
    try? float32Header(sampleRate: rate, dataBytes: dataBytes).write(to: url)
    replaceLatest(with: url)
  }

  private static func beginSession(sampleRate: Int) {
    guard sampleRate > 0 else { return }
    let directory = latestURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true
    )
    let pending = directory.appendingPathComponent("latest-dictation.pending.wav")
    try? FileManager.default.removeItem(at: pending)
    guard FileManager.default.createFile(atPath: pending.path, contents: nil),
          let handle = try? FileHandle(forWritingTo: pending) else { return }
    sessionHandle = handle
    sessionURL = pending
    sessionRate = sampleRate
    sessionDataBytes = 0
    try? float32Header(sampleRate: sampleRate, dataBytes: 0).write(to: pending)
    dlog("diagnostic stream started @\(sampleRate)Hz")
  }

  private static func discardSession() {
    guard let handle = sessionHandle, let url = sessionURL else { return }
    sessionHandle = nil
    sessionURL = nil
    sessionRate = 0
    sessionDataBytes = 0
    try? handle.close()
    try? FileManager.default.removeItem(at: url)
  }

  private static func replaceLatest(with temporary: URL) {
    do {
      _ = try FileManager.default.replaceItemAt(
        latestURL, withItemAt: temporary, backupItemName: nil,
        options: [.usingNewMetadataOnly]
      )
      dlog("saved latest diagnostic audio")
    } catch {
      // replaceItem requires an existing destination on some macOS versions.
      do {
        try? FileManager.default.removeItem(at: latestURL)
        try FileManager.default.moveItem(at: temporary, to: latestURL)
        dlog("saved latest diagnostic audio")
      } catch {
        dlog("could not save diagnostic audio: \(error.localizedDescription)")
      }
    }
  }

  private static func float32Header(sampleRate: Int, dataBytes: Int) -> Data {
    func append(_ v: UInt32) {
      var le = v.littleEndian
      withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
    }
    func append16(_ v: UInt16) {
      var le = v.littleEndian
      withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
    }
    var header = Data()
    func str(_ s: String) { header.append(s.data(using: .ascii)!) }
    str("RIFF"); append(UInt32(36 + dataBytes)); str("WAVE")
    str("fmt "); append(16); append16(3); append16(1)
    append(UInt32(sampleRate)); append(UInt32(sampleRate * 4))
    append16(4); append16(32)
    str("data"); append(UInt32(dataBytes))
    return header
  }

  static func saveLatest(samples: [Float], sampleRate: Int) {
    guard !samples.isEmpty else { return }
    do {
      let directory = latestURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true
      )
      let temporary = directory.appendingPathComponent("latest-dictation.pending.wav")
      try? FileManager.default.removeItem(at: temporary)
      try WaveFile.write(samples: samples, sampleRate: sampleRate, to: temporary)
      dlog("saved latest diagnostic audio: \(samples.count) samples @\(sampleRate)Hz")
      replaceLatest(with: temporary)
    } catch {
      dlog("could not save diagnostic audio: \(error.localizedDescription)")
    }
  }
}
