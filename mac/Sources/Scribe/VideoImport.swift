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

  static func run(url: URL) {
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd_HHmm-ss"
    let dir = MeetingRecorder.root.appendingPathComponent(stamp.string(from: Date()), isDirectory: true)
    DictationManager.shared.status = "Importing \(url.lastPathComponent)…"
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent("screen.\(url.pathExtension.lowercased())"))
        try extractAudio(url, into: dir)
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
