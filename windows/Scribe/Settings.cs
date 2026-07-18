using System.Globalization;
using System.Text.Json;

namespace Scribe;

sealed class Settings
{
  public int HoldKeyVk { get; set; } = 0xA3; // Right Ctrl
  public bool TapHandsFree { get; set; } = true;
  public string ModelId { get; set; } = "zipformer-streaming-en";
  public string Language { get; set; } = DefaultLanguage();
  public bool FirstRun { get; set; } = true;
  public bool SaveHistory { get; set; } = true;
  public List<string> History { get; set; } = new();

  public static readonly (string Label, string Code)[] Languages =
  {
    ("Auto-detect", "auto"),
    ("English", "en"),
    ("Hindi", "hi"),
    ("Spanish", "es"),
    ("French", "fr"),
    ("German", "de"),
    ("Portuguese", "pt"),
    ("Italian", "it"),
    ("Dutch", "nl"),
    ("Russian", "ru"),
    ("Arabic", "ar"),
    ("Turkish", "tr"),
    ("Indonesian", "id"),
    ("Chinese", "zh"),
    ("Japanese", "ja"),
    ("Korean", "ko"),
    ("Bengali", "bn"),
    ("Tamil", "ta"),
    ("Telugu", "te"),
    ("Marathi", "mr"),
    ("Gujarati", "gu"),
    ("Kannada", "kn"),
    ("Malayalam", "ml"),
    ("Punjabi", "pa"),
    ("Urdu", "ur"),
  };

  // Whisper's own language detection misfires on accented speech — it will read
  // accented English as Hindi/Urdu and emit garbage — so default to the OS language.
  static string DefaultLanguage()
  {
    var code = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
    return Languages.Any(l => l.Code == code) ? code : "auto";
  }

  public static readonly (string Label, int Vk)[] HoldKeys =
  {
    ("Right Ctrl", 0xA3),
    ("Right Alt", 0xA5),
    ("Caps Lock", 0x14),
    ("F8", 0x77),
    ("Scroll Lock", 0x91),
    ("Pause", 0x13),
  };

  // Non-modifier keys are swallowed by the hook so they don't also do their
  // normal action (e.g. Caps Lock toggling caps, a letter key typing).
  // Modifiers (Shift/Ctrl/Alt/Win) pass through — apps expect to see them.
  public static bool ShouldSwallow(int vk) =>
    vk is not (>= 0xA0 and <= 0xA5) and not (0x5B or 0x5C) and not (0x10 or 0x11 or 0x12);

  static string FilePath => Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Scribe", "settings.json");

  public static Settings Instance { get; } = Load();

  static Settings Load()
  {
    try
    {
      if (File.Exists(FilePath))
        return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings();
    }
    catch { }
    return new Settings();
  }

  public void Save()
  {
    try
    {
      Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
      File.WriteAllText(FilePath, JsonSerializer.Serialize(this));
    }
    catch { }
  }

  public void AddHistory(string text)
  {
    if (!SaveHistory) return;
    History.Insert(0, text);
    if (History.Count > 50) History.RemoveRange(50, History.Count - 50);
    Save();
  }

  public string HoldKeyLabel
  {
    get
    {
      var preset = HoldKeys.FirstOrDefault(k => k.Vk == HoldKeyVk);
      return preset.Label ?? ((Keys)HoldKeyVk).ToString();
    }
  }
}
