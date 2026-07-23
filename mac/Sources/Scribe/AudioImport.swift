import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Transcribe an existing audio file (mp3/m4a/wav/aac). AVFoundation decodes the
/// container to float PCM; the samples then take the same offline transcription
/// path as dictation, plus optional speaker diarization and punctuation.
enum AudioImport {
  private static var resultWindow: NSWindow?

  static func present() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.audio]
    panel.prompt = "Transcribe"
    panel.message = "Choose an audio file to transcribe on this Mac."
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    run(url: url)
  }

  static func run(url: URL) {
    let d = DictationManager.shared
    guard !d.isRecording else { d.status = "Stop dictation before importing a file."; return }
    let spec = Settings.shared.activeModel
    guard spec.kind != .appleSystem, spec.kind != .llm else {
      d.status = "Pick a downloaded model in the Dashboard to transcribe a file."
      return
    }
    guard installed(spec) else {
      d.status = "Download \(spec.label) in the Dashboard first."
      return
    }

    d.phase = .transcribing
    d.status = "Reading \(url.lastPathComponent)…"
    HUD.shared.show()
    let language = Settings.shared.language
    let provider = Settings.shared.sherpaProvider(for: spec)

    DispatchQueue.global(qos: .userInitiated).async {
      guard let (samples, rate) = decode(url) else {
        DispatchQueue.main.async {
          d.status = "Couldn't read that audio file."
          d.phase = .idle
          HUD.shared.hide()
        }
        return
      }
      DispatchQueue.main.async { d.status = "Transcribing with \(spec.label)…" }
      NativeTranscriptionWorker.shared.transcribe(
        spec: spec, samples: samples, sampleRate: rate,
        language: language, provider: provider
      ) { result in
        switch result {
        case let .failure(error):
          d.status = error.localizedDescription
          d.phase = .idle
          HUD.shared.hide()
        case let .success(text):
          postProcess(text: text, samples: samples, sampleRate: rate, spec: spec)
        }
      }
    }
  }

  /// Diarization (optional) + punctuation + spoken-command formatting. Runs off
  /// the main thread because both native passes can be slow on long files.
  private static func postProcess(text: String, samples: [Float], sampleRate: Int, spec: ModelSpec) {
    let d = DictationManager.shared
    let wantDiar = Settings.shared.diarizeImports && SupportModelStore.diarInstalled
    let speakers = Settings.shared.diarizeSpeakers
    DispatchQueue.global(qos: .userInitiated).async {
      let final: String
      if wantDiar {
        DispatchQueue.main.async { d.status = "Identifying speakers…" }
        let segments = Diarizer.diarize(samples: samples, sampleRate: sampleRate, numSpeakers: speakers)
        let turns = Diarizer.buildSpeakerTurns(text: text, segments: segments)
          .map { SpeakerTurn(speaker: $0.speaker, text: clean($0.text, spec: spec)) }
        final = Diarizer.turnsToText(turns)
      } else {
        final = clean(text, spec: spec)
      }
      DispatchQueue.main.async {
        d.status = "Ready"
        d.phase = .idle
        HUD.shared.hide()
        d.importedResult(final)
        guard !final.isEmpty else {
          d.status = "No speech detected in that file."
          return
        }
        presentResult(final, source: spec.label)
      }
    }
  }

  /// Punctuate un-punctuated engines, then apply formatting-only spoken commands.
  /// Destructive edits ("scratch that") are never applied to imported recordings.
  private static func clean(_ text: String, spec: ModelSpec) -> String {
    var t = text
    if PunctuationRuntime.needsPunctuation(spec.kind), SupportModelStore.punctInstalled {
      t = PunctuationRuntime.shared.punctuate(t)
    }
    return VoiceCommands.apply(t, allowDestructive: false)
  }

  private static func installed(_ spec: ModelSpec) -> Bool {
    let dir = ModelStore.dir(for: spec)
    let fm = FileManager.default
    switch spec.kind {
    case .qwenAsr:
      return fm.fileExists(atPath: dir.appendingPathComponent(spec.fileName).path)
        && fm.fileExists(atPath: dir.appendingPathComponent(spec.mmprojFileName).path)
    case .whisperCpp:
      return fm.fileExists(atPath: dir.appendingPathComponent(spec.fileName).path)
    default:
      return ModelStore.tokensFile(in: dir) != nil
    }
  }

  private static func decode(_ url: URL) -> (samples: [Float], sampleRate: Int)? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let format = file.processingFormat
    let frames = AVAudioFrameCount(file.length)
    guard frames > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
          (try? file.read(into: buffer)) != nil,
          let channel = buffer.floatChannelData else { return nil }
    let n = Int(buffer.frameLength)
    let samples = [Float](UnsafeBufferPointer(start: channel[0], count: n))
    return (samples, Int(format.sampleRate))
  }

  private static func presentResult(_ text: String, source: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)

    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
    scroll.hasVerticalScroller = true
    scroll.autoresizingMask = [.width, .height]
    let textView = NSTextView(frame: scroll.bounds)
    textView.isEditable = false
    textView.isRichText = false
    textView.string = text
    textView.font = .systemFont(ofSize: 13)
    textView.textContainerInset = NSSize(width: 12, height: 12)
    textView.autoresizingMask = [.width]
    scroll.documentView = textView

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
    )
    window.title = "Transcript · \(source) (copied to clipboard)"
    window.contentView = scroll
    window.center()
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    resultWindow = window
  }
}
