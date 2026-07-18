namespace Scribe;

enum ModelKind { Moonshine, NemoTransducer, NemoCtc, Canary, Whisper, DolphinCtc, OnlineTransducer, NemotronTransducer }

sealed record ModelSpec(
  string Id,
  ModelKind Kind,
  string Label,
  string Note,
  string Archive,
  long SizeBytes,
  bool Live)
{
  public string SizeLabel => $"{Math.Round(SizeBytes / 1e6)} MB";
}

/// Same k2-fsa archives the mobile and Mac apps use.
static class ModelCatalog
{
  public const string Releases =
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models";

  public static readonly ModelSpec[] All =
  {
    new("zipformer-streaming-en", ModelKind.OnlineTransducer,
      "Zipformer Streaming · English", "Live partial text while you speak",
      "sherpa-onnx-streaming-zipformer-en-2023-06-21-mobile.tar.bz2", 365_748_162, true),
    new("nemotron-3.5-streaming-multi", ModelKind.NemotronTransducer,
      "Nemotron 3.5 Streaming · Multilingual", "NVIDIA · live · 40 languages · auto-detect · punctuated",
      "sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11.tar.bz2", 473_894_907, true),
    new("nemotron-streaming-en", ModelKind.NemotronTransducer,
      "Nemotron Streaming · English", "NVIDIA · live · instant · punctuated",
      "sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25.tar.bz2", 463_945_051, true),
    new("moonshine-tiny-en", ModelKind.Moonshine,
      "Moonshine Tiny · English", "Useful Sensors · tiny · transcribes on release",
      "sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2", 29_858_559, false),
    new("moonshine-base-en", ModelKind.Moonshine,
      "Moonshine Base · English", "Useful Sensors · balanced accuracy",
      "sherpa-onnx-moonshine-base-en-quantized-2026-02-27.tar.bz2", 111_266_225, false),
    new("nemo-parakeet-ctc-110m-en", ModelKind.NemoCtc,
      "Parakeet 110M · English", "NVIDIA · fast",
      "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8.tar.bz2", 104_337_827, false),
    new("nemo-parakeet-tdt-0.6b-v2-en", ModelKind.NemoTransducer,
      "Parakeet 0.6B v2 · English", "NVIDIA · best English accuracy",
      "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2", 482_468_385, false),
    new("nemo-parakeet-tdt-0.6b-v3-multi", ModelKind.NemoTransducer,
      "Parakeet 0.6B v3 · Multilingual", "NVIDIA · 25 languages",
      "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2", 487_170_055, false),
    new("nemo-canary-180m-multi", ModelKind.Canary,
      "Canary 180M · Multilingual", "NVIDIA · EN/ES/DE/FR",
      "sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8.tar.bz2", 153_692_328, false),
    new("whisper-tiny-multi", ModelKind.Whisper,
      "Whisper Tiny · Auto-language", "OpenAI · auto-detects 99 languages · quick",
      "sherpa-onnx-whisper-tiny.tar.bz2", 116_200_000, false),
    new("whisper-small-multi", ModelKind.Whisper,
      "Whisper Small · Auto-language", "OpenAI · auto-detect · strong European languages",
      "sherpa-onnx-whisper-small.tar.bz2", 639_400_000, false),
    new("whisper-turbo-multi", ModelKind.Whisper,
      "Whisper Turbo · Auto-language", "OpenAI large-v3-turbo · best auto-detect accuracy",
      "sherpa-onnx-whisper-turbo.tar.bz2", 563_800_000, false),
    new("dolphin-base-multi", ModelKind.DolphinCtc,
      "Dolphin Base · Asian languages", "DataoceanAI · 40 languages incl. Hindi · small & fast",
      "sherpa-onnx-dolphin-base-ctc-multi-lang-int8-2025-04-02.tar.bz2", 80_700_000, false),
  };

  public static ModelSpec Get(string id) =>
    All.FirstOrDefault(m => m.Id == id) ?? All[0];
}
