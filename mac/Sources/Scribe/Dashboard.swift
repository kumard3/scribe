import SwiftUI
import AppKit

// pureMono, same palette as the mobile app (src/ui/themes.ts)
enum Mono {
  static let bg = Color(hex: 0x000000)
  static let surface = Color(hex: 0x141416)
  static let surfaceAlt = Color(hex: 0x1C1C1F)
  static let border = Color(hex: 0x2A2A2E)
  static let text = Color.white
  static let textDim = Color(hex: 0x9A9AA3)
  static let textFaint = Color(hex: 0x5C5C66)
}

extension Color {
  init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }
}

/// The mobile app logo: three white waveform bars on a black rounded square.
struct LogoMark: View {
  var size: CGFloat = 44

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.24)
        .fill(Mono.surfaceAlt)
        .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(Mono.border))
      BolkitMark()
        .stroke(.white, style: StrokeStyle(lineWidth: size * 0.045, lineCap: .round, lineJoin: .round))
        .frame(width: size * 0.66, height: size * 0.34)
    }
    .frame(width: size, height: size)
  }
}

/// marketing/logo/bolkit-mark.svg: the wave plus the cursor bar.
struct BolkitMark: Shape {
  func path(in r: CGRect) -> Path {
    let sx = r.width / 701, sy = r.height / 363
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + (x - 160) * sx, y: r.minY + (y - 323) * sy) }
    var path = Path()
    path.move(to: p(180, 520))
    path.addCurve(to: p(292, 553), control1: p(236, 520), control2: p(236, 553))
    path.addCurve(to: p(392, 343), control1: p(342, 553), control2: p(342, 343))
    path.addCurve(to: p(490, 666), control1: p(441, 343), control2: p(441, 666))
    path.addCurve(to: p(605, 469), control1: p(547.5, 666), control2: p(547.5, 469))
    path.addCurve(to: p(724, 520), control1: p(664.5, 469), control2: p(664.5, 520))
    path.addLine(to: p(790, 520))
    path.move(to: p(841, 446))
    path.addLine(to: p(841, 576))
    return path
  }
}

struct DashboardView: View {
  @ObservedObject var dictation = DictationManager.shared
  @ObservedObject var settings = Settings.shared
  @ObservedObject var models = ModelStore.shared
  @ObservedObject var support = SupportModelStore.shared
  @ObservedObject var meeting = MeetingRecorder.shared
  @State private var launchAtLogin = LoginItem.enabled
  @State private var axTrusted = AXIsProcessTrusted()
  @State private var ollamaModels: [String] = []
  @State private var ollamaChecked = false

  enum Tab: String, CaseIterable, Identifiable {
    case home, dictation, meetings, models, cleanup, files, history, settings
    var id: String { rawValue }

    var title: String {
      switch self {
      case .home: return "Home"
      case .dictation: return "Dictation"
      case .meetings: return "Meetings"
      case .models: return "Models"
      case .cleanup: return "AI Cleanup"
      case .files: return "Files"
      case .history: return "History"
      case .settings: return "Settings"
      }
    }

    var icon: String {
      switch self {
      case .home: return "house"
      case .dictation: return "mic"
      case .meetings: return "record.circle"
      case .models: return "square.stack.3d.up"
      case .cleanup: return "sparkles"
      case .files: return "waveform"
      case .history: return "clock"
      case .settings: return "gearshape"
      }
    }
  }

  @AppStorage("dashboardTab") private var tabRaw = Tab.home.rawValue
  private var tab: Tab { Tab(rawValue: tabRaw) ?? .home }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Rectangle().fill(Mono.border).frame(width: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          content
        }
        .padding(28)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 820, minHeight: 620)
    .background(Mono.bg)
    .preferredColorScheme(.dark)
    .onAppear {
      launchAtLogin = LoginItem.enabled
      axTrusted = AXIsProcessTrusted()
      models.refreshInstalled()
      support.refresh()
      if settings.cleanupModelId == ModelCatalog.ollamaId { refreshOllama() }
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        LogoMark(size: 30)
        Text("Bolkit").font(.system(size: 17, weight: .bold)).foregroundColor(Mono.text)
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 18)

      ForEach(visibleTabs) { t in
        Button { tabRaw = t.rawValue } label: {
          HStack(spacing: 10) {
            Image(systemName: t.icon).frame(width: 18)
            Text(t.title)
            Spacer()
            if t == .meetings && meeting.isRecording {
              Circle().fill(Color.red).frame(width: 7, height: 7)
            }
          }
          .font(.system(size: 13, weight: tab == t ? .semibold : .regular))
          .foregroundColor(tab == t ? Mono.text : Mono.textDim)
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(RoundedRectangle(cornerRadius: 8).fill(tab == t ? Mono.surfaceAlt : .clear))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
      }
      Spacer()
      statusPill.padding(.horizontal, 6)
    }
    .padding(14)
    .frame(width: 200)
    .background(Mono.surface.opacity(0.4))
  }

  private var visibleTabs: [Tab] {
    Tab.allCases.filter { $0 != .meetings || MeetingRecorder.supported }
  }

  @ViewBuilder
  private var content: some View {
    switch tab {
    case .home:
      header
      quickActionsCard
      if !axTrusted { permissionCard }
      recentCard
    case .dictation:
      pageTitle("Dictation", "Hold a key, talk, and your words appear wherever you type.")
      hotkeysCard
      vocabularyCard
    case .meetings:
      if let open = meeting.openMeetingID {
        MeetingDetailView(dir: open).id(open)
      } else {
        pageTitle("Meetings", "Record any call. Get a transcript with who said what, plus a summary.")
        meetingCard
      }
    case .models:
      pageTitle("Models", "The speech model that turns your voice into text. All of them run on this Mac.")
      modelsCard
    case .cleanup:
      pageTitle("AI Cleanup", "Optional AI that tidies your text and writes meeting summaries. Runs on this Mac.")
      llmCard
    case .files:
      pageTitle("Files", "Turn a recording you already have into text.")
      audioFileCard
    case .history:
      pageTitle("History", "Everything you dictated. Stored only on this Mac.")
      historyCard
    case .settings:
      pageTitle("Settings", "Startup, clipboard, updates and permissions.")
      generalCard
      if !axTrusted { permissionCard }
    }
  }

  private func pageTitle(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.system(size: 24, weight: .bold)).foregroundColor(Mono.text)
      Text(subtitle).font(.system(size: 12.5)).foregroundColor(Mono.textDim)
    }
  }

  private var statusPill: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(dictation.isRecording || meeting.isRecording ? Color(hex: 0xFF453A) : .white)
        .frame(width: 8, height: 8)
      Text(meeting.isRecording ? "Meeting \(meeting.elapsedLabel)" : dictation.isRecording ? "Listening" : "Ready")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(Mono.textDim)
        .monospacedDigit()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Capsule().fill(Mono.surface))
    .overlay(Capsule().strokeBorder(Mono.border))
  }

  private var quickActionsCard: some View {
    section("Quick actions") {
      HStack(spacing: 10) {
        quickAction(dictation.isRecording ? "Stop dictation" : "Start dictation", "mic") { dictation.toggle() }
        if MeetingRecorder.supported {
          quickAction(meeting.isRecording ? "Stop meeting" : "Record meeting", "record.circle") { meeting.toggle() }
        }
        quickAction("Transcribe file", "waveform") { AudioImport.present() }
      }
      Text("Hold \(settings.holdKey == .off ? settings.toggleLabel : settings.holdKey.label) anywhere to dictate. Model: \(settings.activeModel.label).")
        .font(.caption).foregroundColor(Mono.textDim)
      if !dictation.status.isEmpty {
        Text(dictation.status).font(.caption).foregroundColor(Mono.textFaint).lineLimit(2)
      }
    }
  }

  private func quickAction(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 8) {
        Image(systemName: icon).font(.system(size: 18))
        Text(title).font(.system(size: 12, weight: .medium))
      }
      .foregroundColor(Mono.text)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
      .background(RoundedRectangle(cornerRadius: 10).fill(Mono.surfaceAlt))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Mono.border))
    }
    .buttonStyle(.plain)
  }

  private var recentCard: some View {
    section("Recent") {
      if dictation.history.isEmpty {
        Text("Nothing yet. Your last transcripts show up here.")
          .font(.system(size: 13)).foregroundColor(Mono.textDim)
      } else {
        ForEach(Array(dictation.history.prefix(4).enumerated()), id: \.offset) { _, text in
          Text(text).font(.system(size: 12.5)).foregroundColor(Mono.text).lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Button("See all history") { tabRaw = Tab.history.rawValue }.font(.caption)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      LogoMark(size: 48)
      VStack(alignment: .leading, spacing: 3) {
        Text("Bolkit")
          .font(.system(size: 26, weight: .bold))
          .foregroundColor(Mono.text)
        Text("Your on-device transcriber")
          .font(.system(size: 12.5))
          .foregroundColor(Mono.textDim)
      }
      Spacer()
      HStack(spacing: 7) {
        Circle()
          .fill(dictation.isRecording ? Color(hex: 0xFF453A) : .white)
          .frame(width: 8, height: 8)
        Text(dictation.isRecording ? "Listening" : "Ready")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(Mono.textDim)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(Capsule().fill(Mono.surface))
      .overlay(Capsule().strokeBorder(Mono.border))
    }
  }

  private var hotkeysCard: some View {
    section("Hotkeys") {
      Picker("Hold to talk", selection: $settings.holdKeyRaw) {
        ForEach(HoldKey.allCases) { k in Text(k.label).tag(k.rawValue) }
      }
      Text("Hold the key, speak, let go. The text is typed where your cursor is, in any app.")
        .font(.caption).foregroundColor(Mono.textDim)

      Toggle("Quick tap starts hands-free mode (tap again to stop)", isOn: $settings.tapHandsFree)

      Divider().overlay(Mono.border)

      HStack {
        Text("Toggle shortcut").foregroundColor(Mono.text)
        Spacer()
        ShortcutRecorder()
      }
      .font(.system(size: 13))
      Text("Or press this shortcut once to start and again to stop. Click it to change it.")
        .font(.caption).foregroundColor(Mono.textDim)

      if settings.holdKey == .fn {
        Text("Tip: set System Settings → Keyboard → “Press 🌐 key” to “Do Nothing” so fn doesn’t also trigger macOS actions.")
          .font(.caption).foregroundColor(Mono.textFaint)
      }
    }
  }

  private var modelsCard: some View {
    let asr = ModelCatalog.asrModels(showGemma: true)
    return section("Models") {
      Picker("Style", selection: $settings.dictationStyle) {
        ForEach(DictationStyle.allCases) { s in Text(s.label).tag(s.rawValue) }
      }
      .font(.system(size: 13))
      Text("Auto handles English mixed with Hindi. English: English only. Hinglish: Hindi written in English letters.")
        .font(.caption).foregroundColor(Mono.textFaint)

      Picker("Language", selection: $settings.language) {
        ForEach(speechLanguages) { l in Text(l.label).tag(l.code) }
      }
      .font(.system(size: 13))
      Text("Pick the language you speak. It is more accurate than Auto-detect.")
        .font(.caption).foregroundColor(Mono.textFaint)

      HStack {
        Text("Pause before text appears").foregroundColor(Mono.text)
        Spacer()
        Text("\(settings.chunkPauseMs) ms").foregroundColor(Mono.textDim)
      }
      .font(.system(size: 13))
      Slider(
        value: Binding(
          get: { Double(settings.chunkPauseMs) },
          set: { settings.chunkPauseMs = Int($0.rounded()) }
        ),
        in: 400...700, step: 50
      )
      Text("For live models. Shorter shows text sooner; longer keeps full sentences together.")
        .font(.caption).foregroundColor(Mono.textFaint)

      Toggle("Write Hindi in English letters (Hinglish)", isOn: $settings.romanizeHindi)
        .font(.system(size: 13))
      Toggle("Clean up mic audio", isOn: $settings.conditionAudio)
        .font(.system(size: 13))
      Text("Removes rumble and lifts quiet microphones.")
        .font(.caption).foregroundColor(Mono.textFaint)
      Toggle("Use the GPU and Neural Engine", isOn: $settings.useGpu)
        .font(.system(size: 13))
      Text("Faster on models that support it. Others keep using the CPU.")
        .font(.caption).foregroundColor(Mono.textFaint)
      Divider().overlay(Mono.border)

      ForEach(Array(asr.enumerated()), id: \.element.id) { i, spec in
        modelRow(spec)
        if i < asr.count - 1 {
          Divider().overlay(Mono.border)
        }
      }
    }
  }

  private var meetingCard: some View {
    section("Meetings") {
      HStack(spacing: 12) {
        if meeting.isRecording {
          Circle().fill(Color.red).frame(width: 9, height: 9)
          Text("Recording  \(meeting.elapsedLabel)")
            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
        } else {
          Image(systemName: "record.circle").foregroundColor(Mono.textDim)
          Text("Record a call or meeting").font(.system(size: 13, weight: .semibold))
        }
        Spacer()
        Button("Full screen") { MeetingScreen.shared.show() }
          .font(.system(size: 12))
        Button(meeting.isRecording ? "Stop" : "Record") { meeting.toggle() }
          .font(.system(size: 12, weight: .semibold))
      }
      if meeting.isRecording {
        HStack(spacing: 18) {
          levelMeter("You", meeting.youLevel)
          levelMeter("Others", meeting.othersLevel)
        }
      }
      Text("Your mic is saved as You and everything playing on this Mac (Zoom, Meet, Teams) as Others. Talking in person with nothing playing? Bolkit separates everyone on your mic into speakers instead. After you stop, it transcribes on this Mac, names anyone who says their name, and writes a summary. Your mic picking up the call is removed automatically.")
        .font(.caption).foregroundColor(Mono.textDim)

      Divider().overlay(Mono.border)
      if MeetingPipeline.appleSpeechAvailable {
        Toggle("Transcribe with Apple speech", isOn: $settings.meetingAppleSpeech)
          .font(.system(size: 13))
        Text(settings.meetingAppleSpeech
             ? "Most accurate for English calls. Turn off for Hindi or Hinglish meetings to use your dictation model."
             : "Using your dictation model (\(settings.activeModel.label)).")
          .font(.caption).foregroundColor(Mono.textFaint)
      }
      Picker("Other people on the call or in the room", selection: $settings.diarizeSpeakers) {
        Text("Auto").tag(0)
        ForEach(1...6, id: \.self) { n in Text("\(n)").tag(n) }
      }
      .font(.system(size: 13))
      Text("Auto finds up to 4 people by itself. Pick 5 or 6 for bigger calls.")
        .font(.caption).foregroundColor(Mono.textFaint)
      supportModelRow(
        "Speaker model for 5+ people", "pyannote + campplus. Up to 4 people uses Sortformer, downloaded on first use",
        key: SupportModelStore.diarKey, size: SupportModelStore.diarSizeLabel
      ) { support.downloadDiarization() }
      HStack {
        Text("Names and summary").foregroundColor(Mono.text)
        Spacer()
        Text(MeetingLLM.backendLabel == "none" ? "Turn on AI Cleanup to enable" : MeetingLLM.backendLabel)
          .foregroundColor(Mono.textDim)
      }
      .font(.system(size: 13))
      Divider().overlay(Mono.border)
      HStack(spacing: 10) {
        Button("System audio permission…") {
          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
        }
        Button("Open meetings folder") { meeting.revealRecordings() }
      }
      .font(.system(size: 12))

      if !meeting.recordings.isEmpty {
        Divider().overlay(Mono.border)
        ForEach(Array(meeting.recordings.prefix(8).enumerated()), id: \.element.id) { i, item in
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
              Text(item.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 13))
              meetingStateLine(item)
            }
            Spacer()
            Button(item.hasTranscript ? "Open" : meeting.state(item.id) == .idle ? "Transcribe" : "View") {
              if !item.hasTranscript, meeting.state(item.id) == .idle { meeting.enqueue(item.id) }
              meeting.openMeetingID = item.id
            }
            Button { meeting.reveal(item) } label: { Image(systemName: "folder") }
              .help("Show in Finder")
          }
          .font(.system(size: 12))
          if i < min(meeting.recordings.count, 8) - 1 {
            Divider().overlay(Mono.border)
          }
        }
      }
    }
    .onAppear { meeting.refreshRecordings() }
  }

  @ViewBuilder
  private func meetingStateLine(_ item: MeetingRecorder.MeetingItem) -> some View {
    let base = durationLabel(item.duration) + (item.hasTranscript ? "  ·  transcribed" : "")
    switch meeting.state(item.id) {
    case .idle:
      Text(base).font(.caption).foregroundColor(Mono.textFaint).monospacedDigit()
    case .queued:
      Text(base + "  ·  queued").font(.caption).foregroundColor(Mono.textDim).monospacedDigit()
    case let .running(step):
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text(step).font(.caption).foregroundColor(Mono.textDim).monospacedDigit()
      }
    case let .failed(error):
      Text(error).font(.caption).foregroundColor(Color(hex: 0xFF453A)).lineLimit(2)
    }
  }

  private func levelMeter(_ label: String, _ level: Float) -> some View {
    HStack(spacing: 8) {
      Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(Mono.textDim).frame(width: 44, alignment: .leading)
      GeometryReader { g in
        ZStack(alignment: .leading) {
          Capsule().fill(Mono.surfaceAlt)
          Capsule().fill(Color.white).frame(width: g.size.width * CGFloat(min(max(level, 0), 1)))
        }
      }
      .frame(height: 6)
      .animation(.easeOut(duration: 0.1), value: level)
    }
    .frame(maxWidth: .infinity)
  }

  private func durationLabel(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
  }

  private var audioFileCard: some View {
    section("Audio file") {
      Text("Pick an mp3, m4a, wav or aac file. It is transcribed with the model chosen in Models, on this Mac.")
        .font(.caption).foregroundColor(Mono.textDim)
      Button("Transcribe an audio file…") { AudioImport.present() }
        .font(.system(size: 12))

      Divider().overlay(Mono.border)

      Toggle("Separate speakers", isOn: $settings.diarizeImports)
        .font(.system(size: 13))
      if settings.diarizeImports {
        Picker("Speakers", selection: $settings.diarizeSpeakers) {
          Text("Auto").tag(0)
          ForEach(2...6, id: \.self) { n in Text("\(n)").tag(n) }
        }
        .font(.system(size: 13))
        Text("If you know how many people spoke, pick the number. It is much more accurate than Auto.")
          .font(.caption).foregroundColor(Mono.textFaint)
        supportModelRow(
          "Speaker model", "pyannote + campplus, needed to separate speakers",
          key: SupportModelStore.diarKey, size: SupportModelStore.diarSizeLabel
        ) { support.downloadDiarization() }
      }

      supportModelRow(
        "Punctuation model",
        "Adds punctuation to engines that don't (Zipformer, Parakeet CTC, Dolphin)",
        key: SupportModelStore.punctKey, size: SupportModelStore.punctSizeLabel
      ) { support.downloadPunctuation() }
    }
  }

  @ViewBuilder
  private func supportModelRow(
    _ title: String, _ note: String, key: String, size: String,
    download: @escaping () -> Void
  ) -> some View {
    let installed = support.installed.contains(key)
    let downloading = support.progress[key] != nil
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        Image(systemName: installed ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 14))
          .foregroundColor(installed ? .white : Mono.textFaint)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 13)).foregroundColor(Mono.text)
          Text(note).font(.system(size: 11)).foregroundColor(Mono.textDim)
        }
        Spacer()
        if downloading {
          ProgressView(value: support.progress[key] ?? 0)
            .progressViewStyle(.linear).frame(width: 90)
        } else if installed {
          Button { support.delete(key) } label: { Image(systemName: "trash") }
            .buttonStyle(.plain).foregroundColor(Mono.textFaint).help("Delete model files")
        } else {
          Button("Get · \(size)") { download() }.font(.system(size: 12))
        }
      }
      if let err = support.errors[key] {
        Text(err).font(.system(size: 11))
          .foregroundColor(Color(hex: 0xFF453A)).padding(.leading, 24)
      }
    }
  }

  private var llmCard: some View {
    section("Text AI") {
      Text("Choose the AI that rewrites your text. Nothing is sent to the internet.")
        .font(.caption).foregroundColor(Mono.textDim)

      appleIntelligenceRow
      Divider().overlay(Mono.border)

      ForEach(ModelCatalog.cleanupModels) { spec in
        cleanupRow(spec)
      }

      Divider().overlay(Mono.border)
      ollamaRow

      if LLMRuntime.isAvailable {
        Divider().overlay(Mono.border)
        Toggle("Tidy every dictation automatically", isOn: $settings.autoCleanLLM)
          .font(.system(size: 13))
        Text("Fixes punctuation and removes filler words. Adds a second or two before the text appears.")
          .font(.caption).foregroundColor(Mono.textFaint)
      }
    }
  }

  @ViewBuilder
  private func cleanupRow(_ spec: ModelSpec) -> some View {
    let mlx = ModelCatalog.spec(ModelCatalog.mlxId)
    let isGemma = spec.id == ModelCatalog.gemmaAsrId
    let mlxInstalled = mlx.map { ModelStore.mlxInstalled($0) } ?? false
    let installed = models.isInstalled(spec) || (isGemma && mlxInstalled)
    let downloading = models.progress[spec.id] != nil
      || (isGemma && mlx.map { models.progress[$0.id] != nil } == true)
    let selected = settings.cleanupModelId == spec.id
      || (isGemma && settings.cleanupModelId == ModelCatalog.mlxId)
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .center, spacing: 10) {
        Button {
          if installed { settings.cleanupModelId = spec.id }
        } label: {
          Image(systemName: selected && installed ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 15))
            .foregroundColor(selected && installed ? .white : Mono.textFaint)
        }
        .buttonStyle(.plain)
        .disabled(!installed)

        VStack(alignment: .leading, spacing: 2) {
          Text(isGemma ? "Gemma 4 E2B" : spec.label)
            .font(.system(size: 13, weight: selected && installed ? .semibold : .regular))
            .foregroundColor(Mono.text)
          Text(isGemma
               ? "Best results, including Hindi and Hinglish."
               : spec.kind == .llm || spec.kind == .mlx
               ? "Smallest and fastest. Lighter edits."
               : spec.note)
            .font(.system(size: 11)).foregroundColor(Mono.textDim)
        }
        Spacer()
        if downloading {
          ProgressView(value: models.progress[spec.id] ?? 0)
            .progressViewStyle(.linear).frame(width: 90)
          Button("Cancel") {
            models.cancel(spec)
            if isGemma, let mlx { models.cancel(mlx) }
          }.font(.system(size: 11))
        } else if installed {
          if spec.kind == .llm || spec.kind == .mlx || isGemma {
            Button {
              models.delete(spec)
              if isGemma, let mlx { models.delete(mlx) }
            } label: { Image(systemName: "trash") }
              .buttonStyle(.plain).foregroundColor(Mono.textFaint).help("Delete model files")
          }
        } else if isGemma, let mlx {
          Button("Get · \(mlx.sizeLabel)") { models.download(mlx) }.font(.system(size: 12))
        } else if spec.kind == .llm || spec.kind == .mlx || spec.textCapable {
          Button("Get · \(spec.sizeLabel)") { models.download(spec) }.font(.system(size: 12))
        } else {
          Text("Get it under Models").font(.system(size: 11)).foregroundColor(Mono.textFaint)
        }
      }
      if let err = models.errors[spec.id] {
        Text(err).font(.system(size: 11))
          .foregroundColor(Color(hex: 0xFF453A)).padding(.leading, 25)
      }
    }
  }

  private var appleIntelligenceRow: some View {
    let ready = MeetingLLM.appleAvailable
    return HStack(alignment: .center, spacing: 10) {
      Image(systemName: "apple.intelligence")
        .font(.system(size: 15))
        .foregroundColor(ready ? .white : Mono.textFaint)
        .frame(width: 15)
      VStack(alignment: .leading, spacing: 2) {
        Text("Apple Intelligence").font(.system(size: 13, weight: .semibold)).foregroundColor(Mono.text)
        Text(MeetingLLM.appleStatus)
          .font(.system(size: 11)).foregroundColor(Mono.textDim)
      }
      Spacer()
      if ready {
        Text("Ready").font(.system(size: 12)).foregroundColor(Mono.textDim)
      } else {
        Button("Open Settings") {
          NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
        .font(.system(size: 12))
      }
    }
  }

  private var ollamaRow: some View {
    let selected = settings.cleanupModelId == ModelCatalog.ollamaId
    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 10) {
        Button {
          settings.cleanupModelId = ModelCatalog.ollamaId
          if ollamaModels.isEmpty { refreshOllama() }
        } label: {
          Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 15))
            .foregroundColor(selected ? .white : Mono.textFaint)
        }
        .buttonStyle(.plain)

        VStack(alignment: .leading, spacing: 2) {
          Text("Ollama")
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundColor(Mono.text)
          Text("Advanced: use a model you run in Ollama.")
            .font(.system(size: 11)).foregroundColor(Mono.textDim)
        }
        Spacer()
        Button("Refresh") { refreshOllama() }.font(.system(size: 12))
      }

      if selected {
        if ollamaModels.isEmpty {
          Text(ollamaChecked
               ? "No models found at \(settings.ollamaHost). Start Ollama, then `ollama pull gemma4:e2b` and hit Refresh."
               : "Checking \(settings.ollamaHost)…")
            .font(.system(size: 11)).foregroundColor(Mono.textFaint).padding(.leading, 25)
        } else {
          Picker("Model", selection: $settings.ollamaModel) {
            Text("None").tag("")
            ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
          }
          .font(.system(size: 13)).padding(.leading, 25)
        }
        TextField("Server", text: $settings.ollamaHost)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 12, design: .monospaced))
          .padding(.leading, 25)
          .onSubmit { refreshOllama() }
      }
    }
  }

  private func refreshOllama() {
    OllamaRuntime.list { names in
      ollamaModels = names
      ollamaChecked = true
      if !names.contains(settings.ollamaModel) { settings.ollamaModel = names.first ?? "" }
    }
  }

  private var engineLabel: String {
    let spec = settings.activeModel
    switch spec.kind {
    case .appleSystem: return "Apple on-device speech"
    case .whisperCpp: return "\(spec.label) · whisper.cpp"
    case .qwenAsr:
      return MLXRuntime.gemmaAsrUsesMlx(spec)
        ? "\(spec.label) · MLX"
        : "\(spec.label) · llama.cpp audio"
    case .autoResolve: return "Auto"
    default: return "\(spec.label) · sherpa-onnx"
    }
  }

  private func chip(_ text: String, strong: Bool) -> some View {
    Text(text)
      .font(.system(size: 9, weight: .bold))
      .foregroundColor(strong ? Mono.text : Mono.textDim)
      .padding(.horizontal, 5).padding(.vertical, 2)
      .background(Capsule().fill(Mono.surfaceAlt))
      .overlay(Capsule().strokeBorder(strong ? Mono.text.opacity(0.4) : Mono.border))
  }

  @ViewBuilder
  private func modelRow(_ spec: ModelSpec) -> some View {
    let mlx = ModelCatalog.spec(ModelCatalog.mlxId)
    let isGemma = spec.id == ModelCatalog.gemmaAsrId
    let mlxInstalled = mlx.map { ModelStore.mlxInstalled($0) } ?? false
    let active = settings.activeModelId == spec.id
    let installed = models.isInstalled(spec) || (isGemma && mlxInstalled)
    let downloading = models.progress[spec.id] != nil
      || (isGemma && mlx.map { models.progress[$0.id] != nil } == true)

    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 10) {
        Button {
          if installed { settings.activeModelId = spec.id }
        } label: {
          Image(systemName: active ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 16))
            .foregroundColor(active ? .white : Mono.textFaint)
        }
        .buttonStyle(.plain)
        .disabled(!installed)

        Text(spec.label)
          .font(.system(size: 13, weight: active ? .semibold : .regular))
          .foregroundColor(Mono.text)
        if spec.live { chip("LIVE", strong: false) }
        chip(spec.quality.rawValue, strong: spec.quality == .best)

        Spacer()

        Text(isGemma ? (mlx?.sizeLabel ?? spec.sizeLabel) : spec.sizeLabel)
          .font(.system(size: 11))
          .foregroundColor(Mono.textFaint)

        if spec.kind == .appleSystem || spec.kind == .autoResolve {
          EmptyView()
        } else if downloading {
          ProgressView(value: models.progress[spec.id] ?? (isGemma ? models.progress[ModelCatalog.mlxId] : nil) ?? 0)
            .progressViewStyle(.linear)
            .frame(width: 90)
          Button("Cancel") {
            models.cancel(spec)
            if isGemma, let mlx { models.cancel(mlx) }
          }
            .font(.system(size: 11))
        } else if installed {
          Button {
            models.delete(spec)
            if isGemma, let mlx { models.delete(mlx) }
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.plain)
          .foregroundColor(Mono.textFaint)
          .help("Delete model files")
        } else if isGemma, let mlx {
          Button("Get") { models.download(mlx) }
            .font(.system(size: 12))
        } else {
          Button("Get") { models.download(spec) }
            .font(.system(size: 12))
        }
      }
      if let err = models.errors[spec.id] {
        Text(err)
          .font(.system(size: 11))
          .foregroundColor(Color(hex: 0xFF453A))
          .padding(.leading, 26)
      }
    }
    .padding(.vertical, 2)
  }

  private var generalCard: some View {
    section("General") {
      Toggle("Launch at login", isOn: $launchAtLogin)
        .onChange(of: launchAtLogin) { LoginItem.set($0) }
      Button("Run setup guide again") { OnboardingController.shared.show() }
        .font(.system(size: 12))
      Button("Check for Updates…") { UpdateManager.shared.checkForUpdates() }
        .font(.system(size: 12))
      Toggle("Restore previous clipboard after inserting", isOn: $settings.restoreClipboard)
      Text("Off leaves the transcript on the clipboard so you can paste it again.")
        .font(.caption).foregroundColor(Mono.textDim)
      HStack {
        Text("Speech engine").foregroundColor(Mono.text)
        Spacer()
        Text(engineLabel)
          .foregroundColor(Mono.textDim)
      }
      .font(.system(size: 13))
    }
  }

  private var permissionCard: some View {
    section("Permission needed") {
      Text("Bolkit needs Accessibility to notice the hold key and type into other apps.")
        .font(.system(size: 13))
        .foregroundColor(Mono.text)
      Button("Grant Accessibility…") {
        Paster.ensureAccessibility()
        NSWorkspace.shared.open(
          URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
      }
    }
  }

  private var vocabularyCard: some View {
    section("Vocabulary") {
      Text("Names, brands and jargon Bolkit should spell right. One per line.")
        .font(.caption).foregroundColor(Mono.textDim)
      TextEditor(text: $settings.vocabulary)
        .font(.system(size: 12, design: .monospaced))
        .frame(height: 110)
        .border(Mono.textDim.opacity(0.3))
      Toggle("Learn words when I fix a transcript right after dictating",
             isOn: $settings.learnCorrections)
      Toggle("Keep my last recording so I can retry it",
             isOn: $settings.keepLatestRecording)
      Text("Only the latest one is kept, on this Mac. Useful if a transcription fails.")
        .font(.caption).foregroundColor(Mono.textDim)
    }
  }

  private var historyCard: some View {
    section("Recent transcripts") {
      Toggle("Save transcript history on this Mac", isOn: $settings.saveHistory)
      if !settings.saveHistory {
        Text("New dictations won’t be kept. Existing entries stay until you clear them.")
          .font(.caption).foregroundColor(Mono.textDim)
      }
      if dictation.history.isEmpty {
        Text("Nothing yet, hold \(settings.holdKey == .off ? "the toggle shortcut" : settings.holdKey.label) and speak.")
          .font(.system(size: 13)).foregroundColor(Mono.textDim)
      } else {
        ForEach(Array(dictation.history.prefix(50).enumerated()), id: \.offset) { i, text in
          HStack(alignment: .top) {
            Text(text)
              .font(.system(size: 12.5))
              .foregroundColor(Mono.text)
              .lineLimit(3)
              .frame(maxWidth: .infinity, alignment: .leading)
            Button {
              let pb = NSPasteboard.general
              pb.clearContents()
              pb.setString(text, forType: .string)
            } label: {
              Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundColor(Mono.textDim)
          }
          .padding(.vertical, 3)
          if i < min(dictation.history.count, 50) - 1 {
            Divider().overlay(Mono.border)
          }
        }
        Button("Clear history") {
          dictation.history = []
          UserDefaults.standard.set([String](), forKey: "history")
        }
        .font(.caption)
      }
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title.uppercased())
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(Mono.textFaint)
        .kerning(1.0)
      VStack(alignment: .leading, spacing: 10) {
        content()
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 14).fill(Mono.surface))
      .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Mono.border))
    }
    .tint(.white)
    .toggleStyle(.switch)
  }
}
