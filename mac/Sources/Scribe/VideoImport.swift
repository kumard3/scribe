import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// A Loom download or any screen recording becomes a meeting folder, so it gets the same transcript,
/// speakers, summary and agent.md with screenshots as a recorded call.
enum VideoImport {
  static func present() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.movie]
    panel.prompt = "Import"
    panel.message = "Choose a video (a Loom download, a screen recording…) to make agent-ready."
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    run(url: url)
  }

  static func importLink(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let link = URL(string: trimmed), ["http", "https"].contains(link.scheme?.lowercased() ?? "") else {
      DictationManager.shared.status = "Paste a Loom link or a link to a video file."
      return
    }
    DictationManager.shared.status = "Downloading the video…"
    Task {
      do {
        let file = try await download(link)
        await MainActor.run { run(url: file, moving: true) }
      } catch {
        dlog("video link import: \(error)")
        await MainActor.run { DictationManager.shared.status = (error as? LinkError)?.message ?? "Couldn't download that video." }
      }
    }
  }

  private struct LinkError: Error { let message: String }

  private static func download(_ link: URL) async throws -> URL {
    let id = loomID(link)
    var source = link
    if let id { source = try await loomVideoURL(id) }
    let (tmp, response) = try await URLSession.shared.download(from: source)
    let http = response as? HTTPURLResponse
    let type = http?.mimeType ?? ""
    guard http?.statusCode == 200, type.hasPrefix("video/") || type.hasPrefix("audio/") else {
      try? FileManager.default.removeItem(at: tmp)
      throw LinkError(message: "That link isn't a video. Loom links and direct video links work.")
    }
    let name = id.map { "Loom \($0).mp4" } ?? (response.suggestedFilename ?? "video.mp4")
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: file)
    try FileManager.default.moveItem(at: tmp, to: file)
    return file
  }

  private static func loomID(_ link: URL) -> String? {
    guard let host = link.host?.lowercased(), host == "loom.com" || host.hasSuffix(".loom.com") else { return nil }
    let parts = link.pathComponents.filter { $0 != "/" }
    guard parts.count >= 2, ["share", "embed"].contains(parts[0]) else { return nil }
    let tail = String(parts[1].suffix(32))
    return tail.count == 32 && tail.allSatisfy(\.isHexDigit) ? tail : parts[1]
  }

  /// Same endpoint Loom's own web player uses; it returns a signed cdn.loom.com MP4.
  private static func loomVideoURL(_ id: String) async throws -> URL {
    var request = URLRequest(url: URL(string: "https://www.loom.com/api/campaigns/sessions/\(id)/transcoded-url")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("https://www.loom.com", forHTTPHeaderField: "Origin")
    request.setValue("https://www.loom.com/share/\(id)", forHTTPHeaderField: "Referer")
    request.setValue("loom_web", forHTTPHeaderField: "X-Loom-Request-Source")
    let (data, response) = try await URLSession.shared.data(for: request)
    struct Body: Decodable { let url: URL }
    guard (response as? HTTPURLResponse)?.statusCode == 200, let body = try? JSONDecoder().decode(Body.self, from: data) else {
      throw LinkError(message: "Loom didn't give a downloadable video. Check the link is public, or download it from Loom and choose the file.")
    }
    return body.url
  }

  static func run(url: URL, moving: Bool = false) {
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd_HHmm-ss"
    let dir = MeetingRecorder.root.appendingPathComponent(stamp.string(from: Date()), isDirectory: true)
    DictationManager.shared.status = "Importing \(url.lastPathComponent)…"
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let screen = dir.appendingPathComponent("screen.\(url.pathExtension.lowercased())")
        try moving ? FileManager.default.moveItem(at: url, to: screen) : FileManager.default.copyItem(at: url, to: screen)
        try extractAudio(screen, into: dir)
        DispatchQueue.main.async { MeetingRecorder.shared.add(dir) }
      } catch {
        dlog("video import: \(error)")
        try? FileManager.default.removeItem(at: dir)
        DispatchQueue.main.async { DictationManager.shared.status = "Couldn't read the audio in \(url.lastPathComponent)." }
      }
    }
  }

  /// The writers finalize their CAF files when this returns, before the pipeline reads them.
  private static func extractAudio(_ url: URL, into dir: URL) throws {
    // Everything in the video is "Others"; you.caf stays empty so nothing is labelled You.
    _ = try TrackWriter(url: dir.appendingPathComponent("you.caf"))
    let others = try TrackWriter(url: dir.appendingPathComponent("others.caf"))
    let file = try AVAudioFile(forReading: url)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    while file.framePosition < file.length {
      try file.read(into: buffer)
      others.append(buffer)
    }
  }
}
