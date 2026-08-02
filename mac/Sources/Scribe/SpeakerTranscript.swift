import SwiftUI
import AppKit

final class SpeakerTranscript: ObservableObject {
  @Published var turns: [SpeakerTurn]
  @Published var names: [Int: String] = [:]

  init(turns: [SpeakerTurn]) { self.turns = turns }

  var speakers: [Int] { Array(Set(turns.map(\.speaker))).sorted() }

  func name(_ s: Int) -> String {
    let n = names[s]?.trimmingCharacters(in: .whitespaces)
    return (n?.isEmpty == false) ? n! : Diarizer.speakerLabel(s)
  }

  func rename(_ s: Int, to newName: String) { names[s] = newName }

  func merge(_ from: Int, into target: Int) {
    guard from != target else { return }
    turns = coalesce(turns.map {
      $0.speaker == from ? SpeakerTurn(speaker: target, text: $0.text) : $0
    })
    names[from] = nil
  }

  private func coalesce(_ ts: [SpeakerTurn]) -> [SpeakerTurn] {
    var out: [SpeakerTurn] = []
    for t in ts {
      if var last = out.last, last.speaker == t.speaker {
        last.text += " " + t.text
        out[out.count - 1] = last
      } else {
        out.append(t)
      }
    }
    return out
  }

  func plainText() -> String {
    if speakers.count <= 1 { return turns.map(\.text).joined(separator: " ") }
    return turns.map { "\(name($0.speaker)): \($0.text)" }.joined(separator: "\n\n")
  }
}

private let speakerColors: [Color] = [
  .primary, Color(red: 0.5, green: 0.7, blue: 1.0), Color(red: 0.56, green: 0.89, blue: 0.65),
  Color(red: 1.0, green: 0.76, blue: 0.42), Color(red: 1.0, green: 0.62, blue: 0.7),
  Color(red: 0.79, green: 0.64, blue: 1.0),
]

struct SpeakerTranscriptView: View {
  @ObservedObject var model: SpeakerTranscript
  @State private var editing: [Int: String] = [:]

  private func color(_ s: Int) -> Color { speakerColors[s % speakerColors.count] }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(Array(model.turns.enumerated()), id: \.offset) { _, turn in
            VStack(alignment: .leading, spacing: 3) {
              Text(model.name(turn.speaker))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color(turn.speaker))
              Text(turn.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
      }
      Divider()
      HStack {
        Text("\(model.speakers.count) speaker\(model.speakers.count == 1 ? "" : "s")")
          .font(.system(size: 12))
          .foregroundColor(.secondary)
        Spacer()
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(model.plainText(), forType: .string)
        }
      }
      .padding(12)
    }
    .frame(minWidth: 520, minHeight: 460)
  }

  private var header: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(model.speakers, id: \.self) { s in
          HStack(spacing: 6) {
            Circle().fill(color(s)).frame(width: 8, height: 8)
            TextField("", text: nameBinding(s))
              .textFieldStyle(.plain)
              .font(.system(size: 12, weight: .medium))
              .frame(width: 84)
            if model.speakers.count > 1 {
              Menu {
                ForEach(model.speakers.filter { $0 != s }, id: \.self) { other in
                  Button("Merge into \(model.name(other))") { model.merge(s, into: other) }
                }
              } label: {
                Image(systemName: "arrow.triangle.merge")
              }
              .menuStyle(.borderlessButton)
              .frame(width: 22)
            }
          }
          .padding(.vertical, 5)
          .padding(.horizontal, 9)
          .background(Color.primary.opacity(0.06))
          .clipShape(Capsule())
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
  }

  private func nameBinding(_ s: Int) -> Binding<String> {
    Binding(
      get: { editing[s] ?? model.name(s) },
      set: { editing[s] = $0; model.rename(s, to: $0) }
    )
  }
}
