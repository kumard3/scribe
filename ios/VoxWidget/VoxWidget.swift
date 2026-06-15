import WidgetKit
import SwiftUI

struct VoxEntry: TimelineEntry {
  let date: Date
}

struct VoxProvider: TimelineProvider {
  func placeholder(in context: Context) -> VoxEntry { VoxEntry(date: Date()) }
  func getSnapshot(in context: Context, completion: @escaping (VoxEntry) -> Void) {
    completion(VoxEntry(date: Date()))
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<VoxEntry>) -> Void) {
    completion(Timeline(entries: [VoxEntry(date: Date())], policy: .never))
  }
}

private let voxBg = Color(red: 0x0E / 255, green: 0x0F / 255, blue: 0x13 / 255)
private let voxTeal = Color(red: 0x14 / 255, green: 0xB8 / 255, blue: 0xA6 / 255)

struct WidgetBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 17.0, *) {
      content.containerBackground(voxBg, for: .widget)
    } else {
      content.background(voxBg)
    }
  }
}

struct VoxWidgetEntryView: View {
  var entry: VoxProvider.Entry
  var body: some View {
    VStack(spacing: 6) {
      Text("🎤").font(.system(size: 30))
      Text("Vox · Dictate")
        .font(.system(size: 13, weight: .bold))
        .foregroundColor(voxTeal)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .widgetURL(URL(string: "vox://dictate-session"))
    .modifier(WidgetBackground())
  }
}

@main
struct VoxWidget: Widget {
  let kind = "VoxWidget"
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: VoxProvider()) { entry in
      VoxWidgetEntryView(entry: entry)
    }
    .configurationDisplayName("Vox Dictate")
    .description("Tap to start on-device dictation.")
    .supportedFamilies([.systemSmall])
  }
}
