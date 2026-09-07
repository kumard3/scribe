using System.Globalization;
using System.Text;

namespace Scribe;

static class Romanizer
{
  static readonly HashSet<string> DevanagariLangs = new() { "hi", "mr" };
  static readonly HashSet<char> Vowels = new("aeiouāēīōū");

  public static bool WantsLatinOnly =>
    Settings.Instance.RomanizeHindi
    || (Settings.Instance.Language != "auto"
        && !DevanagariLangs.Contains(Settings.Instance.Language));

  public static bool HasDevanagari(string s)
  {
    foreach (var c in s)
      if (c is >= '\u0900' and <= '\u097F') return true;
    return false;
  }

  public static string NormalizeScript(string s) => WantsLatinOnly ? Mixed(s) : s;

  public static string Mixed(string s)
  {
    if (!HasDevanagari(s)) return s;
    var parts = s.Split(' ');
    for (int i = 0; i < parts.Length; i++)
      if (HasDevanagari(parts[i])) parts[i] = Hinglish(parts[i]);
    return string.Join(' ', parts);
  }

  public static string Hinglish(string s)
  {
    if (s.Length == 0) return s;
    var latin = Transliterate(s);
    latin = latin.Replace("m\u0310", "n").Replace("ṁ", "n").Replace("ṃ", "n")
      .Replace("ṅ", "n").Replace("ñ", "n").Replace("\u0310", "n");
    foreach (var a in new[] { "'", "\u2019", "\u02BC" })
      latin = latin.Replace(a, "");

    var words = latin.Split(' ');
    for (int w = 0; w < words.Length; w++)
    {
      var chars = words[w].Normalize(NormalizationForm.FormC).ToCharArray().ToList();
      var glided = new List<char>();
      for (int idx = 0; idx < chars.Count; idx++)
      {
        glided.Add(chars[idx]);
        if (idx + 1 < chars.Count
            && "iīāa".Contains(chars[idx])
            && "eēāa".Contains(chars[idx + 1])
            && chars[idx] != chars[idx + 1])
          glided.Add('y');
      }
      chars = glided;
      if (chars.Count >= 3 && chars[^1] == 'a' && !Vowels.Contains(chars[^2]))
        chars.RemoveAt(chars.Count - 1);
      int firstVowel = chars.FindIndex(Vowels.Contains);
      for (int i = chars.Count - 2; i > 0; i--)
      {
        if (chars[i] == 'a' && firstVowel >= 0 && i > firstVowel
            && !Vowels.Contains(chars[i - 1])
            && i + 1 < chars.Count && !Vowels.Contains(chars[i + 1])
            && i + 2 < chars.Count && Vowels.Contains(chars[i + 2]))
          chars.RemoveAt(i);
      }
      words[w] = new string(chars.ToArray());
    }
    return StripDiacritics(string.Join(' ', words));
  }

  static string StripDiacritics(string s)
  {
    var formD = s.Normalize(NormalizationForm.FormD);
    var sb = new StringBuilder(formD.Length);
    foreach (var c in formD)
      if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark)
        sb.Append(c);
    return sb.ToString().Normalize(NormalizationForm.FormC);
  }

  static readonly Dictionary<char, string> Independent = new()
  {
    ['अ'] = "a", ['आ'] = "aa", ['इ'] = "i", ['ई'] = "ii", ['उ'] = "u", ['ऊ'] = "uu",
    ['ऋ'] = "ri", ['ए'] = "e", ['ऐ'] = "ai", ['ओ'] = "o", ['औ'] = "au",
  };

  static readonly Dictionary<char, string> Consonant = new()
  {
    ['क'] = "k", ['ख'] = "kh", ['ग'] = "g", ['घ'] = "gh", ['ङ'] = "n",
    ['च'] = "ch", ['छ'] = "chh", ['ज'] = "j", ['झ'] = "jh", ['ञ'] = "n",
    ['ट'] = "t", ['ठ'] = "th", ['ड'] = "d", ['ढ'] = "dh", ['ण'] = "n",
    ['त'] = "t", ['थ'] = "th", ['द'] = "d", ['ध'] = "dh", ['न'] = "n",
    ['प'] = "p", ['फ'] = "ph", ['ब'] = "b", ['भ'] = "bh", ['म'] = "m",
    ['य'] = "y", ['र'] = "r", ['ल'] = "l", ['व'] = "v",
    ['श'] = "sh", ['ष'] = "sh", ['स'] = "s", ['ह'] = "h",
  };

  static readonly Dictionary<char, string> Matra = new()
  {
    ['ा'] = "aa", ['ि'] = "i", ['ी'] = "ii", ['ु'] = "u", ['ू'] = "uu",
    ['ृ'] = "ri", ['े'] = "e", ['ै'] = "ai", ['ो'] = "o", ['ौ'] = "au",
    ['ं'] = "n", ['ँ'] = "n", ['ः'] = "h",
  };

  static string Transliterate(string s)
  {
    var sb = new StringBuilder();
    for (int i = 0; i < s.Length; i++)
    {
      char c = s[i];
      if (Independent.TryGetValue(c, out var iv)) { sb.Append(iv); continue; }
      if (Consonant.TryGetValue(c, out var cons))
      {
        sb.Append(cons);
        if (i + 1 < s.Length)
        {
          char n = s[i + 1];
          if (n == '्') { i++; continue; }
          if (Matra.TryGetValue(n, out var m)) { sb.Append(m); i++; continue; }
        }
        sb.Append('a');
        continue;
      }
      if (Matra.TryGetValue(c, out var matra)) { sb.Append(matra); continue; }
      if (c == '्') continue;
      sb.Append(c);
    }
    return sb.ToString();
  }
}
