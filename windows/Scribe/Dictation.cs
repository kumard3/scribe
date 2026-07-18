using NAudio.Wave;
using SherpaOnnx;

namespace Scribe;

/// On-device STT: NAudio mic capture → sherpa-onnx. Live models (streaming
/// zipformer) decode as you speak; offline models (Moonshine, Parakeet,
/// Canary) buffer the take and transcribe on release.
sealed class Dictation : IDisposable
{
  public event Action<string>? Finished;
  public event Action<bool>? StateChanged;

  public bool Ready => _online != null || _offline != null;
  public bool IsRecording { get; private set; }

  readonly Overlay _overlay;
  readonly object _lock = new();

  ModelSpec? _spec;
  OnlineRecognizer? _online;
  OfflineRecognizer? _offline;
  OnlineStream? _stream;
  WaveInEvent? _waveIn;
  string _committed = "";
  string _current = "";
  readonly List<float> _buffered = new();
  // ~15 min at 16 kHz; past this we stop buffering rather than grow unbounded
  const int MaxBufferedSamples = 16_000 * 900;

  public Dictation(Overlay overlay) => _overlay = overlay;

  public async Task PrepareAsync()
  {
    var spec = ModelCatalog.Get(Settings.Instance.ModelId);
    var dir = await ModelStore.EnsureAsync(spec, s => _overlay.ShowStatus(s));
    _overlay.ShowStatus($"Loading {spec.Label}…");
    await Task.Run(() => Load(spec, dir));
    _overlay.HideOverlay();
  }

  /// Switch models at runtime (settings picker). Safe to call while idle.
  public async Task SwitchAsync(ModelSpec spec)
  {
    lock (_lock)
    {
      if (IsRecording) Stop();
    }
    var dir = await ModelStore.EnsureAsync(spec, s => _overlay.ShowStatus(s));
    _overlay.ShowStatus($"Loading {spec.Label}…");
    await Task.Run(() =>
    {
      lock (_lock)
      {
        _online?.Dispose();
        _offline?.Dispose();
        _online = null;
        _offline = null;
        Load(spec, dir);
      }
    });
    _overlay.HideOverlay();
  }

  void Load(ModelSpec spec, string dir)
  {
    _spec = spec;
    int threads = Math.Max(2, Environment.ProcessorCount / 2);

    if (spec.Kind == ModelKind.OnlineTransducer || spec.Kind == ModelKind.NemotronTransducer)
    {
      // Nemotron ships int8-only; zipformer ships an fp32 decoder. sherpa
      // auto-detects the online model type from the encoder metadata.
      bool decInt8 = spec.Kind == ModelKind.NemotronTransducer;
      var cfg = new OnlineRecognizerConfig();
      cfg.FeatConfig.SampleRate = 16000;
      cfg.FeatConfig.FeatureDim = 80;
      cfg.ModelConfig.Transducer.Encoder = ModelStore.Find(dir, "encoder")!;
      cfg.ModelConfig.Transducer.Decoder = ModelStore.Find(dir, "decoder", preferInt8: decInt8)!;
      cfg.ModelConfig.Transducer.Joiner = ModelStore.Find(dir, "joiner")!;
      cfg.ModelConfig.Tokens = Path.Combine(dir, "tokens.txt");
      cfg.ModelConfig.NumThreads = threads;
      cfg.ModelConfig.Provider = "cpu";
      cfg.DecodingMethod = "greedy_search";
      cfg.EnableEndpoint = 1;
      cfg.Rule1MinTrailingSilence = 2.4f;
      cfg.Rule2MinTrailingSilence = 1.2f;
      cfg.Rule3MinUtteranceLength = 20f;
      _online = new OnlineRecognizer(cfg);
      return;
    }

    var off = new OfflineRecognizerConfig();
    off.FeatConfig.SampleRate = 16000;
    off.FeatConfig.FeatureDim = 80;
    off.ModelConfig.Tokens = Directory.EnumerateFiles(dir).First(f => f.EndsWith("tokens.txt"));
    off.ModelConfig.NumThreads = threads;
    off.ModelConfig.Provider = "cpu";
    off.DecodingMethod = "greedy_search";

    switch (spec.Kind)
    {
      case ModelKind.Moonshine:
        var mergedEnc = ModelStore.Find(dir, "encoder_model");
        var merged = ModelStore.Find(dir, "decoder_model_merged");
        if (mergedEnc != null && merged != null)
        {
          // moonshine v2: encoder + merged decoder only
          off.ModelConfig.Moonshine.Encoder = mergedEnc;
          off.ModelConfig.Moonshine.MergedDecoder = merged;
        }
        else
        {
          off.ModelConfig.Moonshine.Preprocessor = ModelStore.Find(dir, "preprocess")!;
          off.ModelConfig.Moonshine.Encoder = ModelStore.Find(dir, "encode")!;
          off.ModelConfig.Moonshine.UncachedDecoder = ModelStore.Find(dir, "uncached_decode")!;
          off.ModelConfig.Moonshine.CachedDecoder = ModelStore.Find(dir, "cached_decode")!;
        }
        break;
      case ModelKind.NemoCtc:
        off.ModelConfig.NeMoCtc.Model = ModelStore.Find(dir, "model")!;
        break;
      case ModelKind.NemoTransducer:
        off.ModelConfig.Transducer.Encoder = ModelStore.Find(dir, "encoder")!;
        off.ModelConfig.Transducer.Decoder = ModelStore.Find(dir, "decoder")!;
        off.ModelConfig.Transducer.Joiner = ModelStore.Find(dir, "joiner")!;
        off.ModelConfig.ModelType = "nemo_transducer";
        break;
      case ModelKind.Canary:
        off.ModelConfig.Canary.Encoder = ModelStore.Find(dir, "encoder")!;
        off.ModelConfig.Canary.Decoder = ModelStore.Find(dir, "decoder")!;
        off.ModelConfig.Canary.SrcLang = "en";
        off.ModelConfig.Canary.TgtLang = "en";
        off.ModelConfig.Canary.UsePnc = 1;
        break;
      case ModelKind.Whisper:
        off.ModelConfig.Whisper.Encoder = ModelStore.Find(dir, "encoder")!;
        off.ModelConfig.Whisper.Decoder = ModelStore.Find(dir, "decoder", preferInt8: false)!;
        var lang = Settings.Instance.Language;
        off.ModelConfig.Whisper.Language = lang == "auto" ? "" : lang;
        off.ModelConfig.Whisper.Task = "transcribe";
        off.ModelConfig.Whisper.TailPaddings = -1;
        break;
      case ModelKind.DolphinCtc:
        off.ModelConfig.Dolphin.Model = ModelStore.Find(dir, "model")!;
        break;
    }
    _offline = new OfflineRecognizer(off);
  }

  public void Toggle()
  {
    if (IsRecording) Stop(); else Start();
  }

  public void Start()
  {
    lock (_lock)
    {
      if (IsRecording || !Ready) return;
      _committed = "";
      _current = "";
      _buffered.Clear();
      if (_online != null) _stream = _online.CreateStream();
      _waveIn = new WaveInEvent
      {
        WaveFormat = new WaveFormat(16000, 16, 1),
        BufferMilliseconds = 100,
      };
      _waveIn.DataAvailable += OnAudio;
      _waveIn.StartRecording();
      IsRecording = true;
    }
    StateChanged?.Invoke(true);
    _overlay.SetListening();
  }

  public void Stop()
  {
    string text;
    float[]? toTranscribe = null;
    lock (_lock)
    {
      if (!IsRecording) return;
      IsRecording = false;
      _waveIn!.DataAvailable -= OnAudio;
      _waveIn.StopRecording();
      _waveIn.Dispose();
      _waveIn = null;

      if (_online != null)
      {
        _stream!.InputFinished();
        while (_online.IsReady(_stream)) _online.Decode(_stream);
        var last = _online.GetResult(_stream).Text.Trim();
        text = (_committed + " " + last).Trim();
        while (text.Contains("  ")) text = text.Replace("  ", " ");
        _stream.Dispose();
        _stream = null;
      }
      else
      {
        toTranscribe = _buffered.ToArray();
        _buffered.Clear();
        text = "";
      }
    }
    StateChanged?.Invoke(false);

    if (toTranscribe != null)
    {
      _overlay.ShowStatus("Transcribing…");
      var samples = toTranscribe;
      Task.Run(() =>
      {
        string result = "";
        lock (_lock)
        {
          if (_offline != null && samples.Length > 0)
          {
            using var s = _offline.CreateStream();
            s.AcceptWaveform(16000, samples);
            _offline.Decode(s);
            result = s.Result.Text.Trim();
          }
        }
        if (result.Length > 0) _overlay.ShowInserted();
        else _overlay.HideOverlay();
        Finished?.Invoke(result);
      });
      return;
    }

    if (text.Length > 0) _overlay.ShowInserted();
    else _overlay.HideOverlay();
    Finished?.Invoke(text);
  }

  void OnAudio(object? sender, WaveInEventArgs e)
  {
    float level;
    string partial;
    lock (_lock)
    {
      if (!IsRecording) return;

      int n = e.BytesRecorded / 2;
      var samples = new float[n];
      double sum = 0;
      for (int i = 0; i < n; i++)
      {
        short s = BitConverter.ToInt16(e.Buffer, i * 2);
        samples[i] = s / 32768f;
        sum += samples[i] * samples[i];
      }
      level = Math.Min(1f, (float)Math.Sqrt(sum / Math.Max(n, 1)) * 14f);

      if (_online != null && _stream != null)
      {
        _stream.AcceptWaveform(16000, samples);
        while (_online.IsReady(_stream)) _online.Decode(_stream);
        _current = _online.GetResult(_stream).Text.Trim();
        if (_online.IsEndpoint(_stream))
        {
          if (_current.Length > 0) _committed = (_committed + " " + _current).Trim();
          _current = "";
          _online.Reset(_stream);
        }
        partial = (_committed + " " + _current).Trim();
      }
      else
      {
        if (_buffered.Count < MaxBufferedSamples) _buffered.AddRange(samples);
        partial = "";
      }
    }
    _overlay.UpdatePartial(partial, level);
  }

  public void Dispose()
  {
    if (IsRecording) Stop();
    _online?.Dispose();
    _online = null;
    _offline?.Dispose();
    _offline = null;
  }
}
