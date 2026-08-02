import WidgetKit
import SwiftUI

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
      Text("Scribe · Dictate")
        .font(.system(size: 13, weight: .bold))
        .foregroundColor(scribeTeal)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .widgetURL(URL(string: "scribe://dictate-session"))
    .modifier(WidgetBackground())
  }
}

@main
struct ScribeWidget: Widget {
  let kind = "ScribeWidget"
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: ScribeProvider()) { entry in
      ScribeWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("Scribe Dictate")
    .description("Tap to start on-device dictation.")
    .supportedFamilies([.systemSmall])
  }
}
