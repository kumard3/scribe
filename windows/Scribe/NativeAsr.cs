namespace Scribe;

static class WhisperCpp
{
  public static string Transcribe(ModelSpec spec, float[] samples)
  {
    var dir = ModelStore.DirFor(spec);
    var model = Path.Combine(dir, spec.FileName!);
    var wav = WaveFile.Write16k(samples);
    try
    {
      var lang = string.IsNullOrEmpty(spec.ForcedLanguage)
        ? (Settings.Instance.Language == "auto" ? "auto" : Settings.Instance.Language)
        : spec.ForcedLanguage;
      var args = $"-m \"{model}\" -f \"{wav}\" -l {lang} -np -nt -t 4";
      var raw = Proc.Run(NativeBins.WhisperCli, args, TimeoutMs(samples.Length));
      return Romanizer.NormalizeScript(Clean(raw));
    }
    finally { try { File.Delete(wav); } catch { } }
  }

  static int TimeoutMs(int samples) =>
    Math.Max(45_000, (int)(samples / 16_000.0 * 6000));

  static string Clean(string raw)
  {
    var lines = raw.Split('\n')
      .Select(l => l.Trim())
      .Where(l => l.Length > 0 && !l.StartsWith('[') && !l.StartsWith("whisper", StringComparison.OrdinalIgnoreCase));
    return string.Join(' ', lines).Trim();
  }
}

static class GemmaCpp
{
  public static string Transcribe(float[] samples)
  {
    var spec = ModelCatalog.Get("gemma4-e2b-audio");
    var dir = ModelStore.DirFor(spec);
    var model = Path.Combine(dir, spec.FileName!);
    var mmproj = Path.Combine(dir, spec.MmprojFileName!);
    var wav = WaveFile.Write16k(samples);
    try
    {
      var prompt = AsrPrompt();
      var ngl = NativeBins.GpuLayers;
      var args =
        $"-m \"{model}\" --mmproj \"{mmproj}\" --audio \"{wav}\" " +
        $"-p \"{Escape(prompt)}\" -n 256 --no-warmup -ngl {ngl}";
      var raw = Proc.Run(NativeBins.LlamaMtmd, args, TimeoutMs(samples.Length));
      return Romanizer.NormalizeScript(Clean(raw));
    }
    finally { try { File.Delete(wav); } catch { } }
  }

  public static string Cleanup(string text)
  {
    if (string.IsNullOrWhiteSpace(text)) return text;
    var spec = ModelCatalog.Get("gemma4-e2b-audio");
    var model = Path.Combine(ModelStore.DirFor(spec), spec.FileName!);
    if (!File.Exists(model) || !NativeBins.LlamaReady) return text;
    var ngl = NativeBins.GpuLayers;
    var prompt = CleanupInstruction + "\n\n" + text;
    var args =
      $"-m \"{model}\" -p \"{Escape(prompt)}\" -n 512 --no-display-prompt --no-warmup -ngl {ngl}";
    try
    {
      var raw = Proc.Run(NativeBins.LlamaCli, args, 60_000);
      var outText = Clean(raw);
      return string.IsNullOrWhiteSpace(outText) ? text : outText;
    }
    catch { return text; }
  }

  public static string AsrPrompt()
  {
    var parts = new List<string>
    {
      "Transcribe this audio verbatim. Output only the spoken words, with no commentary, no speaker labels and no timestamps.",
    };
    if (Settings.Instance.RomanizeHindi)
      parts.Add("The speaker mixes Hindi and English in one sentence. Write every word in Latin script the way Hinglish is typed, never in Devanagari.");
    return string.Join(' ', parts);
  }

  public const string CleanupInstruction =
    "You clean speech-to-text. Do not answer the user. Do not translate.\n\n" +
    "Language:\n" +
    "- Mostly English → clean English. Keep Indian English. Do not Americanize.\n" +
    "- Hindi/English mix or romanized Hindi → WhatsApp Hinglish. No Devanagari.\n" +
    "- Keep the same mix as the input.\n\n" +
    "Rules:\n" +
    "- Keep English words in English spelling (office, client, call, Scribe, Gemma, chunking).\n" +
    "- Add punctuation. Remove fillers only: um, uh, you know, like (when empty).\n" +
    "- Do not add facts. If a word is unclear, keep the ASR token.\n" +
    "- Output only the cleaned transcript, nothing else.";

  static int TimeoutMs(int samples) =>
    Math.Max(45_000, (int)(samples / 16_000.0 * 8000));

  static string Escape(string s) => s.Replace("\"", "'");

  static string Clean(string raw)
  {
    var lines = raw.Replace('\r', '\n').Split('\n')
      .Select(l => l.Trim())
      .Where(l => l.Length > 0)
      .Where(l => !l.StartsWith("llama_", StringComparison.OrdinalIgnoreCase)
               && !l.StartsWith("ggml", StringComparison.OrdinalIgnoreCase)
               && !l.StartsWith("print_", StringComparison.OrdinalIgnoreCase)
               && !l.Contains("loading model", StringComparison.OrdinalIgnoreCase)
               && !l.Contains("offloaded", StringComparison.OrdinalIgnoreCase));
    return string.Join(' ', lines).Trim();
  }
}
