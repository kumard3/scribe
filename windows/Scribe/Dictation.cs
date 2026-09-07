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

  public bool Ready => _online != null || _offline != null || _native;
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
  const int MaxBufferedSamples = 16_000 * 900;
  bool _native;
  PauseChunker _chunker = new();
  readonly Queue<float[]> _nativeReady = new();
  bool _nativeInFlight;
  string _nativeCommitted = "";
  CancellationTokenSource? _watch;

  public Dictation(Overlay overlay) => _overlay = overlay;

  public async Task PrepareAsync()
  {
    var spec = ModelCatalog.Get(Settings.Instance.ModelId);
    await EnsureEngineAsync(spec);
    _overlay.HideOverlay();
  }

  /// Switch models at runtime (settings picker). Safe to call while idle.
  public async Task SwitchAsync(ModelSpec spec)
  {
    lock (_lock)
    {
      if (IsRecording) Stop();
    }
    await EnsureEngineAsync(spec);
    _overlay.HideOverlay();
  }

  async Task EnsureEngineAsync(ModelSpec spec)
  {
    var dir = await ModelStore.EnsureAsync(spec, s => _overlay.ShowStatus(s));
    if (spec.Kind == ModelKind.WhisperCpp)
      await NativeBins.EnsureWhisperAsync(s => _overlay.ShowStatus(s));
    if (spec.Kind == ModelKind.GemmaAudio)
      await NativeBins.EnsureLlamaAsync(s => _overlay.ShowStatus(s));
    _overlay.ShowStatus($"Loading {spec.Label}…");
    await Task.Run(() =>
    {
      lock (_lock)
      {
        _online?.Dispose();
        _offline?.Dispose();
        _online = null;
        _offline = null;
        _native = false;
        Load(spec, dir);
      }
    });
  }

  void Load(ModelSpec spec, string dir)
  {
    _spec = spec;
    if (spec.Native)
    {
      _native = true;
      return;
    }
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
      cfg.DecodingMethod = "greedy_search";
      cfg.EnableEndpoint = 1;
      cfg.Rule1MinTrailingSilence = 2.4f;
      cfg.Rule2MinTrailingSilence = 1.2f;
      cfg.Rule3MinUtteranceLength = 20f;
      _online = GpuRuntime.Create(provider =>
      {
        cfg.ModelConfig.Provider = provider;
        return new OnlineRecognizer(cfg);
      });
      return;
    }

    var off = new OfflineRecognizerConfig();
    off.FeatConfig.SampleRate = 16000;
    off.FeatConfig.FeatureDim = 80;
    off.ModelConfig.Tokens = Directory.EnumerateFiles(dir).First(f => f.EndsWith("tokens.txt"));
    off.ModelConfig.NumThreads = threads;
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
    _offline = GpuRuntime.Create(provider =>
    {
      off.ModelConfig.Provider = provider;
      return new OfflineRecognizer(off);
    });
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
      _nativeCommitted = "";
      _nativeReady.Clear();
      _nativeInFlight = false;
      _chunker.Reset(16000);
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

      if (_native)
      {
        var last = _chunker.Flush();
        if (last != null) _nativeReady.Enqueue(last);
        ArmWatch();
        text = "";
      }
      else if (_online != null)
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

    if (_native)
    {
      MaybeSpawnNative();
      bool done;
      lock (_lock) done = _nativeReady.Count == 0 && !_nativeInFlight;
      if (done) FinishNative(_nativeCommitted);
      return;
    }

    if (toTranscribe != null)
    {
      _overlay.ShowStatus("Transcribing…");
      var samples = toTranscribe;
      Task.Run(() =>
      {
        string result;
        lock (_lock) result = DecodeOffline(samples);
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

  string DecodeOffline(float[] samples)
  {
    if (_offline == null || samples.Length == 0) return "";
    using var s = _offline.CreateStream();
    s.AcceptWaveform(16000, samples);
    _offline.Decode(s);
    return s.Result.Text.Trim();
  }

  string DecodeOnlineFull(float[] samples)
  {
    if (_online == null || samples.Length == 0) return "";
    using var s = _online.CreateStream();
    s.AcceptWaveform(16000, samples);
    s.InputFinished();
    string committed = "";
    while (_online.IsReady(s))
    {
      _online.Decode(s);
      if (_online.IsEndpoint(s))
      {
        var seg = _online.GetResult(s).Text.Trim();
        if (seg.Length > 0) committed = (committed + " " + seg).Trim();
        _online.Reset(s);
      }
    }
    var last = _online.GetResult(s).Text.Trim();
    var text = (committed + " " + last).Trim();
    while (text.Contains("  ")) text = text.Replace("  ", " ");
    return text;
  }

  public Task<string> TranscribeSamplesAsync(float[] samples) => Task.Run(() =>
  {
    lock (_lock)
      return _offline != null ? DecodeOffline(samples) : DecodeOnlineFull(samples);
  });

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

      if (_native)
      {
        foreach (var chunk in _chunker.Feed(samples))
          _nativeReady.Enqueue(chunk);
        if (_nativeReady.Count > 0) MaybeSpawnNative();
        partial = _nativeCommitted;
      }
      else if (_online != null && _stream != null)
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

  void MaybeSpawnNative()
  {
    float[]? slice = null;
    lock (_lock)
    {
      if (_nativeInFlight || _nativeReady.Count == 0) return;
      slice = _nativeReady.Dequeue();
      _nativeInFlight = true;
    }
    var spec = _spec!;
    var samples = slice!;
    Task.Run(() =>
    {
      string piece;
      try
      {
        piece = spec.Kind == ModelKind.GemmaAudio
          ? GemmaCpp.Transcribe(samples)
          : WhisperCpp.Transcribe(spec, samples);
      }
      catch (Exception ex)
      {
        piece = "";
        _overlay.ShowStatus(ex.Message, 4);
      }
      string committed;
      bool more, finishing;
      lock (_lock)
      {
        _nativeInFlight = false;
        if (piece.Length > 0)
          _nativeCommitted = (_nativeCommitted + " " + piece).Trim();
        committed = _nativeCommitted;
        more = _nativeReady.Count > 0;
        finishing = !IsRecording && !more && !_nativeInFlight;
      }
      if (committed.Length > 0)
        _overlay.UpdatePartial(committed, 0.2f);
      if (more) MaybeSpawnNative();
      else if (finishing) FinishNative(committed);
    });
  }

  void ArmWatch()
  {
    _watch?.Cancel();
    _watch = new CancellationTokenSource();
    var token = _watch.Token;
    _ = Task.Delay(35_000, token).ContinueWith(t =>
    {
      if (t.IsCanceled) return;
      string committed;
      lock (_lock)
      {
        if (!_native || IsRecording) return;
        _nativeReady.Clear();
        _nativeInFlight = false;
        committed = _nativeCommitted;
      }
      FinishNative(committed);
    }, TaskScheduler.Default);
  }

  void FinishNative(string text)
  {
    _watch?.Cancel();
    text = Romanizer.NormalizeScript(text);
    if (text.Length > 0) _overlay.ShowInserted();
    else _overlay.HideOverlay();
    Finished?.Invoke(text);
  }

  public void Dispose()
  {
    _watch?.Cancel();
    if (IsRecording) Stop();
    _online?.Dispose();
    _online = null;
    _offline?.Dispose();
    _offline = null;
  }
}
