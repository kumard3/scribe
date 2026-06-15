using System.Runtime.InteropServices;

namespace Scribe;

/// Inserts text into the focused app via Ctrl+V, then restores whatever text
/// was on the clipboard before. Must be called on the UI (STA) thread.
static class Paster
{
  const byte VK_CONTROL = 0x11;
  const byte VK_V = 0x56;
  const uint KEYEVENTF_KEYUP = 0x0002;

  public static void Insert(string text)
  {
    if (string.IsNullOrEmpty(text)) return;

    string? savedText = null;
    try { if (Clipboard.ContainsText()) savedText = Clipboard.GetText(); } catch { }
    try { Clipboard.SetText(text); } catch { return; }

    keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
    keybd_event(VK_V, 0, 0, UIntPtr.Zero);
    keybd_event(VK_V, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);

    if (savedText == null) return;
    var t = new System.Windows.Forms.Timer { Interval = 1000 };
    t.Tick += (_, _) =>
    {
      t.Stop();
      t.Dispose();
      try { Clipboard.SetText(savedText); } catch { }
    };
    t.Start();
  }

  [DllImport("user32.dll")]
  static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
