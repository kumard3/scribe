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
      let dir = Self.dir(for: spec)
      let installed: Bool
      switch spec.kind {
      case .llm:
        installed = Self.ggufFile(in: dir) != nil
      case .qwenAsr:
        let fm = FileManager.default
        installed = fm.fileExists(atPath: dir.appendingPathComponent(spec.fileName).path)
          && fm.fileExists(atPath: dir.appendingPathComponent(spec.mmprojFileName).path)
      default:
        installed = Self.tokensFile(in: dir) != nil
      }
      if installed { ids.insert(spec.id) }
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
    if spec.kind == .qwenAsr { AsrRuntime.shared.release() }
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

  /// Single-file install for a GGUF: move it into the model dir verbatim (no
  /// archive extraction). Tolerant size check — HF/CDN length can drift.
  /// `wipe` clears the dir first (first file of a set); `isFinal` marks the
  /// spec installed when done. For qwenAsr the mmproj download is kicked off
  /// after the main model lands.
  nonisolated private func installGGUF(
    spec: ModelSpec, tempFile: URL, name: String, expectedBytes: Int64,
    wipe: Bool, isFinal: Bool
  ) {
    let fm = FileManager.default
    let dir = Self.dir(for: spec)
    var failure: String?
    do {
      let size = (try? fm.attributesOfItem(atPath: tempFile.path)[.size] as? Int64) ?? 0
      guard expectedBytes <= 0 || size > Int64(Double(expectedBytes) * 0.99) else {
        throw NSError(domain: "Scribe", code: 1, userInfo: [
          NSLocalizedDescriptionKey:
            "Download incomplete (\(Int(Double(size) / 1e6)) MB) — try again."
        ])
      }
      if wipe { try? fm.removeItem(at: dir) }
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      let dest = dir.appendingPathComponent(name.isEmpty ? "model.gguf" : name)
      try? fm.removeItem(at: dest)
      try fm.moveItem(at: tempFile, to: dest)
    } catch {
      try? fm.removeItem(at: dir)
      failure = error.localizedDescription
    }
    try? fm.removeItem(at: tempFile)
    DispatchQueue.main.async {
      if let failure {
        self.progress[spec.id] = nil
        self.tasks[spec.id] = nil
        self.errors[spec.id] = failure
        dlog("gguf install failed \(spec.id): \(failure)")
        return
      }
      if isFinal {
        self.progress[spec.id] = nil
        self.tasks[spec.id] = nil
        self.refreshInstalled()
        dlog("model installed \(spec.id)")
      } else if let mmprojURL = spec.mmprojURL, let url = URL(string: mmprojURL) {
        let task = self.session.downloadTask(with: url)
        task.taskDescription = "\(spec.id)#mmproj"
        self.tasks[spec.id] = task
        task.resume()
        dlog("mmproj download start \(spec.id)")
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
  // taskDescription is the spec id, with "#mmproj" appended for the second
  // file of a qwenAsr pair.
  nonisolated private static func parse(_ desc: String) -> (id: String, mmproj: Bool) {
    desc.hasSuffix("#mmproj")
      ? (String(desc.dropLast("#mmproj".count)), true)
      : (desc, false)
  }

  nonisolated func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData _: Int64, totalBytesWritten written: Int64,
    totalBytesExpectedToWrite expected: Int64
  ) {
    guard let desc = downloadTask.taskDescription else { return }
    let (id, mmproj) = Self.parse(desc)
    guard let spec = ModelCatalog.spec(id) else { return }
    let total = expected > 0 ? expected : spec.sizeBytes
    let ratio = total > 0 ? Double(written) / Double(total) : 0
    // qwenAsr downloads two files: main model fills 0→0.6, mmproj 0.6→0.97.
    let mapped = spec.kind == .qwenAsr
      ? (mmproj ? 0.6 + ratio * 0.37 : ratio * 0.6)
      : min(0.97, ratio * 0.97)
    DispatchQueue.main.async { self.progress[id] = mapped }
  }

  nonisolated func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let desc = downloadTask.taskDescription else { return }
    let (id, mmproj) = Self.parse(desc)
    guard let spec = ModelCatalog.spec(id) else { return }
    // The temp file dies when this delegate returns — move it out first.
    let singleFile = spec.kind == .llm || spec.kind == .qwenAsr
    let ext = singleFile ? "gguf" : "tar.bz2"
    let kept = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-\(id)\(mmproj ? "-mmproj" : "").\(ext)")
    try? FileManager.default.removeItem(at: kept)
    try? FileManager.default.moveItem(at: location, to: kept)
    DispatchQueue.global(qos: .userInitiated).async {
      switch spec.kind {
      case .llm:
        self.installGGUF(spec: spec, tempFile: kept, name: spec.fileName,
                         expectedBytes: spec.sizeBytes, wipe: true, isFinal: true)
      case .qwenAsr:
        if mmproj {
          self.installGGUF(spec: spec, tempFile: kept, name: spec.mmprojFileName,
                           expectedBytes: spec.mmprojSizeBytes, wipe: false, isFinal: true)
        } else {
          self.installGGUF(spec: spec, tempFile: kept, name: spec.fileName,
                           expectedBytes: spec.sizeBytes - spec.mmprojSizeBytes,
                           wipe: true, isFinal: false)
        }
      default:
        self.extract(spec: spec, tempFile: kept)
      }
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    guard let error, (error as NSError).code != NSURLErrorCancelled,
          let desc = task.taskDescription else { return }
    let id = Self.parse(desc).id
    DispatchQueue.main.async {
      self.tasks[id] = nil
      self.progress[id] = nil
      self.errors[id] = error.localizedDescription
      dlog("model download failed \(id): \(error.localizedDescription)")
    }
  }
}
