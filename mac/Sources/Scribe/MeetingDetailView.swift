import AVFoundation
import SwiftUI

/// What a processed meeting folder holds, saved as meeting.json next to the audio.
struct MeetingDetail: Codable {
  struct Turn: Codable {
    let speaker: Int
    var text: String
  }

  var names: [String: String]
  var turns: [Turn]
  var summary: String?

  func name(_ speaker: Int) -> String { names[String(speaker)] ?? Diarizer.speakerLabel(speaker) }

  var speakers: [Int] { Array(Set(turns.map(\.speaker))).sorted() }

  var transcriptText: String {
    turns.map { "\(name($0.speaker)): \($0.text)" }.joined(separator: "\n\n")
  }

  /// Same layout the pipeline has always written, so older tools keep reading it.
  var fileText: String {
    (summary.map { "SUMMARY\n\($0)\n\nTRANSCRIPT\n" } ?? "") + transcriptText
  }

  static func load(_ dir: URL) -> MeetingDetail? {
    let json = dir.appendingPathComponent("meeting.json")
    if let data = try? Data(contentsOf: json), let detail = try? JSONDecoder().decode(MeetingDetail.self, from: data) {
      return detail
    }
    guard var text = try? String(contentsOf: dir.appendingPathComponent("transcript.txt"), encoding: .utf8),
          !text.isEmpty else { return nil }
    var summary = try? String(contentsOf: dir.appendingPathComponent("summary.txt"), encoding: .utf8)
    if text.hasPrefix("SUMMARY\n"), let r = text.range(of: "\n\nTRANSCRIPT\n") {
      summary = summary ?? String(text[text.index(text.startIndex, offsetBy: 8)..<r.lowerBound])
      text = String(text[r.upperBound...])
    }
    var ids: [String: Int] = ["You": 0]
    var names = ["0": "You"]
    let turns = text.components(separatedBy: "\n\n").compactMap { block -> Turn? in
      guard let colon = block.firstIndex(of: ":") else { return nil }
      let label = String(block[..<colon])
      let body = block[block.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
      let id = ids[label] ?? (ids.values.max() ?? 0) + 1
      ids[label] = id
      names[String(id)] = label
      return Turn(speaker: id, text: body)
    }
    return MeetingDetail(names: names, turns: turns, summary: summary)
  }

  init(names: [String: String], turns: [Turn], summary: String?) {
    self.names = names
    self.turns = turns
    self.summary = summary
  }

  init(_ out: MeetingPipeline.Output) {
    names = Dictionary(uniqueKeysWithValues: out.names.map { (String($0.key), $0.value) })
    turns = out.turns.map { Turn(speaker: $0.speaker, text: $0.text) }
    summary = out.summary
  }

  func save(to dir: URL) {
    if let data = try? JSONEncoder().encode(self) {
      try? data.write(to: dir.appendingPathComponent("meeting.json"))
    }
    try? fileText.write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
    if let summary {
      try? summary.write(to: dir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
    }
  }
}

final class MeetingPlayer: ObservableObject {
  @Published private(set) var isPlaying = false
  @Published var time: TimeInterval = 0
  private(set) var duration: TimeInterval = 0
  private var player: AVAudioPlayer?
  private var timer: Timer?

  func load(_ url: URL) {
    player = try? AVAudioPlayer(contentsOf: url)
    duration = player?.duration ?? 0
  }

  func toggle() {
    guard let player else { return }
    if player.isPlaying {
      player.pause()
      timer?.invalidate()
    } else {
      player.play()
      timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
        guard let self, let p = self.player else { return }
        self.time = p.currentTime
        if !p.isPlaying { self.isPlaying = false; self.timer?.invalidate() }
      }
    }
    isPlaying = player.isPlaying
  }

  func seek(_ t: TimeInterval) {
    player?.currentTime = t
    time = t
  }

  func stop() {
    player?.stop()
    timer?.invalidate()
    isPlaying = false
  }
}

private let speakerTints: [Color] = [
  .white, Color(red: 0.55, green: 0.74, blue: 1.0), Color(red: 0.58, green: 0.88, blue: 0.66),
  Color(red: 1.0, green: 0.77, blue: 0.45), Color(red: 1.0, green: 0.63, blue: 0.72),
  Color(red: 0.8, green: 0.66, blue: 1.0),
]

struct MeetingDetailView: View {
  let dir: URL
  @ObservedObject var meeting = MeetingRecorder.shared
  @StateObject private var player = MeetingPlayer()
  @State private var detail: MeetingDetail?
  @State private var mode = Mode.summary
  @State private var search = ""
  @State private var editing: [Int: String] = [:]

  init(dir: URL, mode: Mode = .summary) {
    self.dir = dir
    _mode = State(initialValue: mode)
  }

  enum Mode: String, CaseIterable, Identifiable {
    case summary = "Summary", transcript = "Transcript", speakers = "Speakers"
    var id: String { rawValue }
  }

  private func tint(_ speaker: Int) -> Color { speakerTints[speaker % speakerTints.count] }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Button { player.stop(); meeting.openMeetingID = nil } label: {
        Label("All meetings", systemImage: "chevron.left").font(.system(size: 12))
      }
      .buttonStyle(.plain)
      .foregroundColor(Mono.textDim)

      header
      jobBanner
      playerBar

      Picker("", selection: $mode) {
        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 360)

      if let detail {
        switch mode {
        case .summary: summaryView(detail)
        case .transcript: transcriptView(detail)
        case .speakers: speakersView(detail)
        }
      } else if meeting.state(dir) == .idle {
        card {
          Text("This meeting hasn't been transcribed yet.").foregroundColor(Mono.textDim)
          Button("Transcribe") { meeting.enqueue(dir) }
        }
      }
    }
    .onAppear {
      detail = MeetingDetail.load(dir)
      player.load(dir.appendingPathComponent("meeting.m4a"))
    }
    .onChange(of: meeting.processing) { _ in detail = MeetingDetail.load(dir) }
    .onDisappear { player.stop() }
  }

  private var header: some View {
    let date = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    let speakers = detail?.speakers.count
    return HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Text(date.formatted(date: .complete, time: .shortened))
          .font(.system(size: 22, weight: .bold)).foregroundColor(Mono.text)
        Text(clock(player.duration) + (speakers.map { "  ·  \($0) speaker\($0 == 1 ? "" : "s")" } ?? ""))
          .font(.system(size: 12)).foregroundColor(Mono.textDim).monospacedDigit()
      }
      Spacer()
      HStack(spacing: 8) {
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(detail?.fileText ?? "", forType: .string)
        }
        .disabled(detail == nil)
        Button { NSWorkspace.shared.activateFileViewerSelecting([dir]) } label: { Image(systemName: "folder") }
          .help("Show in Finder")
        Button(detail == nil ? "Transcribe" : "Re-transcribe") { meeting.enqueue(dir) }
          .disabled(meeting.state(dir) == .queued || meeting.processing == dir)
      }
      .font(.system(size: 12))
    }
  }

  @ViewBuilder
  private var jobBanner: some View {
    switch meeting.state(dir) {
    case .idle:
      EmptyView()
    case .queued:
      banner { Image(systemName: "clock"); Text("Queued. It starts when the meeting before it finishes.") }
    case let .running(step):
      banner { ProgressView().controlSize(.small); Text("Transcribing in the background · \(step)") }
    case let .failed(error):
      banner {
        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Color(hex: 0xFF453A))
        Text(error)
        Spacer()
        Button("Try again") { meeting.enqueue(dir) }
      }
    }
  }

  private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: 10) { content() }
      .font(.system(size: 12)).foregroundColor(Mono.textDim)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 12).fill(Mono.surface))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Mono.border))
  }

  private var playerBar: some View {
    HStack(spacing: 12) {
      Button { player.toggle() } label: {
        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 13)).frame(width: 30, height: 30)
          .background(Circle().fill(Color.white)).foregroundColor(.black)
      }
      .buttonStyle(.plain)
      .disabled(player.duration == 0)
      Text(clock(player.time)).font(.system(size: 11)).monospacedDigit().foregroundColor(Mono.textDim)
      Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(player.duration, 1))
        .tint(.white)
      Text(clock(player.duration)).font(.system(size: 11)).monospacedDigit().foregroundColor(Mono.textDim)
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 12).fill(Mono.surface))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Mono.border))
  }

  @ViewBuilder
  private func summaryView(_ d: MeetingDetail) -> some View {
    card {
      if let summary = d.summary, !summary.isEmpty {
        Text(summary).font(.system(size: 13)).foregroundColor(Mono.text).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text("No summary for this meeting. Turn on a model under AI Cleanup (or Apple Intelligence), then press Re-transcribe.")
          .font(.system(size: 13)).foregroundColor(Mono.textDim)
      }
    }
  }

  private func transcriptView(_ d: MeetingDetail) -> some View {
    let query = search.trimmingCharacters(in: .whitespaces).lowercased()
    let turns = d.turns.enumerated().filter { query.isEmpty || $0.element.text.lowercased().contains(query) }
    return VStack(alignment: .leading, spacing: 12) {
      TextField("Search transcript", text: $search)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 320)
      card {
        if turns.isEmpty {
          Text(query.isEmpty ? "No speech was detected." : "Nothing matches “\(search)”.").foregroundColor(Mono.textDim)
        }
        ForEach(turns, id: \.offset) { _, turn in
          VStack(alignment: .leading, spacing: 3) {
            Text(d.name(turn.speaker)).font(.system(size: 12, weight: .semibold)).foregroundColor(tint(turn.speaker))
            Text(turn.text).font(.system(size: 13)).foregroundColor(Mono.text).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.vertical, 4)
        }
      }
    }
  }

  private func speakersView(_ d: MeetingDetail) -> some View {
    card {
      Text("Rename a speaker and the transcript and saved files update.")
        .font(.caption).foregroundColor(Mono.textDim)
      ForEach(d.speakers, id: \.self) { s in
        let words = d.turns.filter { $0.speaker == s }.reduce(0) { $0 + $1.text.split(separator: " ").count }
        HStack(spacing: 10) {
          Circle().fill(tint(s)).frame(width: 9, height: 9)
          TextField("Name", text: Binding(
            get: { editing[s] ?? d.name(s) },
            set: { editing[s] = $0 }
          ))
          .textFieldStyle(.roundedBorder)
          .frame(width: 200)
          .onSubmit { rename(s) }
          Text("\(words) words").font(.system(size: 11)).foregroundColor(Mono.textFaint).monospacedDigit()
          Spacer()
          if editing[s] != nil, editing[s] != d.name(s) {
            Button("Save") { rename(s) }.font(.system(size: 12))
          }
        }
      }
    }
  }

  private func rename(_ speaker: Int) {
    guard var d = detail, let name = editing[speaker]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
    d.names[String(speaker)] = name
    d.save(to: dir)
    detail = d
    editing[speaker] = nil
    meeting.refreshRecordings()
  }

  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) { content() }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 14).fill(Mono.surface))
      .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Mono.border))
  }

  private func clock(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
  }
}
