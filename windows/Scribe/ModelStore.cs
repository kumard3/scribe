using SharpCompress.Common;
using SharpCompress.Readers;

namespace Scribe;

/// Downloads + extracts model archives into %LOCALAPPDATA%\Scribe\models\<id>.
static class ModelStore
{
  static string Base => Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Scribe");

  public static string Root => Path.Combine(Base, "models");
  public static string AuxRoot => Path.Combine(Base, "aux");

  public static string DirFor(ModelSpec spec) => Path.Combine(Root, spec.Id);

  /// Directory holding the extracted model files (where tokens.txt lives).
  public static string? ModelDir(ModelSpec spec)
  {
    var root = DirFor(spec);
    if (!Directory.Exists(root)) return null;
    // whisper archives prefix the tokens file (e.g. tiny-tokens.txt)
    static bool HasTokens(string d) =>
      Directory.EnumerateFiles(d).Any(f => f.EndsWith("tokens.txt"));
    if (HasTokens(root)) return root;
    return Directory.EnumerateDirectories(root).FirstOrDefault(HasTokens);
  }

  public static bool IsInstalled(ModelSpec spec)
  {
    if (spec.DirectUrl != null && spec.FileName != null)
    {
      var f = Path.Combine(DirFor(spec), spec.FileName);
      if (!File.Exists(f)) return false;
      if (spec.MmprojFileName != null)
        return File.Exists(Path.Combine(DirFor(spec), spec.MmprojFileName));
      return true;
    }
    return ModelDir(spec) != null;
  }

  public static void Delete(ModelSpec spec)
  {
    var dir = DirFor(spec);
    if (Directory.Exists(dir)) Directory.Delete(dir, true);
  }

  public static async Task<string> EnsureAsync(ModelSpec spec, Action<string> status)
  {
    if (spec.DirectUrl != null && spec.FileName != null)
    {
      var dir = DirFor(spec);
      Directory.CreateDirectory(dir);
      var dest = Path.Combine(dir, spec.FileName);
      if (!File.Exists(dest))
      {
        status($"Downloading {spec.Label} ({spec.SizeLabel}, one time)…");
        var tmp = dest + ".part";
        try
        {
          await DownloadTo(spec.DirectUrl, tmp, spec.SizeBytes,
            pct => status($"Downloading {spec.Label}… {pct}%"));
          File.Move(tmp, dest, true);
        }
        catch
        {
          try { File.Delete(tmp); } catch { }
          throw;
        }
      }
      if (spec.MmprojUrl != null && spec.MmprojFileName != null)
      {
        var mm = Path.Combine(dir, spec.MmprojFileName);
        if (!File.Exists(mm))
        {
          status($"Downloading {spec.Label} audio encoder…");
          var tmp = mm + ".part";
          try
          {
            await DownloadTo(spec.MmprojUrl, tmp, spec.MmprojSizeBytes,
              pct => status($"Downloading audio encoder… {pct}%"));
            File.Move(tmp, mm, true);
          }
          catch
          {
            try { File.Delete(tmp); } catch { }
            throw;
          }
        }
      }
      return dir;
    }

    var existing = ModelDir(spec);
    if (existing != null) return existing;

    var archiveDir = DirFor(spec);
    Directory.CreateDirectory(archiveDir);
    var archiveTmp = Path.Combine(archiveDir, spec.Archive);
    status($"Downloading {spec.Label} ({spec.SizeLabel}, one time)…");
    try
    {
      await DownloadTo($"{ModelCatalog.Releases}/{spec.Archive}", archiveTmp, spec.SizeBytes,
        pct => status($"Downloading {spec.Label}… {pct}%"));
      status($"Extracting {spec.Label}…");
      await Task.Run(() => ExtractArchive(archiveTmp, archiveDir));
    }
    catch
    {
      try { Directory.Delete(archiveDir, true); } catch { }
      throw;
    }
    finally
    {
      if (File.Exists(archiveTmp)) File.Delete(archiveTmp);
    }

    return ModelDir(spec) ?? throw new IOException("Model archive did not contain a model folder.");
  }

  public static async Task DownloadTo(string url, string dest, long sizeHint, Action<int>? onPercent)
  {
    using var http = new HttpClient();
    http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "Scribe/1.0");
    using var res = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
    res.EnsureSuccessStatusCode();
    long total = res.Content.Headers.ContentLength ?? sizeHint;
    await using var src = await res.Content.ReadAsStreamAsync();
    await using var dst = File.Create(dest);
    var buf = new byte[1 << 16];
    long done = 0;
    int lastPct = -1;
    int n;
    while ((n = await src.ReadAsync(buf)) > 0)
    {
      await dst.WriteAsync(buf.AsMemory(0, n));
      done += n;
      if (total > 0)
      {
        int pct = (int)(done * 100 / total);
        if (pct != lastPct) { lastPct = pct; onPercent?.Invoke(pct); }
      }
    }
    if (total > 0 && done < total)
      throw new IOException("Download was incomplete, check your connection and retry.");
  }

  public static void ExtractArchive(string archivePath, string destDir)
  {
    using var stream = File.OpenRead(archivePath);
    using var reader = ReaderFactory.OpenReader(stream, new ReaderOptions());
    while (reader.MoveToNextEntry())
    {
      if (!reader.Entry.IsDirectory)
        reader.WriteEntryToDirectory(destDir, new ExtractionOptions
        {
          ExtractFullPath = true,
          Overwrite = true,
        });
    }
  }

  /// Picks a model file whose name contains `needle`, preferring (or
  /// avoiding) int8 quantized variants. Newer archives ship .ort files.
  public static string? Find(string dir, string needle, bool preferInt8 = true)
  {
    var files = Directory.GetFiles(dir)
      .Where(f => (f.EndsWith(".onnx") || f.EndsWith(".ort"))
                  && Path.GetFileName(f).Contains(needle))
      .ToArray();
    var int8 = files.FirstOrDefault(f => f.Contains("int8"));
    var fp = files.FirstOrDefault(f => !f.Contains("int8"));
    return preferInt8 ? int8 ?? fp : fp ?? int8;
  }
}
