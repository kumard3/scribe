import Foundation

enum ModelKind: String {
  case appleSystem
  case moonshine
  case nemoTransducer
  case nemoCtc
  case canary
  case whisper
  case dolphinCtc
  case onlineTransducer
}

struct ModelSpec: Identifiable, Equatable {
  let id: String
  let kind: ModelKind
  let label: String
  let note: String
  let archive: String
  let sizeBytes: Int64
  /// true = streams partial text while you speak; false = transcribes on release.
  let live: Bool
  /// Locale for the Apple engine (appleSystem kind only).
  var locale: String = "en-US"
  /// Romanize Devanagari output to Latin "Hinglish" (appleSystem hi-IN only).
  var romanize: Bool = false

  var sizeLabel: String {
    sizeBytes == 0 ? "No download" : "\(Int((Double(sizeBytes) / 1e6).rounded())) MB"
  }
}

enum ModelCatalog {
  static let systemId = "system"
  static let releases = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"

  // Same k2-fsa archives the mobile app uses (src/asr/nemo.ts).
  static let all: [ModelSpec] = [
    ModelSpec(
      id: systemId, kind: .appleSystem,
      label: "Built-in · English",
      note: "Apple on-device speech — instant, streaming, no download.",
      archive: "", sizeBytes: 0, live: true
    ),
    ModelSpec(
      id: "system-en-in", kind: .appleSystem,
      label: "Built-in · English (India)",
      note: "Apple · tuned for Indian-English accent · on-device",
      archive: "", sizeBytes: 0, live: true, locale: "en-IN"
    ),
    ModelSpec(
      id: "system-hi", kind: .appleSystem,
      label: "Built-in · Hindi (हिन्दी)",
      note: "Apple · Hindi & mixed Hindi-English · Devanagari script · add Hindi in System Settings → Dictation for fully offline",
      archive: "", sizeBytes: 0, live: true, locale: "hi-IN"
    ),
    ModelSpec(
      id: "system-hinglish", kind: .appleSystem,
      label: "Built-in · Hinglish (Roman)",
      note: "Same speech, written in English letters — “main kal miting mein aaunga”. Phonetic, so English words spell by sound.",
      archive: "", sizeBytes: 0, live: true, locale: "hi-IN", romanize: true
    ),
    ModelSpec(
      id: "moonshine-tiny-en", kind: .moonshine,
      label: "Moonshine Tiny · English",
      note: "Useful Sensors · tiny · transcribes on release",
      archive: "sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2",
      sizeBytes: 29_858_559, live: false
    ),
    ModelSpec(
      id: "moonshine-base-en", kind: .moonshine,
      label: "Moonshine Base · English",
      note: "Useful Sensors · balanced accuracy",
      archive: "sherpa-onnx-moonshine-base-en-quantized-2026-02-27.tar.bz2",
      sizeBytes: 111_266_225, live: false
    ),
    ModelSpec(
      id: "nemo-parakeet-ctc-110m-en", kind: .nemoCtc,
      label: "Parakeet 110M · English",
      note: "NVIDIA · fast",
      archive: "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8.tar.bz2",
      sizeBytes: 104_337_827, live: false
    ),
    ModelSpec(
      id: "nemo-parakeet-tdt-0.6b-v2-en", kind: .nemoTransducer,
      label: "Parakeet 0.6B v2 · English",
      note: "NVIDIA · best English accuracy",
      archive: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2",
      sizeBytes: 482_468_385, live: false
    ),
    ModelSpec(
      id: "nemo-parakeet-tdt-0.6b-v3-multi", kind: .nemoTransducer,
      label: "Parakeet 0.6B v3 · Multilingual",
      note: "NVIDIA · 25 languages",
      archive: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2",
      sizeBytes: 487_170_055, live: false
    ),
    ModelSpec(
      id: "nemo-canary-180m-multi", kind: .canary,
      label: "Canary 180M · Multilingual",
      note: "NVIDIA · EN/ES/DE/FR",
      archive: "sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8.tar.bz2",
      sizeBytes: 153_692_328, live: false
    ),
    ModelSpec(
      id: "whisper-tiny-multi", kind: .whisper,
      label: "Whisper Tiny · Auto-language",
      note: "OpenAI · auto-detects 99 languages · quick",
      archive: "sherpa-onnx-whisper-tiny.tar.bz2",
      sizeBytes: 116_200_000, live: false
    ),
    ModelSpec(
      id: "whisper-small-multi", kind: .whisper,
      label: "Whisper Small · Auto-language",
      note: "OpenAI · auto-detect · strong European languages",
      archive: "sherpa-onnx-whisper-small.tar.bz2",
      sizeBytes: 639_400_000, live: false
    ),
    ModelSpec(
      id: "whisper-turbo-multi", kind: .whisper,
      label: "Whisper Turbo · Auto-language",
      note: "OpenAI large-v3-turbo · best auto-detect accuracy",
      archive: "sherpa-onnx-whisper-turbo.tar.bz2",
      sizeBytes: 563_800_000, live: false
    ),
    ModelSpec(
      id: "dolphin-base-multi", kind: .dolphinCtc,
      label: "Dolphin Base · Asian languages",
      note: "DataoceanAI · 40 languages incl. Hindi · small & fast",
      archive: "sherpa-onnx-dolphin-base-ctc-multi-lang-int8-2025-04-02.tar.bz2",
      sizeBytes: 80_700_000, live: false
    ),
    ModelSpec(
      id: "zipformer-streaming-en", kind: .onlineTransducer,
      label: "Zipformer Streaming · English",
      note: "Live partial text while you speak",
      archive: "sherpa-onnx-streaming-zipformer-en-2023-06-21-mobile.tar.bz2",
      sizeBytes: 365_748_162, live: true
    ),
  ]

  static func spec(_ id: String) -> ModelSpec? {
    all.first { $0.id == id }
  }
}
