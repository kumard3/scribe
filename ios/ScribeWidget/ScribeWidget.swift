import ActivityKit
import SwiftUI
import WidgetKit

struct ScribeEntry: TimelineEntry {
  let date: Date
}

struct ScribeProvider: TimelineProvider {
  func placeholder(in context: Context) -> ScribeEntry { ScribeEntry(date: Date()) }
  func getSnapshot(in context: Context, completion: @escaping (ScribeEntry) -> Void) {
    completion(ScribeEntry(date: Date()))
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<ScribeEntry>) -> Void) {
    completion(Timeline(entries: [ScribeEntry(date: Date())], policy: .never))
  }
}

private let scribeBg = Color(red: 0x0E / 255, green: 0x0F / 255, blue: 0x13 / 255)
private let scribeTeal = Color(red: 0x14 / 255, green: 0xB8 / 255, blue: 0xA6 / 255)

struct WidgetBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 17.0, *) {
      content.containerBackground(scribeBg, for: .widget)
    } else {
      content.background(scribeBg)
    }
  }
}

struct ScribeWidgetEntryView: View {
  var entry: ScribeProvider.Entry
  var body: some View {
    VStack(spacing: 6) {
      Text("🎤").font(.system(size: 30))
      Text("Bolkit · Dictate")
        .font(.system(size: 13, weight: .bold))
        .foregroundColor(scribeTeal)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .widgetURL(URL(string: "scribe://dictate-session"))
    .modifier(WidgetBackground())
  }
}

struct ScribeWidget: Widget {
  let kind = "ScribeWidget"
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: ScribeProvider()) { entry in
      ScribeWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("Bolkit Dictate")
    .description("Tap to start on-device dictation.")
    .supportedFamilies([.systemSmall])
  }
}

@main
struct ScribeWidgets: WidgetBundle {
  var body: some Widget {
    ScribeWidget()
    DictationLiveActivity()
  }
}

private let monoDim = Color(red: 0x9A / 255, green: 0x9A / 255, blue: 0xA3 / 255)
private let monoRed = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)

private func label(_ phase: FlowPhase) -> String {
  switch phase {
  case .listening: return "Listening"
  case .transcribing: return "Transcribing"
  default: return "Bolkit ready"
  }
}

private struct PhaseIcon: View {
  let phase: FlowPhase
  var body: some View {
    Image(systemName: phase == .listening ? "waveform" : "mic.fill")
      .foregroundColor(phase == .listening ? monoRed : .white)
  }
}

private struct Elapsed: View {
  let state: DictationActivityAttributes.ContentState
  var body: some View {
    if state.phase == .listening {
      Text(state.since, style: .timer).monospacedDigit().foregroundColor(.white)
    } else {
      Text(label(state.phase)).foregroundColor(monoDim)
    }
  }
}

private struct StopButton: View {
  let phase: FlowPhase
  var body: some View {
    if #available(iOS 17.0, *) {
      Button(intent: FlowStopIntent()) {
        Image(systemName: phase == .listening ? "stop.fill" : "xmark")
          .font(.system(size: 16, weight: .bold))
          .foregroundColor(.black)
          .frame(width: 40, height: 40)
          .background(Circle().fill(Color.white))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(phase == .listening ? "Stop dictation" : "End Flow session")
    }
  }
}

struct DictationLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DictationActivityAttributes.self) { context in
      HStack(spacing: 12) {
        PhaseIcon(phase: context.state.phase).font(.system(size: 22, weight: .semibold))
        VStack(alignment: .leading, spacing: 2) {
          Text(label(context.state.phase)).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
          Elapsed(state: context.state).font(.system(size: 13))
        }
        Spacer()
        StopButton(phase: context.state.phase)
      }
      .padding(16)
      .activityBackgroundTint(.black)
      .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          PhaseIcon(phase: context.state.phase).font(.system(size: 22, weight: .semibold)).padding(.leading, 6)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(spacing: 2) {
            Text(label(context.state.phase)).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
            Elapsed(state: context.state).font(.system(size: 13))
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          StopButton(phase: context.state.phase).padding(.trailing, 6)
        }
      } compactLeading: {
        PhaseIcon(phase: context.state.phase)
      } compactTrailing: {
        if context.state.phase == .listening {
          Text(context.state.since, style: .timer).monospacedDigit().foregroundColor(.white).frame(maxWidth: 44)
        }
      } minimal: {
        PhaseIcon(phase: context.state.phase)
      }
      .keylineTint(.white)
    }
  }
}
