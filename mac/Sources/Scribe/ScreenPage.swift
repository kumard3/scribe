import AVFoundation
import AVKit
import SwiftUI

extension DashboardView {
  @ViewBuilder
  var screenPage: some View {
    if let open = screen.openRecording {
      ScreenRecordingDetail(url: open).id(open)
    } else {
      pageTitle("Screen", "Record your screen with your voice and the Mac's sound. Everything stays on this Mac.")
      screenRecordCard
      screenListCard
    }
  }

  private var screenRecordCard: some View {
    heroCard(active: screen.isRecording) {
      recordButton(screen.isRecording, help: screen.isRecording ? "Stop recording" : "Start recording") {
        screen.isRecording ? screen.stop() : RecorderPanel.shared.show(.screen)
      }
      .disabled(meeting.isRecording)
      VStack(alignment: .leading, spacing: 8) {
        if screen.isRecording {
          Text(screen.elapsedLabel)
            .font(.system(size: 26, weight: .light)).monospacedDigit().foregroundColor(Mono.text)
          Text(screen.target.isEmpty ? "Starting…" : screen.target)
            .font(.system(size: 12)).foregroundColor(Mono.textDim).lineLimit(1)
          Button("Change what's shared…") { RecorderPanel.shared.show() }
            .font(.system(size: 12))
        } else {
          Text("Record screen").font(.system(size: 17, weight: .semibold)).foregroundColor(Mono.text)
          Text(meeting.isRecording
               ? "A meeting is recording. Share a screen from its Recorder to capture it with the call."
               : "Your mic and everything this Mac plays are recorded with the video. Press record to choose what to share.")
            .font(.system(size: 12)).foregroundColor(Mono.textDim)
        }
      }
      Spacer(minLength: 0)
    }
  }

  private var screenListCard: some View {
    section("Screen recordings") {
      if screen.recordings.isEmpty {
        Text("Your recordings show up here. The files live in Movies > Bolkit.")
          .font(.system(size: 13)).foregroundColor(Mono.textDim)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], alignment: .leading, spacing: 16) {
        ForEach(screen.recordings) { item in
          Button { screen.openRecording = item.id } label: {
            VStack(alignment: .leading, spacing: 6) {
              VideoThumb(url: item.id).frame(height: 112)
              Text(item.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                .font(.system(size: 12, weight: .semibold)).foregroundColor(Mono.text)
              Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))
                .font(.system(size: 11)).foregroundColor(Mono.textFaint)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.id]) }
            Button("Move to Trash") {
              try? FileManager.default.trashItem(at: item.id, resultingItemURL: nil)
              screen.refreshRecordings()
            }
          }
        }
      }
      Button("Open recordings folder") {
        try? FileManager.default.createDirectory(at: ScreenRecorder.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ScreenRecorder.folder)
      }
      .font(.system(size: 12))
    }
    .onAppear { screen.refreshRecordings() }
  }
}

struct ScreenRecordingDetail: View {
  let url: URL
  @ObservedObject var screen = ScreenRecorder.shared
  @State private var player: AVPlayer?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Button { close() } label: {
        Label("All recordings", systemImage: "chevron.left").font(.system(size: 12))
      }
      .buttonStyle(.plain)
      .foregroundColor(Mono.textDim)

      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(((try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date())
            .formatted(date: .complete, time: .shortened))
            .font(.system(size: 22, weight: .bold)).foregroundColor(Mono.text)
          Text(url.lastPathComponent).font(.system(size: 12)).foregroundColor(Mono.textDim)
        }
        Spacer()
        HStack(spacing: 8) {
          Button("Open") { NSWorkspace.shared.open(url) }
            .help("Open in your default video player")
          Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
            .help("Show in Finder")
          Button {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            close()
          } label: { Image(systemName: "trash") }
            .help("Move to Trash")
        }
        .font(.system(size: 12))
      }

      if let player {
        VideoPlayer(player: player)
          .frame(height: 420)
          .clipShape(RoundedRectangle(cornerRadius: 12))
      }
    }
    .onAppear { player = AVPlayer(url: url) }
    .onDisappear { player?.pause() }
  }

  private func close() {
    player?.pause()
    screen.openRecording = nil
    screen.refreshRecordings()
  }
}

struct VideoThumb: View {
  let url: URL
  var showsDuration = true
  @State private var image: CGImage?
  @State private var duration = ""

  var body: some View {
    Rectangle()
      .fill(Mono.surfaceAlt)
      .overlay {
        if let image {
          Image(decorative: image, scale: 1).resizable().scaledToFill()
        } else {
          Image(systemName: "play.rectangle").foregroundColor(Mono.textFaint)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if showsDuration, !duration.isEmpty {
          Text(duration)
            .font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundColor(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.7)))
            .padding(6)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .task(id: url) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        image = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        if let d = try? await asset.load(.duration), d.seconds.isFinite {
          duration = Duration.seconds(Int(d.seconds)).formatted(.time(pattern: .minuteSecond))
        }
      }
  }
}
