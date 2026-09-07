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
  case nemotronTransducer
  case qwenAsr
  case whisperCpp
  case fluidParakeet
  case arkasrOnnx
  case arkOnnx
  case llm
  case mlx
  case autoResolve
}

/// Offline ONNX engines that take whole utterances and return the transcript.
protocol OfflineAsrEngine {
  func transcribe(samples: [Float], sampleRate: Int) throws -> String
}

/// One member of a multi-file model bundle, downloaded in order into the
/// model dir. `name` is the on-disk name, which for ONNX external-data files
/// must stay exactly as the graph references it.
struct BundleFile: Equatable {
  let url: String
  let name: String
  let sizeBytes: Int64
}

extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

enum ModelQuality: String {
  case best = "BEST"
  case good = "GOOD"
  case basic = "BASIC"
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
  var quality: ModelQuality = .good
  /// Locale for the Apple engine (appleSystem kind only).
  var locale: String = "en-US"
  /// Romanize Devanagari output to Latin "Hinglish" (appleSystem hi-IN only).
  var romanize: Bool = false
  /// Full download URL for single-file models (the LLM GGUF). When set, the file
  /// is saved verbatim, no archive extraction.
  var directURL: String? = nil
  /// Saved file name for directURL downloads (the LLM kind only).
  var fileName: String = ""
  /// Second GGUF for qwenAsr models: the mmproj audio encoder, downloaded
  /// after the main model file.
  var mmprojURL: String? = nil
  var mmprojFileName: String = ""
  var mmprojSizeBytes: Int64 = 0
  /// Optional SHA-256 for a directly downloaded model artifact.
  var sha256: String = ""
  /// Text sent alongside the audio for qwenAsr models. Dedicated ASR models
  /// (Srota) transcribe bare audio; general omni models (Gemma 4) need asking.
  var asrInstruction: String = ""
  /// qwenAsr models that are also good enough at instructions to run AI Cleanup
  /// & Summary, reusing the GGUF already on disk instead of a second download.
  var textCapable: Bool = false
  /// Files for arkasrOnnx bundles, which ship as loose graphs plus weights
  /// rather than one archive.
  var bundleFiles: [BundleFile] = []
  var arkasrConfig = ArkasrEngine.Config()
  var arkConfig = ArkEngine.Config()
  /// whisper.cpp `-l`. Oriserve Hinglish checkpoints expect `hi`.
  var forcedLanguage: String = ""
  /// Hidden from the ASR picker unless Settings.showGemmaAsr is on.
  var hiddenAsr: Bool = false

  var sizeLabel: String {
    if sizeBytes == 0 { return "No download" }
    let mb = Double(sizeBytes) / 1e6
    return mb >= 1000
      ? String(format: "%.1f GB", mb / 1000)
      : "\(Int(mb.rounded())) MB"
  }
}

enum ModelCatalog {
  static let systemId = "system"
  static let autoId = "auto"
  static let swiftId = "oriserve-swift-q8"
  static let apexId = "apex-hinglish-q5"
  static let turboId = "whisper-large-v3-turbo-q5"
  static let gemmaAsrId = "gemma4-e2b-audio"
  static let mlxId = "gemma4-e2b-mlx"
  static let releases = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"

  // Same k2-fsa archives the mobile app uses (src/asr/nemo.ts).
  static let all: [ModelSpec] = [
    ModelSpec(
      id: autoId, kind: .autoResolve,
      label: "Auto · Hinglish + Indian English",
      note: "Apex if downloaded, else Swift, else Built-in. Audio never goes to Gemma.",
      archive: "", sizeBytes: 0, live: true, quality: .best
    ),
    ModelSpec(
      id: systemId, kind: .appleSystem,
      label: "Built-in · English",
      note: "Apple on-device speech, instant, streaming, no download.",
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
      note: "Same speech, written in English letters, “main kal miting mein aaunga”. Phonetic, so English words spell by sound.",
      archive: "", sizeBytes: 0, live: true, quality: .basic, locale: "hi-IN", romanize: true
    ),
    ModelSpec(
      id: swiftId, kind: .whisperCpp,
      label: "Swift · Hinglish",
      note: "Oriserve · 74M · romanized Hinglish + Indian English · live chunks",
      archive: "", sizeBytes: 81_768_585, live: true, quality: .good,
      directURL: "https://huggingface.co/anish2305/airnote-hinglish-stt-ggml/resolve/main/ggml-oriserve-hinglish-q8_0.bin",
      fileName: "ggml-oriserve-hinglish-q8_0.bin",
      sha256: "8550803dc10fa9f0b3db5cb884f8580c61067b062a67ee169d5789bcd0faec90",
      forcedLanguage: "hi"
    ),
    ModelSpec(
      id: apexId, kind: .whisperCpp,
      label: "Apex Q5 · Hinglish",
      note: "Oriserve Whisper Turbo · Indian accents · romanized Hinglish · desktop default",
      archive: "", sizeBytes: 574_041_195, live: true, quality: .best,
      directURL: "https://huggingface.co/Marquestra/Whisper-Hindi2Hinglish-Apex-GGML/resolve/main/ggml-apex-hinglish-q5_0.bin",
      fileName: "ggml-apex-hinglish-q5_0.bin",
      sha256: "9d877151b15cec1feb9110cfbc0a3162cf377bcc0ab1935174226f461cf60f13",
      forcedLanguage: "hi"
    ),
    ModelSpec(
      id: turboId, kind: .whisperCpp,
      label: "Whisper Turbo · English",
      note: "OpenAI large-v3-turbo · English fallback · live chunks",
      archive: "", sizeBytes: 574_041_195, live: true, quality: .good,
      directURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
      fileName: "ggml-large-v3-turbo-q5_0.bin",
      forcedLanguage: "en"
    ),
    ModelSpec(
      id: gemmaAsrId, kind: .qwenAsr,
      label: "Gemma 4 E2B · Audio",
      note: "Google · same Gemma 4 E2B as cleanup · MLX GPU if downloaded, else llama.cpp · slower than Swift/Apex",
      archive: "", sizeBytes: 3_398_849_248, live: false,
      directURL: "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_0.gguf",
      fileName: "gemma-4-E2B-it-Q4_0.gguf",
      mmprojURL: "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/mmproj-gemma-4-E2B-it-Q8_0.gguf",
      mmprojFileName: "mmproj-gemma-4-E2B-it-Q8_0.gguf",
      mmprojSizeBytes: 557_368_064,
      asrInstruction: Self.transcribeInstruction, textCapable: true
    ),
    ModelSpec(
      id: "moonshine-tiny-en", kind: .moonshine,
      label: "Moonshine Tiny · English",
      note: "Useful Sensors · tiny · transcribes on release",
      archive: "sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2",
      sizeBytes: 29_858_559, live: false, quality: .basic
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
      sizeBytes: 482_468_385, live: false, quality: .best
    ),
    ModelSpec(
      id: "nemo-parakeet-tdt-0.6b-v3-multi", kind: .nemoTransducer,
      label: "Parakeet 0.6B v3 · Multilingual",
      note: "NVIDIA · 25 languages",
      archive: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2",
      sizeBytes: 487_170_055, live: false, quality: .best
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
      sizeBytes: 116_200_000, live: false, quality: .basic
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
      sizeBytes: 563_800_000, live: false, quality: .best
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
      sizeBytes: 365_748_162, live: true, quality: .basic
    ),
    ModelSpec(
      id: "nemotron-3.5-streaming-multi", kind: .nemotronTransducer,
      label: "Nemotron 3.5 Streaming · Multilingual",
      note: "NVIDIA · live · 40 languages · auto-detect · punctuated",
      archive: "sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11.tar.bz2",
      sizeBytes: 473_894_907, live: true
    ),
    ModelSpec(
      id: "nemotron-streaming-en", kind: .nemotronTransducer,
      label: "Nemotron Streaming · English",
      note: "NVIDIA · live · instant · punctuated",
      archive: "sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25.tar.bz2",
      sizeBytes: 463_945_051, live: true
    ),
    ModelSpec(
      id: "srota-hinglish", kind: .qwenAsr,
      label: "Srota · Hinglish",
      note: "Qwen3-ASR fine-tune · natural Hindi-English mix · transcribes on release",
      archive: "", sizeBytes: 1_018_020_320, live: false, quality: .best,
      directURL: "https://github.com/kumard3/scribe/releases/download/srota-gguf-1/srota-hinglish-q8_0.gguf",
      fileName: "srota-hinglish-q8_0.gguf",
      mmprojURL: "https://github.com/kumard3/scribe/releases/download/srota-gguf-1/mmproj-srota-hinglish-f16.gguf",
      mmprojFileName: "mmproj-srota-hinglish-f16.gguf",
      mmprojSizeBytes: 378_576_480
    ),
    ModelSpec(
      id: "fluid-parakeet-v2-en", kind: .fluidParakeet,
      label: "Parakeet ANE · English",
      note: "FluidAudio · runs on the Neural Engine · downloads itself on first use",
      archive: "", sizeBytes: 0, live: false, quality: .best
    ),
    ModelSpec(
      id: "fluid-parakeet-v3-multi", kind: .fluidParakeet,
      label: "Parakeet ANE · Multilingual",
      note: "FluidAudio · Neural Engine · 25 languages · downloads itself on first use",
      archive: "", sizeBytes: 0, live: false, quality: .best
    ),
    ModelSpec(
      id: "audio8-asr-0.1b", kind: .arkasrOnnx,
      label: "Audio8 0.1B · Multilingual",
      note: "Audio8 · EN/ZH/YUE/FR/JA/DE/KO · handles code-switching · non-commercial licence (CC BY-NC 4.0)",
      archive: "", sizeBytes: 760_476_589, live: false,
      bundleFiles: Self.audio8Bundle(
        repo: "Audio8/Audio8-ASR-0.1B-onnx-runtime",
        files: [
          ("audio_hidden_int8.onnx", "audio_hidden_int8.onnx", 234_699_007),
          ("lm_cache_prefill_int8.onnx", "lm_cache_prefill_int8.onnx", 1_308_788),
          ("lm_cache_prefill_int8.onnx.data", "lm_cache_prefill_int8.onnx.data", 103_565_312),
          ("lm_cache_decode_int8.onnx", "lm_cache_decode_int8.onnx", 1_255_083),
          ("lm_cache_decode_int8.onnx.data", "lm_cache_decode_int8.onnx.data", 103_598_080),
          ("weights/token_embedding.npy", "token_embedding.npy", 311_165_056),
          ("weights/audio_projector.npz", "audio_projector.npz", 2_108_430),
          ("vocab.json", "vocab.json", 2_776_833),
        ])
    ),
    ModelSpec(
      id: "ark-asr-0.6b", kind: .arkOnnx,
      label: "ARK 0.6B · Multilingual",
      note: "Audio8 · 19 languages · Apache 2.0 · best on technical terms · first run after download is slow",
      archive: "", sizeBytes: 1_750_897_835, live: false,
      bundleFiles: Self.hfFiles(
        repo: "Audio8/ark-asr-0.6b-int8-onnx",
        files: [
          ("audio_encoder_whisper_int8.onnx", 640_432_014),
          ("audio_encoder_adapter_int8.onnx", 10_810_770),
          ("embedding_fp32.onnx", 300),
          ("embedding_fp32.data", 587_625_472),
          ("llm_kv_cpu_fp32_int8.onnx", 509_252_446),
          ("vocab.json", 2_776_833),
        ])
    ),
    ModelSpec(
      id: mlxId, kind: .mlx,
      label: "Gemma 4 E2B",
      note: "GPU runtime files for Gemma 4 E2B on this Mac (MLX). Not a different model.",
      archive: "", sizeBytes: 3_583_000_000, live: false, quality: .best,
      bundleFiles: Self.hfFiles(
        repo: "mlx-community/gemma-4-e2b-it-4bit",
        files: [
          ("config.json", 6_395),
          ("generation_config.json", 208),
          ("tokenizer_config.json", 2_740),
          ("tokenizer.json", 32_169_626),
          ("chat_template.jinja", 17_336),
          ("processor_config.json", 1_316),
          ("model.safetensors.index.json", 218_323),
          ("model.safetensors", 3_550_670_554),
        ])
    ),
    ModelSpec(
      id: "qwen-cleanup-0.5b", kind: .llm,
      label: "Qwen 2.5 · 0.5B",
      note: "Tiny on-device cleanup & summary · offline · under 1 GB peak",
      archive: "", sizeBytes: 491_400_032, live: false,
      directURL: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf",
      fileName: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
      sha256: "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db"
    ),
  ]

  /// Audio8 bundles live under model_bundle/ in their HF repo.
  private static func audio8Bundle(
    repo: String, files: [(String, String, Int64)]
  ) -> [BundleFile] {
    files.map {
      BundleFile(
        url: "https://huggingface.co/\(repo)/resolve/main/model_bundle/\($0.0)",
        name: $0.1, sizeBytes: $0.2)
    }
  }

  /// Files kept at the root of an HF repo, saved under the same name.
  private static func hfFiles(repo: String, files: [(String, Int64)]) -> [BundleFile] {
    files.map {
      BundleFile(
        url: "https://huggingface.co/\(repo)/resolve/main/\($0.0)",
        name: $0.0, sizeBytes: $0.1)
    }
  }

  /// An omni model will happily answer questions about the audio instead of
  /// writing it out, so the ask is explicit and the output format is pinned.
  static let transcribeInstruction =
    "Transcribe this audio verbatim. Output only the spoken words, with no " +
    "commentary, no speaker labels and no timestamps."

  /// What actually goes with the audio: the base ask, the picked language and
  /// the user's vocabulary. Left of the audio marker on purpose, see cllama.c.
  static func asrPrompt(for spec: ModelSpec) -> String {
    guard !spec.asrInstruction.isEmpty else { return "" }
    var parts = [spec.asrInstruction]
    let settings = Settings.shared
    // An omni model writes native Hinglish when asked, which beats transcribing
    // to Devanagari and transliterating after. Naming one language here instead
    // makes it render the whole mixed sentence in that script.
    if settings.romanizeHindi {
      parts.append(
        "The speaker mixes Hindi and English in one sentence. Write every word " +
        "in Latin script the way Hinglish is typed, never in Devanagari."
      )
    } else if settings.language != "auto",
              let language = speechLanguages.first(where: { $0.code == settings.language }) {
      parts.append("The audio is in \(language.label). Write the transcript in \(language.label).")
    }
    if let terms = Vocabulary.whisperPrompt {
      parts.append("These names appear in the audio, spell them exactly: \(terms).")
    }
    return parts.joined(separator: " ")
  }

  static func spec(_ id: String) -> ModelSpec? {
    all.first { $0.id == id }
  }

  /// Sentinel id for "send cleanup to the local Ollama server instead".
  static let ollamaId = "ollama"

  static func asrModels(showGemma: Bool) -> [ModelSpec] {
    all.filter {
      $0.kind != .llm && $0.kind != .mlx && (showGemma || !$0.hiddenAsr)
    }
  }

  /// Apex if on disk, else Swift, else Whisper turbo, else Apple.
  static func resolveAuto(installed: (ModelSpec) -> Bool) -> ModelSpec {
    for id in [apexId, swiftId, turboId] {
      if let spec = spec(id), installed(spec) { return spec }
    }
    if Settings.shared.romanizeHindi, let hinglish = spec("system-hinglish") {
      return hinglish
    }
    return spec(systemId)!
  }

  /// Models that can run AI Cleanup & Summary: the dedicated small LLM plus the
  /// multimodal ASR models that are full instruction LLMs anyway.
  static var cleanupModels: [ModelSpec] {
    all.filter { $0.kind == .llm || $0.textCapable }
  }
}

enum DictationStyle: String, CaseIterable, Identifiable {
  case auto, english, hinglish
  var id: String { rawValue }
  var label: String {
    switch self {
    case .auto: return "Auto"
    case .english: return "English"
    case .hinglish: return "Hinglish"
    }
  }
}

enum WhisperDecode {
  /// Oriserve checkpoints are trained with decoder language `hi`. Style English
  /// pins `en`; anything else keeps the checkpoint's forced language.
  static func language(for spec: ModelSpec) -> String {
    let style = DictationStyle(rawValue: Settings.shared.dictationStyle) ?? .auto
    switch style {
    case .english:
      return "en"
    case .hinglish:
      return spec.forcedLanguage.isEmpty ? "hi" : spec.forcedLanguage
    case .auto:
      let lang = Settings.shared.language
      if lang == "en" { return spec.forcedLanguage.isEmpty ? "en" : spec.forcedLanguage }
      if !spec.forcedLanguage.isEmpty { return spec.forcedLanguage }
      return lang == "auto" ? "auto" : lang
    }
  }
}
