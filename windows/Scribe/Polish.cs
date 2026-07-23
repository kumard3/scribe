using System.Text.RegularExpressions;

namespace Scribe;

static class Polish
{
  const RegexOptions I = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;

  static readonly Regex Fillers =
    new(@"\b(um+|uh+|erm+|uhh+|hmm+|mm+hmm|y'?know)\b", I);

  static readonly (Regex Re, string Sym)[] Commands =
  {
    (new(@"\b(new paragraph|next paragraph)\b", I), "\n\n"),
    (new(@"\b(new line|next line)\b", I), "\n"),
    (new(@"\b(bullet point|new bullet|bullet)\b", I), "\n• "),
    (new(@"\b(numbered list|number list)\b", I), "\n1. "),
    (new(@"\b(open paren|open parenthesis)\b", I), "("),
    (new(@"\b(close paren|close parenthesis)\b", I), ")"),
    (new(@"\b(open quote|quote)\b", I), "“"),
    (new(@"\b(close quote|unquote|end quote)\b", I), "”"),
    (new(@"\b(exclamation mark|exclamation point)\b", I), "!"),
    (new(@"\b(question mark)\b", I), "?"),
    (new(@"\b(full stop|period)\b", I), "."),
    (new(@"\b(comma)\b", I), ","),
    (new(@"\b(colon)\b", I), ":"),
    (new(@"\b(semicolon)\b", I), ";"),
    (new(@"\b(hyphen|dash)\b", I), "-"),
    (new(@"\b(smiley face|smiley)\b", I), ":)"),
  };

  static string ApplyCommands(string text)
  {
    foreach (var (re, sym) in Commands) text = re.Replace(text, sym);
    return text;
  }

  static readonly Regex Scratch =
    new(@"[^.!?\n]*\b(?:scratch|strike|delete|cross)\s+that\b[.,!?]*", I);
  static readonly Regex LastWord =
    new(@"(?:\S+)\s+\b(?:scratch|delete|cross)\s+(?:the\s+)?last word\b[.,!?]*", I);
  static readonly Regex LastLine =
    new(@"\b(?:scratch|delete|cross)\s+(?:this |the |that )?last line\b[.,!?]*", I);

  // Destructive: apply to live dictation only, never imported recordings.
  public static string ApplyVoiceCommands(string text)
  {
    var t = LastWord.Replace(Scratch.Replace(text, ""), "");
    if (LastLine.IsMatch(t))
    {
      var outLines = new List<string>();
      foreach (var line in t.Split('\n'))
      {
        var m = LastLine.Match(line);
        if (m.Success)
        {
          var before = line[..m.Index].Trim();
          if (before.Length == 0 && outLines.Count > 0) outLines.RemoveAt(outLines.Count - 1);
          continue;
        }
        outLines.Add(line);
      }
      t = string.Join("\n", outLines);
    }
    return t;
  }

  static readonly Regex NoSpaceBeforePunct = new(@"[ \t]+([,.!?;:])");
  static readonly Regex SpaceAfterPunct = new(@"([,.!?;:])(?=[^\s\n])");
  static readonly Regex CollapseSpaces = new(@"[ \t]{2,}");
  static readonly Regex TrimNewlines = new(@"[ \t]*\n[ \t]*");
  static readonly Regex TooManyNewlines = new(@"\n{3,}");
  static readonly Regex SentenceStart = new(@"(^|[.!?]\s+|\n)([a-z])");
  static readonly Regex StandaloneI = new(@"\bi\b");

  static string Tidy(string text)
  {
    var t = NoSpaceBeforePunct.Replace(text, "$1");
    t = SpaceAfterPunct.Replace(t, "$1 ");
    t = CollapseSpaces.Replace(t, " ");
    t = TrimNewlines.Replace(t, "\n");
    t = TooManyNewlines.Replace(t, "\n\n");
    t = t.Trim();
    t = SentenceStart.Replace(t, m => m.Groups[1].Value + char.ToUpperInvariant(m.Groups[2].Value[0]));
    t = StandaloneI.Replace(t, "I");
    return t;
  }

  public static string Format(string text)
  {
    if (string.IsNullOrWhiteSpace(text)) return text;
    return Tidy(Fillers.Replace(ApplyCommands(text), " "));
  }
}
