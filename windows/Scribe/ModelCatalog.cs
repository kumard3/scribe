namespace Scribe;

enum ModelKind
{
  Moonshine, NemoTransducer, NemoCtc, Canary, Whisper, DolphinCtc,
  OnlineTransducer, NemotronTransducer, WhisperCpp, GemmaAudio
}

sealed record ModelSpec(
  string Id,
  ModelKind Kind,
  string Label,
  string Note,
  string Archive,
  long SizeBytes,
  bool Live,
  bool Punctuated = false,
  string? DirectUrl = null,
  string? FileName = null,
  string? MmprojUrl = null,
  string? MmprojFileName = null,
  long MmprojSizeBytes = 0,
  string ForcedLanguage = "")
{
  public string SizeLabel => SizeBytes >= 1_000_000_000
    ? $"{SizeBytes / 1e9:0.0} GB"
    : $"{Math.Round(SizeBytes / 1e6)} MB";
  public bool Native => Kind is ModelKind.WhisperCpp or ModelKind.GemmaAudio;
}

/// Same k2-fsa archives the mobile and Mac apps use.
static class ModelCatalog
{
  public const string Releases =
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models";

  public static readonly ModelSpec[] All =
  {
    new("oriserve-swift-q8", ModelKind.WhisperCpp,
      "Swift · Hinglish", "Oriserve · 74M · romanized Hinglish + Indian English · live chunks",
      "", 81_768_585, true,
      DirectUrl: "https://huggingface.co/anish2305/airnote-hinglish-stt-ggml/resolve/main/ggml-oriserve-hinglish-q8_0.bin",
      FileName: "ggml-oriserve-hinglish-q8_0.bin", ForcedLanguage: "hi"),
    new("apex-hinglish-q5", ModelKind.WhisperCpp,
      "Apex Q5 · Hinglish", "Oriserve Whisper Turbo · Indian accents · romanized Hinglish",
      "", 574_041_195, true,
      DirectUrl: "https://huggingface.co/Marquestra/Whisper-Hindi2Hinglish-Apex-GGML/resolve/main/ggml-apex-hinglish-q5_0.bin",
      FileName: "ggml-apex-hinglish-q5_0.bin", ForcedLanguage: "hi"),
    new("whisper-large-v3-turbo-q5", ModelKind.WhisperCpp,
      "Whisper Turbo · English", "OpenAI large-v3-turbo · English fallback · live chunks",
      "", 574_041_195, true,
      DirectUrl: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
      FileName: "ggml-large-v3-turbo-q5_0.bin", ForcedLanguage: "en"),
    new("gemma4-e2b-audio", ModelKind.GemmaAudio,
      "Gemma 4 E2B · Audio", "Google · llama.cpp (CUDA/Vulkan/CPU). Not MLX. Hinglish when the toggle is on.",
      "", 2_839_481_184, false,
      DirectUrl: "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_0.gguf",
      FileName: "gemma-4-E2B-it-Q4_0.gguf",
      MmprojUrl: "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/mmproj-gemma-4-E2B-it-Q8_0.gguf",
      MmprojFileName: "mmproj-gemma-4-E2B-it-Q8_0.gguf",
      MmprojSizeBytes: 557_368_064),
    new("zipformer-streaming-en", ModelKind.OnlineTransducer,
      "Zipformer Streaming · English", "Live partial text while you speak",
      "sherpa-onnx-streaming-zipformer-en-2023-06-21-mobile.tar.bz2", 365_748_162, true),
    new("nemotron-3.5-streaming-multi", ModelKind.NemotronTransducer,
      "Nemotron 3.5 Streaming · Multilingual", "NVIDIA · live · 40 languages · auto-detect · punctuated",
      "sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11.tar.bz2", 473_894_907, true, Punctuated: true),
    new("nemotron-streaming-en", ModelKind.NemotronTransducer,
      "Nemotron Streaming · English", "NVIDIA · live · instant · punctuated",
      "sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25.tar.bz2", 463_945_051, true, Punctuated: true),
    new("moonshine-tiny-en", ModelKind.Moonshine,
      "Moonshine Tiny · English", "Useful Sensors · tiny · transcribes on release",
      "sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2", 29_858_559, false, Punctuated: true),
    new("moonshine-base-en", ModelKind.Moonshine,
      "Moonshine Base · English", "Useful Sensors · balanced accuracy",
      "sherpa-onnx-moonshine-base-en-quantized-2026-02-27.tar.bz2", 111_266_225, false, Punctuated: true),
    new("nemo-parakeet-ctc-110m-en", ModelKind.NemoCtc,
      "Parakeet 110M · English", "NVIDIA · fast",
      "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8.tar.bz2", 104_337_827, false),
    new("nemo-parakeet-tdt-0.6b-v2-en", ModelKind.NemoTransducer,
      "Parakeet 0.6B v2 · English", "NVIDIA · best English accuracy",
      "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2", 482_468_385, false, Punctuated: true),
    new("nemo-parakeet-tdt-0.6b-v3-multi", ModelKind.NemoTransducer,
      "Parakeet 0.6B v3 · Multilingual", "NVIDIA · 25 languages",
      "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2", 487_170_055, false, Punctuated: true),
    new("nemo-canary-180m-multi", ModelKind.Canary,
      "Canary 180M · Multilingual", "NVIDIA · EN/ES/DE/FR",
      "sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8.tar.bz2", 153_692_328, false, Punctuated: true),
    new("whisper-tiny-multi", ModelKind.Whisper,
      "Whisper Tiny · Auto-language", "OpenAI · auto-detects 99 languages · quick",
      "sherpa-onnx-whisper-tiny.tar.bz2", 116_200_000, false, Punctuated: true),
    new("whisper-small-multi", ModelKind.Whisper,
      "Whisper Small · Auto-language", "OpenAI · auto-detect · strong European languages",
      "sherpa-onnx-whisper-small.tar.bz2", 639_400_000, false, Punctuated: true),
    new("whisper-turbo-multi", ModelKind.Whisper,
      "Whisper Turbo · Auto-language", "OpenAI large-v3-turbo · best auto-detect accuracy",
      "sherpa-onnx-whisper-turbo.tar.bz2", 563_800_000, false, Punctuated: true),
    new("dolphin-base-multi", ModelKind.DolphinCtc,
      "Dolphin Base · Asian languages", "DataoceanAI · 40 languages incl. Hindi · small & fast",
      "sherpa-onnx-dolphin-base-ctc-multi-lang-int8-2025-04-02.tar.bz2", 80_700_000, false),
  };

  public static ModelSpec Get(string id) =>
    All.FirstOrDefault(m => m.Id == id) ?? All[0];
}
