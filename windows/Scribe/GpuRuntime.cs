using System.Management;

namespace Scribe;

static class GpuRuntime
{
  public const string Auto = "auto";

  public static string Used { get; private set; } = "cpu";
  public static string Adapter { get; private set; } = "CPU";
  public static bool Nvidia { get; private set; }
  public static bool HasGpu { get; private set; }

  public static string StatusLine =>
    HasGpu ? $"{Adapter} · {Used}" : "CPU";

  public static void Probe()
  {
    HasGpu = false;
    Nvidia = false;
    Adapter = "CPU";
    try
    {
      using var searcher = new ManagementObjectSearcher(
        "SELECT Name, PNPDeviceID FROM Win32_VideoController");
      foreach (ManagementObject obj in searcher.Get())
      {
        var name = (obj["Name"] as string ?? "").Trim();
        var pnp = obj["PNPDeviceID"] as string ?? "";
        if (name.Length == 0) continue;
        if (name.Contains("Basic Display", StringComparison.OrdinalIgnoreCase) ||
            name.Contains("Basic Render", StringComparison.OrdinalIgnoreCase))
          continue;
        HasGpu = true;
        var nvidia = pnp.Contains("VEN_10DE", StringComparison.OrdinalIgnoreCase)
          || name.Contains("NVIDIA", StringComparison.OrdinalIgnoreCase);
        if (nvidia || Adapter == "CPU")
        {
          Adapter = name;
          Nvidia = nvidia;
        }
        if (nvidia) break;
      }
    }
    catch { }
  }

  public static string Resolve()
  {
    Probe();
    var pref = Settings.Instance.GpuProvider ?? Auto;
    if (pref is "cpu" or "cuda" or "directml") return pref;
    if (Nvidia && CudaDriverPresent()) return "cuda";
    if (HasGpu) return "directml";
    return "cpu";
  }

  public static void MarkUsed(string provider) => Used = provider;

  public static T Create<T>(Func<string, T> build)
  {
    var want = Resolve();
    try
    {
      var result = build(want);
      MarkUsed(want);
      return result;
    }
    catch when (want != "cpu")
    {
      var result = build("cpu");
      MarkUsed("cpu");
      return result;
    }
  }

  static bool CudaDriverPresent()
  {
    var sys = Environment.SystemDirectory;
    if (File.Exists(Path.Combine(sys, "nvcuda.dll"))) return true;
    var cuda = Environment.GetEnvironmentVariable("CUDA_PATH");
    return !string.IsNullOrEmpty(cuda)
      && File.Exists(Path.Combine(cuda, "bin", "nvcuda.dll"));
  }
}
