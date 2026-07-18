import Foundation

/// Downloads model archives from k2-fsa releases into
/// ~/Library/Application Support/Scribe/models/<id>/ and extracts them.
@MainActor
final class ModelStore: NSObject, ObservableObject {
  static let shared = ModelStore()

  @Published var progress: [String: Double] = [:]
  @Published var errors: [String: String] = [:]
  @Published var installedIds: Set<String> = []

  private var tasks: [String: URLSessionDownloadTask] = [:]
  private lazy var session = URLSession(
    configuration: .default, delegate: self, delegateQueue: nil
  )

  override private init() {
    super.init()
    refreshInstalled()
  }

  nonisolated static var root: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Scribe/models", isDirectory: true)
  }

  nonisolated static func dir(for spec: ModelSpec) -> URL {
    root.appendingPathComponent(spec.id, isDirectory: true)
  }

  func refreshInstalled() {
    var ids: Set<String> = []
    for spec in ModelCatalog.all where spec.kind != .appleSystem {
      let marker = spec.kind == .llm
        ? Self.ggufFile(in: Self.dir(for: spec))
        : Self.tokensFile(in: Self.dir(for: spec))
      if marker != nil { ids.insert(spec.id) }
    }
    installedIds = ids
  }

  func isInstalled(_ spec: ModelSpec) -> Bool {
    spec.kind == .appleSystem || installedIds.contains(spec.id)
  }

  func isDownloading(_ spec: ModelSpec) -> Bool {
    tasks[spec.id] != nil
  }

  func download(_ spec: ModelSpec) {
    guard tasks[spec.id] == nil else { return }
    let urlString = spec.directURL ?? (spec.archive.isEmpty ? nil : "\(ModelCatalog.releases)/\(spec.archive)")
    guard let urlString, let url = URL(string: urlString) else { return }
    errors[spec.id] = nil
    progress[spec.id] = 0
    let task = session.downloadTask(with: url)
    task.taskDescription = spec.id
    tasks[spec.id] = task
    task.resume()
    dlog("model download start \(spec.id)")
  }

  func cancel(_ spec: ModelSpec) {
    tasks[spec.id]?.cancel()
    tasks[spec.id] = nil
    progress[spec.id] = nil
  }

  func delete(_ spec: ModelSpec) {
    if spec.kind == .llm { LLMRuntime.shared.release() }
    try? FileManager.default.removeItem(at: Self.dir(for: spec))
    refreshInstalled()
    if Settings.shared.activeModelId == spec.id {
      Settings.shared.activeModelId = ModelCatalog.systemId
    }
  }

  /// Every archive ships a tokens file next to its .onnx files — usually
  /// tokens.txt, but Whisper archives prefix it (e.g. tiny-tokens.txt).
  nonisolated static func tokensFile(in dir: URL) -> URL? {
    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
    else { return nil }
    for case let url as URL in e where url.lastPathComponent.hasSuffix("tokens.txt") {
      return url
    }
    return nil
  }

  /// Directory containing the extracted model files (where tokens.txt lives).
  nonisolated static func modelDir(for spec: ModelSpec) -> URL? {
    tokensFile(in: dir(for: spec))?.deletingLastPathComponent()
  }

  /// The .gguf file for a single-file LLM model (install marker / load path).
  nonisolated static func ggufFile(in dir: URL) -> URL? {
    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
    else { return nil }
    for case let url as URL in e where url.pathExtension == "gguf" {
      return url
    }
    return nil
  }

  /// Picks a model file whose name contains `needle`, preferring (or
  /// avoiding) int8 quantized variants.
  nonisolated static func find(_ needle: String, in dir: URL, preferInt8: Bool = true) -> URL? {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    let onnx = files.filter {
      ["onnx", "ort"].contains($0.pathExtension) && $0.lastPathComponent.contains(needle)
    }
    let int8 = onnx.first { $0.lastPathComponent.contains("int8") }
    let plain = onnx.first { !$0.lastPathComponent.contains("int8") }
    return preferInt8 ? (int8 ?? plain) : (plain ?? int8)
  }

  /// Single-file install for the LLM GGUF: move it into the model dir verbatim
  /// (no archive extraction). Tolerant size check — HF/CDN length can drift.
  nonisolated private func installGGUF(spec: ModelSpec, tempFile: URL) {
    let fm = FileManager.default
    let dir = Self.dir(for: spec)
    var failure: String?
    do {
      let size = (try? fm.attributesOfItem(atPath: tempFile.path)[.size] as? Int64) ?? 0
      guard size > Int64(Double(spec.sizeBytes) * 0.99) else {
        throw NSError(domain: "Scribe", code: 1, userInfo: [
          NSLocalizedDescriptionKey:
            "Download incomplete (\(Int(Double(size) / 1e6)) of \(spec.sizeLabel)) — try again."
        ])
      }
      try? fm.removeItem(at: dir)
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      let name = spec.fileName.isEmpty ? "model.gguf" : spec.fileName
      try fm.moveItem(at: tempFile, to: dir.appendingPathComponent(name))
    } catch {
      try? fm.removeItem(at: dir)
      failure = error.localizedDescription
    }
    try? fm.removeItem(at: tempFile)
    DispatchQueue.main.async {
      self.progress[spec.id] = nil
      self.tasks[spec.id] = nil
      if let failure {
        self.errors[spec.id] = failure
        dlog("llm install failed \(spec.id): \(failure)")
      } else {
        self.refreshInstalled()
        dlog("llm installed \(spec.id)")
      }
    }
  }

  nonisolated private func extract(spec: ModelSpec, tempFile: URL) {
    let fm = FileManager.default
    let dir = Self.dir(for: spec)
    var failure: String?
    do {
      let size = (try? fm.attributesOfItem(atPath: tempFile.path)[.size] as? Int64) ?? 0
      guard size > Int64(Double(spec.sizeBytes) * 0.995) else {
        throw NSError(domain: "Scribe", code: 1, userInfo: [
          NSLocalizedDescriptionKey:
            "Download incomplete (\(Int(Double(size) / 1e6)) of \(spec.sizeLabel)) — try again."
        ])
      }
      try? fm.removeItem(at: dir)
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)

      let tar = Process()
      tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
      tar.arguments = ["xjf", tempFile.path, "-C", dir.path]
      try tar.run()
      tar.waitUntilExit()
      guard tar.terminationStatus == 0 else {
        throw NSError(domain: "Scribe", code: 2, userInfo: [
          NSLocalizedDescriptionKey: "Archive extraction failed — try again."
        ])
      }
      guard Self.tokensFile(in: dir) != nil else {
        throw NSError(domain: "Scribe", code: 3, userInfo: [
          NSLocalizedDescriptionKey: "Model files missing after extraction."
        ])
      }
    } catch {
      try? fm.removeItem(at: dir)
      failure = error.localizedDescription
    }
    try? fm.removeItem(at: tempFile)
    DispatchQueue.main.async {
      self.progress[spec.id] = nil
      self.tasks[spec.id] = nil
      if let failure {
        self.errors[spec.id] = failure
        dlog("model install failed \(spec.id): \(failure)")
      } else {
        self.refreshInstalled()
        dlog("model installed \(spec.id)")
      }
    }
  }
}

extension ModelStore: URLSessionDownloadDelegate {
  nonisolated func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData _: Int64, totalBytesWritten written: Int64,
    totalBytesExpectedToWrite expected: Int64
  ) {
    guard let id = downloadTask.taskDescription,
          let spec = ModelCatalog.spec(id) else { return }
    let total = expected > 0 ? expected : spec.sizeBytes
    let ratio = total > 0 ? Double(written) / Double(total) : 0
    DispatchQueue.main.async { self.progress[id] = min(0.97, ratio * 0.97) }
  }

  nonisolated func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let id = downloadTask.taskDescription,
          let spec = ModelCatalog.spec(id) else { return }
    // The temp file dies when this delegate returns — move it out first.
    let ext = spec.kind == .llm ? "gguf" : "tar.bz2"
    let kept = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-\(id).\(ext)")
    try? FileManager.default.removeItem(at: kept)
    try? FileManager.default.moveItem(at: location, to: kept)
    DispatchQueue.main.async { self.progress[id] = 0.98 }
    DispatchQueue.global(qos: .userInitiated).async {
      if spec.kind == .llm {
        self.installGGUF(spec: spec, tempFile: kept)
      } else {
        self.extract(spec: spec, tempFile: kept)
      }
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    guard let error, (error as NSError).code != NSURLErrorCancelled,
          let id = task.taskDescription else { return }
    DispatchQueue.main.async {
      self.tasks[id] = nil
      self.progress[id] = nil
      self.errors[id] = error.localizedDescription
      dlog("model download failed \(id): \(error.localizedDescription)")
    }
  }
}
