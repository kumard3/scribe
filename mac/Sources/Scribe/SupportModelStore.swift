import Foundation

/// Downloads the auxiliary on-device models that back file transcription:
/// punctuation restoration and speaker diarization. They live outside the ASR
/// catalog (they are not transcription engines) under Scribe/models/_punct and
/// _diar, pulled from the same k2-fsa releases the mobile app uses.
@MainActor
final class SupportModelStore: ObservableObject {
  static let shared = SupportModelStore()

  nonisolated static let punctKey = "punct"
  nonisolated static let diarKey = "diar"

  @Published var progress: [String: Double] = [:]
  @Published var errors: [String: String] = [:]
  @Published var installed: Set<String> = []

  private init() { refresh() }

  private static let punctBase =
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models"
  private static let punctArchive = "sherpa-onnx-online-punct-en-2024-08-06.tar.bz2"
  private static let segBase =
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models"
  private static let segArchive = "sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
  private static let embBase =
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models"
  nonisolated private static let embFileName = "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"

  nonisolated static let punctSizeLabel = "≈ 29 MB"
  nonisolated static let diarSizeLabel = "≈ 34 MB"

  nonisolated static var punctDir: URL {
    ModelStore.root.appendingPathComponent("_punct", isDirectory: true)
  }
  nonisolated static var diarDir: URL {
    ModelStore.root.appendingPathComponent("_diar", isDirectory: true)
  }
  nonisolated static var segDir: URL {
    diarDir.appendingPathComponent("segmentation", isDirectory: true)
  }
  nonisolated static var embFile: URL {
    diarDir.appendingPathComponent(embFileName)
  }

  nonisolated private static func find(_ dir: URL, name: String) -> String? {
    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
    else { return nil }
    for case let url as URL in e where url.lastPathComponent == name { return url.path }
    return nil
  }

  nonisolated static func punctModelPath() -> String? { find(punctDir, name: "model.onnx") }
  nonisolated static func punctVocabPath() -> String? { find(punctDir, name: "bpe.vocab") }
  nonisolated static func diarSegPath() -> String? { find(segDir, name: "model.onnx") }
  nonisolated static func diarEmbPath() -> String? {
    FileManager.default.fileExists(atPath: embFile.path) ? embFile.path : nil
  }

  nonisolated static var punctInstalled: Bool { punctModelPath() != nil && punctVocabPath() != nil }
  nonisolated static var diarInstalled: Bool { diarSegPath() != nil && diarEmbPath() != nil }

  func refresh() {
    var s: Set<String> = []
    if Self.punctInstalled { s.insert(Self.punctKey) }
    if Self.diarInstalled { s.insert(Self.diarKey) }
    installed = s
  }

  func delete(_ key: String) {
    let dir = key == Self.punctKey ? Self.punctDir : Self.diarDir
    try? FileManager.default.removeItem(at: dir)
    refresh()
  }

  func downloadPunctuation() {
    guard progress[Self.punctKey] == nil, !installed.contains(Self.punctKey) else { return }
    errors[Self.punctKey] = nil
    progress[Self.punctKey] = 0
    Task {
      do {
        try await Self.downloadAndExtract(
          url: URL(string: "\(Self.punctBase)/\(Self.punctArchive)")!,
          into: Self.punctDir
        ) { r in self.report(Self.punctKey, r) }
        guard Self.punctInstalled else { throw SupportError.missing }
        finish(Self.punctKey, nil)
      } catch {
        finish(Self.punctKey, error.localizedDescription)
      }
    }
  }

  func downloadDiarization() {
    guard progress[Self.diarKey] == nil, !installed.contains(Self.diarKey) else { return }
    errors[Self.diarKey] = nil
    progress[Self.diarKey] = 0
    Task {
      do {
        if Self.diarSegPath() == nil {
          try await Self.downloadAndExtract(
            url: URL(string: "\(Self.segBase)/\(Self.segArchive)")!,
            into: Self.segDir
          ) { r in self.report(Self.diarKey, r * 0.5) }
        }
        if Self.diarEmbPath() == nil {
          try await Self.downloadFile(
            url: URL(string: "\(Self.embBase)/\(Self.embFileName)")!,
            to: Self.embFile
          ) { r in self.report(Self.diarKey, 0.5 + r * 0.5) }
        }
        guard Self.diarInstalled else { throw SupportError.missing }
        finish(Self.diarKey, nil)
      } catch {
        finish(Self.diarKey, error.localizedDescription)
      }
    }
  }

  // Called from the downloader's background thread; hop to the main actor.
  nonisolated private func report(_ key: String, _ value: Double) {
    Task { @MainActor in self.progress[key] = value }
  }

  private func finish(_ key: String, _ error: String?) {
    progress[key] = nil
    errors[key] = error
    refresh()
    dlog(error == nil ? "support model installed \(key)" : "support model failed \(key): \(error!)")
  }

  enum SupportError: LocalizedError {
    case missing
    case extractionFailed
    var errorDescription: String? {
      switch self {
      case .missing: return "Model files missing after download."
      case .extractionFailed: return "Could not extract the model archive."
      }
    }
  }

  nonisolated private static func downloadAndExtract(
    url: URL, into dir: URL, onProgress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let tmp = try await FileDownloader(onProgress: onProgress).download(url)
    defer { try? fm.removeItem(at: tmp) }
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["xjf", tmp.path, "-C", dir.path]
    try tar.run()
    tar.waitUntilExit()
    guard tar.terminationStatus == 0 else { throw SupportError.extractionFailed }
  }

  nonisolated private static func downloadFile(
    url: URL, to dest: URL, onProgress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    let tmp = try await FileDownloader(onProgress: onProgress).download(url)
    try? fm.removeItem(at: dest)
    try fm.moveItem(at: tmp, to: dest)
  }
}

/// Minimal delegate-backed downloader that reports fractional progress and hands
/// back a temp file. URLSession deletes its own temp file when the delegate
/// returns, so the finish callback moves it out first.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let onProgress: @Sendable (Double) -> Void
  private var continuation: CheckedContinuation<URL, Error>?
  private lazy var session = URLSession(
    configuration: .default, delegate: self, delegateQueue: nil
  )

  init(onProgress: @escaping @Sendable (Double) -> Void) {
    self.onProgress = onProgress
  }

  func download(_ url: URL) async throws -> URL {
    try await withCheckedThrowingContinuation { c in
      continuation = c
      session.downloadTask(with: url).resume()
    }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData _: Int64, totalBytesWritten written: Int64,
    totalBytesExpectedToWrite expected: Int64
  ) {
    guard expected > 0 else { return }
    onProgress(Double(written) / Double(expected))
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let kept = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-support-\(UUID().uuidString)")
    do {
      try FileManager.default.moveItem(at: location, to: kept)
      continuation?.resume(returning: kept)
    } catch {
      continuation?.resume(throwing: error)
    }
    continuation = nil
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    guard let error, continuation != nil else { return }
    continuation?.resume(throwing: error)
    continuation = nil
  }
}
