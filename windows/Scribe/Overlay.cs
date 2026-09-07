using System.Drawing.Drawing2D;

namespace Scribe;

/// Bottom-center black pill (matches the Mac HUD): live level bars + rolling
/// partial text while listening, then a brief "Inserted" confirmation.
sealed class Overlay : Form
{
  enum Mode { Hidden, Listening, Inserted, Status }

  Mode _mode = Mode.Hidden;
  float _level;
  string _text = "";
  readonly System.Windows.Forms.Timer _hideTimer = new();

  public Overlay()
  {
    FormBorderStyle = FormBorderStyle.None;
    ShowInTaskbar = false;
    TopMost = true;
    StartPosition = FormStartPosition.Manual;
    BackColor = Color.FromArgb(20, 20, 20);
    Size = new Size(520, 48);
    DoubleBuffered = true;
    _hideTimer.Tick += (_, _) =>
    {
      _hideTimer.Stop();
      if (_mode != Mode.Listening) HideCore();
    };
  }

  protected override bool ShowWithoutActivation => true;

  protected override CreateParams CreateParams
  {
    get
    {
      var p = base.CreateParams;
      // WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT
      p.ExStyle |= 0x8 | 0x80 | 0x08000000 | 0x20;
      return p;
    }
  }

  public void SetListening() => BeginInvoke(() =>
  {
    _mode = Mode.Listening;
    _text = "";
    _level = 0;
    ShowCore();
  });

  public void UpdatePartial(string text, float level)
  {
    if (!IsHandleCreated) return;
    BeginInvoke(() =>
    {
      if (_mode != Mode.Listening) return;
      _text = text;
      _level = level;
      Invalidate();
    });
  }

  public void ShowInserted() => BeginInvoke(() =>
  {
    _mode = Mode.Inserted;
    ShowCore();
    Invalidate();
    _hideTimer.Interval = 900;
    _hideTimer.Stop();
    _hideTimer.Start();
  });

  public void ShowStatus(string text, int autoHideSeconds = 0)
  {
    if (!IsHandleCreated) return;
    BeginInvoke(() =>
    {
      _mode = Mode.Status;
      _text = text;
      ShowCore();
      Invalidate();
      if (autoHideSeconds > 0)
      {
        _hideTimer.Interval = autoHideSeconds * 1000;
        _hideTimer.Stop();
        _hideTimer.Start();
      }
    });
  }

  public void HideOverlay() => BeginInvoke(HideCore);

  void ShowCore()
  {
    var screen = Screen.PrimaryScreen!.WorkingArea;
    Location = new Point(screen.Left + (screen.Width - Width) / 2, screen.Bottom - Height - 28);
    using var path = Pill(ClientRectangle);
    Region = new Region(path);
    if (!Visible) Show();
  }

  void HideCore()
  {
    _mode = Mode.Hidden;
    Hide();
  }

  protected override void OnPaint(PaintEventArgs e)
  {
    var g = e.Graphics;
    g.SmoothingMode = SmoothingMode.AntiAlias;
    g.Clear(Color.FromArgb(20, 20, 20));

    using var font = new Font("Segoe UI", 10.5f, FontStyle.Regular);
    using var white = new SolidBrush(Color.White);
    using var fmt = new StringFormat
    {
      LineAlignment = StringAlignment.Center,
      Trimming = StringTrimming.EllipsisCharacter,
      FormatFlags = StringFormatFlags.NoWrap,
    };

    if (_mode == Mode.Inserted)
    {
      using var green = new SolidBrush(Color.FromArgb(52, 199, 89));
      g.FillEllipse(green, 22, Height / 2 - 7, 14, 14);
      g.DrawString("Inserted", font, white, new RectangleF(46, 0, Width - 60, Height), fmt);
      return;
    }

    if (_mode == Mode.Status)
    {
      fmt.Alignment = StringAlignment.Center;
      g.DrawString(_text, font, white, new RectangleF(16, 0, Width - 32, Height), fmt);
      return;
    }

    float[] weights = { 0.45f, 0.75f, 1f, 0.75f, 0.45f };
    float cx = 26;
    for (int i = 0; i < weights.Length; i++)
    {
      float h = 5 + Math.Clamp(_level, 0, 1) * 22 * weights[i];
      var bar = new RectangleF(cx, Height / 2f - h / 2f, 3.5f, h);
      using var path = Pill(Rectangle.Round(bar));
      g.FillPath(white, path);
      cx += 7;
    }

    var display = _text.Length == 0 ? "Listening…" : _text;
    if (display.Length > 64) display = "…" + display[^64..];
    g.DrawString(display, font, white, new RectangleF(72, 0, Width - 92, Height), fmt);
  }

  static GraphicsPath Pill(Rectangle r)
  {
    int d = Math.Min(r.Height, r.Width);
    var path = new GraphicsPath();
    path.AddArc(r.Left, r.Top, d, d, 90, 180);
    path.AddArc(r.Right - d, r.Top, d, d, 270, 180);
    path.CloseFigure();
    return path;
  }
}
