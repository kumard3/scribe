import SwiftUI
import AppKit

// pureMono, same palette as the mobile app (src/ui/themes.ts)
private enum Mono {
  static let bg = Color(hex: 0x000000)
  static let surface = Color(hex: 0x141416)
  static let surfaceAlt = Color(hex: 0x1C1C1F)
  static let border = Color(hex: 0x2A2A2E)
  static let text = Color.white
  static let textDim = Color(hex: 0x9A9AA3)
  static let textFaint = Color(hex: 0x5C5C66)
}

private extension Color {
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
      HStack(spacing: size * 0.1) {
        Capsule().fill(.white).frame(width: size * 0.1, height: size * 0.3)
        Capsule().fill(.white).frame(width: size * 0.1, height: size * 0.52)
        Capsule().fill(.white).frame(width: size * 0.1, height: size * 0.38)
      }
    }
    .frame(width: size, height: size)
  }
}

struct DashboardView: View {
  @ObservedObject var dictation = DictationManager.shared
  @ObservedObject var settings = Settings.shared
  @ObservedObject var models = ModelStore.shared
  @ObservedObject var support = SupportModelStore.shared
  @State private var launchAtLogin = LoginItem.enabled
  @State private var axTrusted = AXIsProcessTrusted()
  @State private var ollamaModels: [String] = []
  @State private var ollamaChecked = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        header
        hotkeysCard
        modelsCard
        audioFileCard
        llmCard
        generalCard
        if !axTrusted { permissionCard }
        historyCard
      }
      .padding(28)
    }
    .frame(minWidth: 560, minHeight: 620)
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

  private var header: some View {
    HStack(spacing: 14) {
      LogoMark(size: 48)
      VStack(alignment: .leading, spacing: 3) {
        Text("Scribe")
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
      Text("Hold to speak, release to insert. Works in any app.")
        .font(.caption).foregroundColor(Mono.textDim)

      Toggle("Quick tap starts hands-free mode (tap again to stop)", isOn: $settings.tapHandsFree)

      Divider().overlay(Mono.border)

      HStack {
        Text("Toggle shortcut").foregroundColor(Mono.text)
        Spacer()
        ShortcutRecorder()
      }
      .font(.system(size: 13))
      Text("Click the shortcut, then press any key combo you like. Start/stop, works even without Accessibility.")
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
      Text("Auto keeps mixed Indian English + WhatsApp Hinglish. English pins the English decoder. Hinglish forces romanized Hindi.")
        .font(.caption).foregroundColor(Mono.textFaint)

      Picker("Language", selection: $settings.language) {
        ForEach(speechLanguages) { l in Text(l.label).tag(l.code) }
      }
      .font(.system(size: 13))
      Text("Auto-detect misreads accented speech. Naming your language is the biggest accuracy win.")
        .font(.caption).foregroundColor(Mono.textFaint)

      HStack {
        Text("Chunk pause").foregroundColor(Mono.text)
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
      Text("How long a pause closes a live chunk. Shorter feels snappier; longer holds a sentence together.")
        .font(.caption).foregroundColor(Mono.textFaint)

      Toggle("Write Hindi in English letters (Hinglish)", isOn: $settings.romanizeHindi)
        .font(.system(size: 13))
      Toggle("Adaptive mic conditioning", isOn: $settings.conditionAudio)
        .font(.system(size: 13))
      Text("Reduces rumble and safely evens out quiet microphones. Accent recognition comes from the selected model.")
        .font(.caption).foregroundColor(Mono.textFaint)
      Toggle("Use GPU acceleration (CoreML)", isOn: $settings.useGpu)
        .font(.system(size: 13))
      Text("Runs downloaded models on the GPU/Neural Engine when the build supports it. Falls back to CPU otherwise.")
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

  private var audioFileCard: some View {
    section("Audio file") {
      Text("Transcribe an existing recording (mp3, m4a, wav, aac) with your selected model, fully on this Mac. Pick a downloaded model above first.")
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
        Text("Auto over-segments long calls. Setting the real speaker count is the biggest accuracy win.")
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
    section("AI Cleanup & Summary") {
      Text("Punctuates dictation on this Mac. Gemma 4 E2B is one model; MLX is the Apple GPU runtime for cleanup and for Gemma STT, not a second model.")
        .font(.caption).foregroundColor(Mono.textDim)

      ForEach(ModelCatalog.cleanupModels) { spec in
        cleanupRow(spec)
      }

      Divider().overlay(Mono.border)
      ollamaRow

      if LLMRuntime.isAvailable {
        Divider().overlay(Mono.border)
        Toggle("Clean up every dictation automatically", isOn: $settings.autoCleanLLM)
          .font(.system(size: 13))
        Text("Adds a moment after you stop talking while the AI rewrites your text before it's inserted.")
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
               ? (mlxInstalled
                  ? "Runtime: MLX (Apple GPU). Same Gemma 4 E2B as STT."
                  : "Runtime: MLX on this Mac. Get pulls GPU weights for the same Gemma 4 E2B, not a new model.")
               : spec.textCapable
               ? "Text cleanup only. Audio never goes to this model."
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
          if spec.kind == .llm || isGemma {
            Button {
              models.delete(spec)
              if isGemma, let mlx { models.delete(mlx) }
            } label: { Image(systemName: "trash") }
              .buttonStyle(.plain).foregroundColor(Mono.textFaint).help("Delete model files")
          }
        } else if isGemma, let mlx {
          Button("Get · \(mlx.sizeLabel)") { models.download(mlx) }.font(.system(size: 12))
        } else if spec.kind == .llm || spec.textCapable {
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
          Text("Any model you have pulled, e.g. `ollama pull gemma4:e2b`")
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
      Text("Off keeps the transcript on the clipboard so you can paste it again.")
        .font(.caption).foregroundColor(Mono.textDim)
      HStack {
        Text("Engine").foregroundColor(Mono.text)
        Spacer()
        Text(engineLabel)
          .foregroundColor(Mono.textDim)
      }
      .font(.system(size: 13))
    }
  }

  private var permissionCard: some View {
    section("Permission needed") {
      Text("Accessibility lets Scribe watch the hold key and paste into other apps.")
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

  private var historyCard: some View {
    section("Recent transcripts") {
      Toggle("Save transcript history on this Mac", isOn: $settings.saveHistory)
      if !settings.saveHistory {
        Text("New dictations won’t be kept. Existing entries stay until you clear them.")
          .font(.caption).foregroundColor(Mono.textDim)
      }
      Text("Vocabulary").font(.headline)
      Text("One name, acronym or bit of jargon per line. Primes Swift/Apex (whisper.cpp prompt), biases Parakeet/Nemotron, and is the HOTWORDS list Gemma may correct toward.")
        .font(.caption).foregroundColor(Mono.textDim)
      TextEditor(text: $settings.vocabulary)
        .font(.system(size: 12, design: .monospaced))
        .frame(height: 90)
        .border(Mono.textDim.opacity(0.3))
      Toggle("Learn terms from corrections I make right after dictating",
             isOn: $settings.learnCorrections)

      Toggle("Keep the last recording so a failed transcription can be retried",
             isOn: $settings.keepLatestRecording)
      Text("One WAV, replaced by each offline dictation and never leaving this Mac. Turn it off and a transcription that fails takes the audio with it.")
        .font(.caption).foregroundColor(Mono.textDim)
      if dictation.history.isEmpty {
        Text("Nothing yet, hold \(settings.holdKey == .off ? "the toggle shortcut" : settings.holdKey.label) and speak.")
          .font(.system(size: 13)).foregroundColor(Mono.textDim)
      } else {
        ForEach(Array(dictation.history.prefix(15).enumerated()), id: \.offset) { i, text in
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
          if i < min(dictation.history.count, 15) - 1 {
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
