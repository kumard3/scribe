import AppKit
import AVFoundation

/// agent.md next to a meeting: summary, timestamped transcript, and screenshots from the screen
/// clips at the moments the screen changed, so an agent that can't watch video can follow the call.
enum AgentExport {
  static func file(in dir: URL) -> URL { dir.appendingPathComponent("agent.md") }

  /// Frames are extracted once; the markdown is rewritten every time so renamed speakers show up.
  static func write(dir: URL) async {
    guard let detail = MeetingDetail.load(dir) else { return }
    let framesDir = dir.appendingPathComponent("frames", isDirectory: true)
    let started = created(dir) ?? Date()
    var frames = existingFrames(framesDir)
    if frames.isEmpty {
      for clip in MeetingRecorder.clips(in: dir) {
        let offset = max(0, (created(clip) ?? started).timeIntervalSince(started))
        frames += await keyFrames(clip, offset: offset, into: framesDir)
      }
    }
    try? markdown(detail, date: started, dir: dir, frames: frames)
      .write(to: file(in: dir), atomically: true, encoding: .utf8)
  }

  /// What "Copy for agent" puts on the clipboard: the meeting id for the bolkit MCP server, with the file as a fallback.
  static func prompt(dir: URL) -> String {
    let id = dir.lastPathComponent
    let frames = dir.appendingPathComponent("frames")
    let shots = existingFrames(frames).isEmpty ? "" : " Screenshots of the shared screen: \(frames.path)."
    return "Bolkit meeting \(id). With the bolkit MCP server: get_meeting id=\(id) returns the summary and the " +
      "first page of the transcript (from_ms/to_ms reads a part), and search_memory finds a topic. " +
      "Without MCP, read \(file(in: dir).path).\(shots)"
  }

  private static func markdown(_ d: MeetingDetail, date: Date, dir: URL, frames: [(Double, String)]) -> String {
    let duration = (d.duration ?? d.turns.compactMap(\.start).max()).map { "  ·  \(clock($0))" } ?? ""
    let fm = FileManager.default
    let files = (fm.fileExists(atPath: dir.appendingPathComponent("meeting.m4a").path) ? ["meeting.m4a is the audio"] : [])
      + (MeetingRecorder.clips(in: dir).isEmpty ? [] : ["\(MeetingRecorder.clips(in: dir).map(\.lastPathComponent).joined(separator: ", ")) are the screen clips"])
    var lines = [
      "# \(d.title ?? "Meeting"), \(date.formatted(date: .abbreviated, time: .shortened))\(duration)",
      "",
      "Speakers: " + d.speakers.map { d.agentName($0) }.joined(separator: ", "),
    ]
    if d.name(MeetingPipeline.you) == "You" { lines.append("You = \(Settings.shared.yourName)") }
    lines += ["Folder: \(dir.path)" + (files.isEmpty ? "" : " (\(files.joined(separator: "; ")))"), ""]
    if let summary = d.summary, !summary.isEmpty { lines += ["## Summary", "", summary, ""] }
    if let chapters = d.chapters {
      lines += ["## Chapters", ""] + chapters.map { "- \(clock($0.start))-\(clock($0.end)) \($0.title)" } + [""]
    }
    lines += ["## Transcript", ""]
    var pending = frames.sorted { $0.0 < $1.0 }[...]
    for turn in d.turns {
      if let start = turn.start {
        while let next = pending.first, next.0 <= start {
          lines += ["![Screen at \(clock(next.0))](\(next.1))", ""]
          pending = pending.dropFirst()
        }
        lines.append("[\(clock(start))] **\(d.agentName(turn.speaker))**: \(turn.text)")
      } else {
        lines.append("**\(d.agentName(turn.speaker))**: \(turn.text)")
      }
      lines.append("")
    }
    for frame in pending { lines += ["![Screen at \(clock(frame.0))](\(frame.1))", ""] }
    return lines.joined(separator: "\n")
  }

  // ponytail: one frame every 10 s, kept when the screen changed or a minute has passed since the
  // last kept one; scene detection on every frame would catch quick changes if agents miss them.
  private static func keyFrames(_ url: URL, offset: Double, into dir: URL) async -> [(Double, String)] {
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else { return [] }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1280, height: 1280)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var out: [(Double, String)] = []
    var last: [UInt8]?
    var lastAt = -Double.infinity
    var t = min(1, duration / 2)
    while t < duration {
      if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
        let print = fingerprint(image)
        if t - lastAt >= 60 || last.map({ difference($0, print) > 3 }) ?? true {
          let at = offset + t
          let name = "\(Int(at * 10)).jpg"
          let rep = NSBitmapImageRep(cgImage: image)
          if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]),
             (try? data.write(to: dir.appendingPathComponent(name))) != nil {
            out.append((at, "frames/\(name)"))
            last = print
            lastAt = t
          }
        }
      }
      t += 10
    }
    return out
  }

  private static func existingFrames(_ dir: URL) -> [(Double, String)] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { name in
      guard name.hasSuffix(".jpg"), let tenths = Double(name.dropLast(4)) else { return nil }
      return (tenths / 10, "frames/\(name)")
    }
  }

  /// 32x18 grayscale thumbnail; mean absolute difference between two of them tells screen changes.
  private static func fingerprint(_ image: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: 32 * 18)
    pixels.withUnsafeMutableBytes { buffer in
      guard let ctx = CGContext(data: buffer.baseAddress, width: 32, height: 18, bitsPerComponent: 8,
                                bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 18))
    }
    return pixels
  }

  private static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
  }

  private static func created(_ url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
  }

  private static func clock(_ t: Double) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
  }
}
