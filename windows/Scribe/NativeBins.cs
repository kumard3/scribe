using System.IO.Compression;
using System.Net.Http.Headers;
using System.Text.Json;

namespace Scribe;

static class NativeBins
{
  static string Root => Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
    "Scribe", "bins");

  public static string WhisperCli => Path.Combine(Root, "whisper", "whisper-cli.exe");
  public static string LlamaMtmd => Path.Combine(Root, "llama", "llama-mtmd-cli.exe");
  public static string LlamaCli => Path.Combine(Root, "llama", "llama-cli.exe");

  public static bool WhisperReady => File.Exists(WhisperCli);
  public static bool LlamaReady => File.Exists(LlamaMtmd) && File.Exists(LlamaCli);

  public static int GpuLayers =>
    GpuRuntime.Resolve() is "cuda" or "directml" ? 999 : 0;

  public static async Task EnsureWhisperAsync(Action<string> status)
  {
    if (WhisperReady) return;
    Directory.CreateDirectory(Path.Combine(Root, "whisper"));
    var nvidia = GpuRuntime.Nvidia;
    var url = nvidia
      ? "https://github.com/ggml-org/whisper.cpp/releases/download/b4938/whisper-cublas-12.4.0-bin-x64.zip"
      : "https://github.com/ggml-org/whisper.cpp/releases/download/b4938/whisper-blas-bin-x64.zip";
    status(nvidia ? "Downloading whisper.cpp (CUDA)…" : "Downloading whisper.cpp…");
    await Unpack(url, Path.Combine(Root, "whisper"), "whisper-cli.exe");
  }

  public static async Task EnsureLlamaAsync(Action<string> status)
  {
    if (LlamaReady) return;
    Directory.CreateDirectory(Path.Combine(Root, "llama"));
    GpuRuntime.Probe();
    string zip;
    if (GpuRuntime.Nvidia)
    {
      zip = "llama-b10837-bin-win-cuda-12.4-x64.zip";
      status("Downloading llama.cpp (CUDA)…");
    }
    else if (GpuRuntime.HasGpu)
    {
      zip = "llama-b10837-bin-win-vulkan-x64.zip";
      status("Downloading llama.cpp (Vulkan)…");
    }
    else
    {
      zip = "llama-b10837-bin-win-cpu-x64.zip";
      status("Downloading llama.cpp (CPU)…");
    }
    var url = "https://github.com/ggml-org/llama.cpp/releases/download/b10837/" + zip;
    try
    {
      await Unpack(url, Path.Combine(Root, "llama"), "llama-mtmd-cli.exe");
    }
    catch
    {
      status("GPU llama.cpp failed, trying CPU…");
      await Unpack(
        "https://github.com/ggml-org/llama.cpp/releases/download/b10837/llama-b10837-bin-win-cpu-x64.zip",
        Path.Combine(Root, "llama"), "llama-mtmd-cli.exe");
    }
  }

  static async Task Unpack(string url, string dest, string requiredExe)
  {
    var tmp = Path.Combine(dest, "download.zip");
    await ModelStore.DownloadTo(url, tmp, 80_000_000, null);
    ZipFile.ExtractToDirectory(tmp, dest, overwriteFiles: true);
    File.Delete(tmp);
    if (FindExe(dest, requiredExe) is not { } found)
      throw new IOException($"Archive did not contain {requiredExe}");
    var target = Path.Combine(dest, requiredExe);
    if (!PathsEqual(found, target))
    {
      foreach (var f in Directory.GetFiles(Path.GetDirectoryName(found)!, "*.*"))
      {
        var name = Path.GetFileName(f);
        var to = Path.Combine(dest, name);
        if (!PathsEqual(f, to)) File.Copy(f, to, true);
      }
    }
    if (!File.Exists(Path.Combine(dest, requiredExe)))
      throw new IOException($"Could not place {requiredExe}");
  }

  static string? FindExe(string dir, string name) =>
    Directory.GetFiles(dir, name, SearchOption.AllDirectories).FirstOrDefault();

  static bool PathsEqual(string a, string b) =>
    string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase);
}

static class WaveFile
{
  public static string Write16k(float[] samples)
  {
    var path = Path.Combine(Path.GetTempPath(), $"scribe-{Guid.NewGuid():N}.wav");
    using var fs = File.Create(path);
    using var bw = new BinaryWriter(fs);
    int dataBytes = samples.Length * 2;
    bw.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
    bw.Write(36 + dataBytes);
    bw.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
    bw.Write(16);
    bw.Write((short)1);
    bw.Write((short)1);
    bw.Write(16000);
    bw.Write(16000 * 2);
    bw.Write((short)2);
    bw.Write((short)16);
    bw.Write(System.Text.Encoding.ASCII.GetBytes("data"));
    bw.Write(dataBytes);
    foreach (var s in samples)
    {
      float x = Math.Clamp(s, -1f, 1f);
      bw.Write((short)(x * 32767f));
    }
    return path;
  }
}

static class Proc
{
  public static string Run(string exe, string args, int timeoutMs)
  {
    var psi = new System.Diagnostics.ProcessStartInfo
    {
      FileName = exe,
      Arguments = args,
      WorkingDirectory = Path.GetDirectoryName(exe),
      RedirectStandardOutput = true,
      RedirectStandardError = true,
      UseShellExecute = false,
      CreateNoWindow = true,
    };
    using var p = System.Diagnostics.Process.Start(psi)
      ?? throw new IOException("Could not start " + exe);
    if (!p.WaitForExit(timeoutMs))
    {
      try { p.Kill(true); } catch { }
      throw new TimeoutException("Timed out: " + Path.GetFileName(exe));
    }
    var stdout = p.StandardOutput.ReadToEnd();
    var stderr = p.StandardError.ReadToEnd();
    if (p.ExitCode != 0 && string.IsNullOrWhiteSpace(stdout))
      throw new IOException(stderr.Length > 0 ? stderr[^Math.Min(400, stderr.Length)..] : "exit " + p.ExitCode);
    return stdout;
  }
}
