using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using SherpaOnnx;

namespace Scribe;

static class AudioFile
{
  public static float[] Decode16kMono(string path)
  {
    using var reader = new AudioFileReader(path);
    ISampleProvider src = reader.WaveFormat.Channels > 1
      ? new StereoToMonoSampleProvider(reader)
      : reader;
    if (src.WaveFormat.SampleRate != 16000)
      src = new WdlResamplingSampleProvider(src, 16000);

    var samples = new List<float>(16000 * 60);
    var buf = new float[16000];
    int n;
    while ((n = src.Read(buf, 0, buf.Length)) > 0)
      samples.AddRange(new ArraySegment<float>(buf, 0, n));
    return samples.ToArray();
  }
}

static class Punctuation
{
  static readonly string Dir = Path.Combine(ModelStore.AuxRoot, "punct");
  const string Archive = "sherpa-onnx-online-punct-en-2024-08-06.tar.bz2";
  const string Url =
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/" + Archive;
  const long SizeBytes = 29L * 1024 * 1024;

  static OnlinePunctuation? _punct;
  static int _installing;

  static string? Model =>
    Directory.Exists(Dir)
      ? Directory.EnumerateFiles(Dir, "model.onnx", SearchOption.AllDirectories).FirstOrDefault()
      : null;
  static string? Vocab =>
    Directory.Exists(Dir)
      ? Directory.EnumerateFiles(Dir, "bpe.vocab", SearchOption.AllDirectories).FirstOrDefault()
      : null;

  public static bool Installed => Model != null && Vocab != null;

  public static async Task EnsureAsync(Action<string> status)
  {
    if (Installed) return;
    Directory.CreateDirectory(Dir);
    var tmp = Path.Combine(Dir, Archive);
    await ModelStore.DownloadTo(Url, tmp, SizeBytes, p => status($"Downloading punctuation model… {p}%"));
    status("Preparing punctuation model…");
    ModelStore.ExtractArchive(tmp, Dir);
    if (File.Exists(tmp)) File.Delete(tmp);
  }

  static OnlinePunctuation? Instance()
  {
    if (_punct != null) return _punct;
    var m = Model;
    var v = Vocab;
    if (m == null || v == null) return null;
    var cfg = new OnlinePunctuationConfig();
    cfg.Model.CnnBiLstm = m;
    cfg.Model.BpeVocab = v;
    cfg.Model.NumThreads = 1;
    cfg.Model.Provider = "cpu";
    _punct = new OnlinePunctuation(cfg);
    return _punct;
  }

  // Downloads in the background on first use, returning input unchanged until ready.
  public static string Apply(string text, Action<string> status)
  {
    if (string.IsNullOrWhiteSpace(text)) return text;
    if (!Installed) { EnsureInBackground(status); return text; }
    var p = Instance();
    if (p == null) return text;
    try
    {
      var outText = p.AddPunct(text)?.Trim();
      return string.IsNullOrEmpty(outText) ? text : outText;
    }
    catch { return text; }
  }

  static void EnsureInBackground(Action<string> status)
  {
    if (Interlocked.Exchange(ref _installing, 1) == 1) return;
    Task.Run(async () =>
    {
      try { await EnsureAsync(status); }
      catch { try { if (Directory.Exists(Dir)) Directory.Delete(Dir, true); } catch { } }
      finally { Interlocked.Exchange(ref _installing, 0); }
    });
  }
}

static class Diarization
{
  static readonly string Dir = Path.Combine(ModelStore.AuxRoot, "diar");
  static string SegDir => Path.Combine(Dir, "segmentation");
  const string SegArchive = "sherpa-onnx-pyannote-segmentation-3-0.tar.bz2";
  const string SegUrl =
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/" + SegArchive;
  const long SegSize = 6L * 1024 * 1024;
  const string EmbFile = "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx";
  // The k2-fsa release tag is spelled "recongition" upstream, keep the typo.
  const string EmbUrl =
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/" + EmbFile;
  const long EmbSize = 28L * 1024 * 1024;

  static string? SegModel =>
    Directory.Exists(SegDir)
      ? Directory.EnumerateFiles(SegDir, "model.onnx", SearchOption.AllDirectories).FirstOrDefault()
      : null;
  static string EmbPath => Path.Combine(Dir, EmbFile);

  public static bool Installed => SegModel != null && File.Exists(EmbPath);

  public static async Task EnsureAsync(Action<string> status)
  {
    if (SegModel == null)
    {
      Directory.CreateDirectory(SegDir);
      var tmp = Path.Combine(SegDir, SegArchive);
      await ModelStore.DownloadTo(SegUrl, tmp, SegSize, p => status($"Downloading speaker model… {p}%"));
      status("Preparing speaker model…");
      ModelStore.ExtractArchive(tmp, SegDir);
      if (File.Exists(tmp)) File.Delete(tmp);
    }
    if (!File.Exists(EmbPath))
    {
      Directory.CreateDirectory(Dir);
      await ModelStore.DownloadTo(EmbUrl, EmbPath, EmbSize, p => status($"Downloading speaker model… {p}%"));
    }
  }

  // numSpeakers <= 0 lets the clusterer decide the count automatically.
  public static string Compose(string text, float[] samples, int numSpeakers)
  {
    var seg = SegModel;
    if (seg == null || !File.Exists(EmbPath)) return text;

    int threads = Math.Max(1, Environment.ProcessorCount / 2);
    var cfg = new OfflineSpeakerDiarizationConfig();
    cfg.Segmentation.Pyannote.Model = seg;
    cfg.Segmentation.NumThreads = threads;
    cfg.Embedding.Model = EmbPath;
    cfg.Embedding.NumThreads = threads;
    if (numSpeakers > 0) cfg.Clustering.NumClusters = numSpeakers;

    using var sd = new OfflineSpeakerDiarization(cfg);
    var diar = sd.Process(samples) ?? Array.Empty<OfflineSpeakerDiarizationSegment>();
    return TurnsToText(BuildTurns(text, diar));
  }

  static List<(int Speaker, string Text)> BuildTurns(string text, OfflineSpeakerDiarizationSegment[] diar)
  {
    var turns = new List<(int, string)>();
    var trimmed = text.Trim();
    if (diar.Length == 0)
    {
      if (trimmed.Length > 0) turns.Add((0, trimmed));
      return turns;
    }
    var words = trimmed.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
    if (words.Length == 0) return turns;

    var ordered = diar.OrderBy(d => d.Start).ToArray();
    double total = ordered.Sum(d => Math.Max(0, d.End - d.Start));
    if (total <= 0) total = 1;

    int idx = 0;
    for (int i = 0; i < ordered.Length; i++)
    {
      var d = ordered[i];
      double share = Math.Max(0, d.End - d.Start) / total;
      int count = i == ordered.Length - 1 ? words.Length - idx : (int)Math.Round(share * words.Length);
      count = Math.Clamp(count, 0, words.Length - idx);
      if (count == 0) continue;
      var piece = string.Join(" ", words[idx..(idx + count)]);
      idx += count;
      if (turns.Count > 0 && turns[^1].Item1 == d.Speaker)
        turns[^1] = (d.Speaker, turns[^1].Item2 + " " + piece);
      else
        turns.Add((d.Speaker, piece));
    }
    return turns;
  }

  static string TurnsToText(List<(int Speaker, string Text)> turns)
  {
    if (turns.Count == 0) return "";
    if (turns.Count == 1) return turns[0].Text;
    return string.Join("\n\n", turns.Select(t => $"Speaker {t.Speaker + 1}: {t.Text}"));
  }
}
