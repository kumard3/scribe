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

  enum WorkerError: LocalizedError {
    case executableMissing
    case helperMissing
    case timedOut
    case memoryLimitExceeded(UInt64)
    case failed(Int32, String)
    case emptyResult

    var errorDescription: String? {
      switch self {
      case .executableMissing: return "Scribe transcription worker is unavailable"
      case .helperMissing: return "The on-device Hinglish runtime is missing, reinstall Scribe"
      case .timedOut: return "Transcription exceeded the safety time limit"
      case let .memoryLimitExceeded(bytes):
        return "Transcription stopped at the \(bytes / 1_000_000) MB memory safety limit"
      case let .failed(code, detail):
        return detail.isEmpty ? "Transcription worker failed (\(code))" : detail
      case .emptyResult: return "No speech was detected"
      }
    }
  }

  func transcribe(
    spec: ModelSpec, samples: [Float], sampleRate: Int,
    language: String, provider: String,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    queue.async {
      let result: Result<String, Error>
      do {
        result = .success(try self.run(
          spec: spec, samples: samples, sampleRate: sampleRate,
          language: language, provider: provider
        ))
      } catch {
        result = .failure(error)
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  private func run(
    spec: ModelSpec, samples: [Float], sampleRate: Int,
    language: String, provider: String
  ) throws -> String {
    if Settings.shared.keepLatestDiagnosticAudio {
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
        "-l", "auto", "-np", "-nt", "-t", "4", "-sns",
      ]
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

    let deadline = Date().addingTimeInterval(TranscriptionLimits.workerTimeoutSeconds)
    let memoryLimit = TranscriptionLimits.workerMemoryLimit(for: spec)
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

    try? stdoutHandle.synchronize()
    try? stderrHandle.synchronize()
    let output = (try? Data(contentsOf: stdoutURL)) ?? Data()
    let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
    let detail = String(data: errorData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard process.terminationStatus == 0 else {
      throw WorkerError.failed(process.terminationStatus, String(detail.suffix(600)))
    }
    let text = String(data: output, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { throw WorkerError.emptyResult }
    return text
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
      _ = try FileManager.default.replaceItemAt(
        latestURL, withItemAt: temporary, backupItemName: nil,
        options: [.usingNewMetadataOnly]
      )
      dlog("saved latest diagnostic audio: \(samples.count) samples @\(sampleRate)Hz")
    } catch {
      // replaceItem requires an existing destination on some macOS versions.
      do {
        try? FileManager.default.removeItem(at: latestURL)
        let temporary = latestURL.deletingLastPathComponent()
          .appendingPathComponent("latest-dictation.pending.wav")
        try FileManager.default.moveItem(at: temporary, to: latestURL)
        dlog("saved latest diagnostic audio: \(samples.count) samples @\(sampleRate)Hz")
      } catch {
        dlog("could not save diagnostic audio: \(error.localizedDescription)")
      }
    }
  }
}
