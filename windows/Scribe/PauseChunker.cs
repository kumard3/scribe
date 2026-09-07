namespace Scribe;

struct PauseChunker
{
  public int SampleRate = 16_000;
  public int PauseMs = 550;
  public double HardCapSeconds = 3;
  public double OverlapSeconds = 0.3;
  public float SpeechRms = 0.01f;
  public double MinSpeechSeconds = 0.15;
  public double LeadPadSeconds = 0.1;

  public PauseChunker() { }

  readonly List<float> _current = new();
  readonly List<float> _lead = new();
  int _silent, _voiced;
  bool _inSpeech;

  int PauseSamples => Math.Max(1, SampleRate * Math.Max(PauseMs, 1) / 1000);
  int HardCapSamples => Math.Max(PauseSamples, (int)(SampleRate * HardCapSeconds));
  int MinSpeechSamples => Math.Max(1, (int)(SampleRate * MinSpeechSeconds));
  int OverlapSamples => Math.Max(0, (int)(SampleRate * OverlapSeconds));

  public void Reset(int sampleRate)
  {
    SampleRate = Math.Max(sampleRate, 1);
    _current.Clear();
    _lead.Clear();
    _silent = _voiced = 0;
    _inSpeech = false;
  }

  public List<float[]> Feed(float[] samples)
  {
    var outChunks = new List<float[]>();
    if (samples.Length == 0) return outChunks;
    int win = Math.Max(1, SampleRate / 100);
    int i = 0;
    while (i < samples.Length)
    {
      int end = Math.Min(i + win, samples.Length);
      float rms = Rms(samples, i, end - i);
      int n = end - i;
      if (rms >= SpeechRms)
      {
        if (!_inSpeech)
        {
          _current.AddRange(_lead);
          _lead.Clear();
          _inSpeech = true;
        }
        for (int k = i; k < end; k++) _current.Add(samples[k]);
        _voiced += n;
        _silent = 0;
      }
      else if (_inSpeech)
      {
        for (int k = i; k < end; k++) _current.Add(samples[k]);
        _silent += n;
      }
      else
      {
        for (int k = i; k < end; k++) _lead.Add(samples[k]);
        int pad = (int)(SampleRate * LeadPadSeconds);
        if (_lead.Count > pad) _lead.RemoveRange(0, _lead.Count - pad);
      }
      if (_inSpeech && _voiced >= MinSpeechSamples &&
          (_silent >= PauseSamples || _voiced >= HardCapSamples))
      {
        var chunk = Close();
        if (chunk != null) outChunks.Add(chunk);
      }
      i = end;
    }
    return outChunks;
  }

  public float[]? Flush() => Close();

  float[]? Close()
  {
    var chunk = _current.ToArray();
    if (_voiced < MinSpeechSamples)
    {
      _current.Clear();
      _lead.Clear();
      _silent = _voiced = 0;
      _inSpeech = false;
      return null;
    }
    int keep = Math.Min(OverlapSamples, chunk.Length);
    _current.Clear();
    if (keep > 0) _current.AddRange(chunk.AsSpan(chunk.Length - keep).ToArray());
    _lead.Clear();
    _silent = _voiced = 0;
    _inSpeech = false;
    return chunk;
  }

  static float Rms(float[] s, int start, int n)
  {
    if (n <= 0) return 0;
    double sum = 0;
    for (int i = 0; i < n; i++) sum += s[start + i] * s[start + i];
    return (float)Math.Sqrt(sum / n);
  }
}
