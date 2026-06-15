using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Scribe;

/// Low-level keyboard hook on the configured hold key: hold = push-to-talk,
/// tap = hands-free toggle (same semantics as fn on the Mac app).
sealed class KeyHook
{
  public Action? Press;
  public Action<TimeSpan>? Release;
  /// When set, the next keydown is delivered here (and swallowed) instead of
  /// being treated as the hold key — used by "press any key" capture.
  public Action<int>? CaptureNext;

  const int WH_KEYBOARD_LL = 13;
  const int WM_KEYDOWN = 0x0100;
  const int WM_KEYUP = 0x0101;
  const int WM_SYSKEYDOWN = 0x0104;
  const int WM_SYSKEYUP = 0x0105;

  delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

  IntPtr _hook = IntPtr.Zero;
  HookProc? _proc; // keep a reference so the delegate isn't GC'd
  DateTime? _downAt;

  public void Install()
  {
    if (_hook != IntPtr.Zero) return;
    _proc = Callback;
    using var process = Process.GetCurrentProcess();
    using var module = process.MainModule!;
    _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(module.ModuleName), 0);
  }

  public void Uninstall()
  {
    if (_hook == IntPtr.Zero) return;
    UnhookWindowsHookEx(_hook);
    _hook = IntPtr.Zero;
  }

  IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
  {
    if (nCode >= 0)
    {
      int vk = Marshal.ReadInt32(lParam);
      if (CaptureNext is Action<int> capture)
      {
        int m = (int)wParam;
        if (m == WM_KEYDOWN || m == WM_SYSKEYDOWN)
        {
          CaptureNext = null;
          capture(vk);
          return (IntPtr)1;
        }
      }
      else if (vk == Settings.Instance.HoldKeyVk)
      {
        int msg = (int)wParam;
        bool handled = false;
        if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN)
        {
          if (_downAt == null)
          {
            _downAt = DateTime.UtcNow;
            Press?.Invoke();
          }
          handled = true; // auto-repeat keydowns are swallowed too
        }
        else if ((msg == WM_KEYUP || msg == WM_SYSKEYUP) && _downAt is DateTime at)
        {
          _downAt = null;
          Release?.Invoke(DateTime.UtcNow - at);
          handled = true;
        }
        if (handled && Settings.ShouldSwallow(vk)) return (IntPtr)1;
      }
    }
    return CallNextHookEx(_hook, nCode, wParam, lParam);
  }

  [DllImport("user32.dll", SetLastError = true)]
  static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

  [DllImport("user32.dll", SetLastError = true)]
  static extern bool UnhookWindowsHookEx(IntPtr hhk);

  [DllImport("user32.dll")]
  static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

  [DllImport("kernel32.dll")]
  static extern IntPtr GetModuleHandle(string lpModuleName);
}
