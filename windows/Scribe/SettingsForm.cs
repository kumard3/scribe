using System.Drawing.Drawing2D;

namespace Scribe;

// pureMono — same palette as the mobile app (src/ui/themes.ts)
static class Mono
{
  public static readonly Color Bg = Color.FromArgb(0, 0, 0);
  public static readonly Color Surface = Color.FromArgb(20, 20, 22);
  public static readonly Color SurfaceAlt = Color.FromArgb(28, 28, 31);
  public static readonly Color Border = Color.FromArgb(42, 42, 46);
  public static readonly Color Text = Color.White;
  public static readonly Color TextDim = Color.FromArgb(154, 154, 163);
  public static readonly Color TextFaint = Color.FromArgb(92, 92, 102);
}

/// The mobile app logo: three white waveform bars on a dark rounded square.
sealed class LogoMark : Panel
{
  public LogoMark(int size)
  {
    Size = new Size(size, size);
    BackColor = Mono.Bg;
  }

  protected override void OnPaint(PaintEventArgs e)
  {
    var g = e.Graphics;
    g.SmoothingMode = SmoothingMode.AntiAlias;
    int s = Width;

    using var bgPath = Rounded(new Rectangle(0, 0, s - 1, s - 1), (int)(s * 0.24));
    using (var b = new SolidBrush(Mono.SurfaceAlt)) g.FillPath(b, bgPath);
    using (var p = new Pen(Mono.Border)) g.DrawPath(p, bgPath);

    float w = s * 0.1f;
    float[] heights = { s * 0.3f, s * 0.52f, s * 0.38f };
    float gap = s * 0.1f;
    float totalW = 3 * w + 2 * gap;
    float x = (s - totalW) / 2;
    using var white = new SolidBrush(Color.White);
    foreach (var h in heights)
    {
      var r = new RectangleF(x, (s - h) / 2, w, h);
      using var bar = Rounded(Rectangle.Round(r), (int)(w / 2));
      g.FillPath(white, bar);
      x += w + gap;
    }
  }

  static GraphicsPath Rounded(Rectangle r, int radius)
  {
    int d = radius * 2;
    var path = new GraphicsPath();
    path.AddArc(r.Left, r.Top, d, d, 180, 90);
    path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
    path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
    path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
    path.CloseFigure();
    return path;
  }
}

sealed class SettingsForm : Form
{
  readonly ComboBox _holdKey = new()
  {
    DropDownStyle = ComboBoxStyle.DropDownList,
    Width = 220,
    FlatStyle = FlatStyle.Flat,
    BackColor = Mono.SurfaceAlt,
    ForeColor = Mono.Text,
  };
  readonly CheckBox _handsFree = new()
  {
    Text = "Quick tap starts hands-free mode (tap again to stop)",
    AutoSize = true,
    ForeColor = Mono.Text,
  };
  readonly CheckBox _startup = new()
  {
    Text = "Launch at startup",
    AutoSize = true,
    ForeColor = Mono.Text,
  };
  readonly CheckBox _saveHistory = new()
  {
    Text = "Save transcript history on this PC",
    AutoSize = true,
    ForeColor = Mono.Text,
  };
  readonly ListBox _history = new()
  {
    Dock = DockStyle.Fill,
    BorderStyle = BorderStyle.None,
    BackColor = Mono.Surface,
    ForeColor = Mono.Text,
    HorizontalScrollbar = true,
  };

  readonly ComboBox _model = new()
  {
    DropDownStyle = ComboBoxStyle.DropDownList,
    Width = 320,
    FlatStyle = FlatStyle.Flat,
    BackColor = Mono.SurfaceAlt,
    ForeColor = Mono.Text,
  };
  readonly Label _modelNote = new()
  {
    ForeColor = Mono.TextDim,
    Font = new Font("Segoe UI", 8.25f),
    AutoSize = true,
    Margin = new Padding(2, 0, 0, 8),
  };

  readonly Button _captureKey = new()
  {
    Text = "Set any key…",
    AutoSize = true,
    FlatStyle = FlatStyle.Flat,
    BackColor = Mono.SurfaceAlt,
    ForeColor = Mono.Text,
  };

  readonly Func<bool> _getStartup;
  readonly Action<bool> _setStartup;
  readonly Func<ModelSpec, Task> _switchModel;
  readonly Action<Action<int>> _armCapture;
  bool _syncing;

  public SettingsForm(
    Func<bool> getStartup, Action<bool> setStartup,
    Func<ModelSpec, Task> switchModel, Action<Action<int>> armCapture)
  {
    _getStartup = getStartup;
    _setStartup = setStartup;
    _switchModel = switchModel;
    _armCapture = armCapture;

    Text = "Scribe";
    Size = new Size(580, 660);
    BackColor = Mono.Bg;
    ForeColor = Mono.Text;
    Font = new Font("Segoe UI", 9.5f);
    StartPosition = FormStartPosition.CenterScreen;
    MaximizeBox = false;

    foreach (var (label, _) in Settings.HoldKeys) _holdKey.Items.Add(label);

    var layout = new FlowLayoutPanel
    {
      Dock = DockStyle.Fill,
      FlowDirection = FlowDirection.TopDown,
      WrapContents = false,
      AutoScroll = true,
      Padding = new Padding(24),
    };

    _captureKey.FlatAppearance.BorderColor = Mono.Border;
    _captureKey.Click += (_, _) =>
    {
      _captureKey.Text = "Press any key…";
      _armCapture(vk =>
      {
        BeginInvoke(() =>
        {
          Settings.Instance.HoldKeyVk = vk;
          Settings.Instance.Save();
          _captureKey.Text = "Set any key…";
          Sync();
        });
      });
    };

    var keyRow = Row("Hold to talk:", _holdKey);
    keyRow.Controls.Add(_captureKey);

    layout.Controls.Add(Header());
    layout.Controls.Add(Section("HOTKEY",
      keyRow,
      Note("Hold to speak, release to insert. Works in any app. “Set any key…” captures whatever key you press next."),
      _handsFree));
    layout.Controls.Add(Section("MODEL",
      Row("Speech model:", _model),
      _modelNote,
      Note("Everything runs on this PC. Models download once on first use — live ones show text as you speak, the rest transcribe when you release.")));
    layout.Controls.Add(Section("GENERAL", _startup));

    var copyBtn = new Button
    {
      Text = "Copy selected",
      AutoSize = true,
      FlatStyle = FlatStyle.Flat,
      BackColor = Mono.SurfaceAlt,
      ForeColor = Mono.Text,
    };
    copyBtn.FlatAppearance.BorderColor = Mono.Border;
    copyBtn.Click += (_, _) =>
    {
      if (_history.SelectedItem is string s && s.Length > 0) Clipboard.SetText(s);
    };
    var historyPanel = new Panel
    {
      Height = 200,
      Width = 480,
      BackColor = Mono.Surface,
      Padding = new Padding(8),
    };
    historyPanel.Controls.Add(_history);
    layout.Controls.Add(Section("RECENT TRANSCRIPTS", _saveHistory, historyPanel, copyBtn));

    Controls.Add(layout);

    foreach (var m in ModelCatalog.All) _model.Items.Add($"{m.Label}{(m.Live ? "  · LIVE" : "")}");

    Load += (_, _) => Sync();
    _holdKey.SelectedIndexChanged += (_, _) =>
    {
      if (_syncing || _holdKey.SelectedIndex >= Settings.HoldKeys.Length) return;
      Settings.Instance.HoldKeyVk = Settings.HoldKeys[_holdKey.SelectedIndex].Vk;
      Settings.Instance.Save();
    };
    _model.SelectedIndexChanged += async (_, _) =>
    {
      if (_syncing || _model.SelectedIndex < 0) return;
      var spec = ModelCatalog.All[_model.SelectedIndex];
      if (spec.Id == Settings.Instance.ModelId) return;
      Settings.Instance.ModelId = spec.Id;
      Settings.Instance.Save();
      UpdateModelNote(spec);
      try
      {
        await _switchModel(spec);
        UpdateModelNote(spec);
      }
      catch (Exception ex)
      {
        _modelNote.Text = "Model setup failed: " + ex.Message;
      }
    };
    _handsFree.CheckedChanged += (_, _) =>
    {
      Settings.Instance.TapHandsFree = _handsFree.Checked;
      Settings.Instance.Save();
    };
    _saveHistory.CheckedChanged += (_, _) =>
    {
      if (_syncing) return;
      Settings.Instance.SaveHistory = _saveHistory.Checked;
      Settings.Instance.Save();
    };
    _startup.CheckedChanged += (_, _) => _setStartup(_startup.Checked);

    FormClosing += (_, e) =>
    {
      if (e.CloseReason == CloseReason.UserClosing)
      {
        e.Cancel = true;
        Hide();
      }
    };
  }

  public void Sync()
  {
    _syncing = true;
    // presets + one trailing "Custom: X" slot when the current key isn't a preset
    while (_holdKey.Items.Count > Settings.HoldKeys.Length) _holdKey.Items.RemoveAt(_holdKey.Items.Count - 1);
    var idx = Array.FindIndex(Settings.HoldKeys, k => k.Vk == Settings.Instance.HoldKeyVk);
    if (idx < 0)
    {
      _holdKey.Items.Add($"Custom: {Settings.Instance.HoldKeyLabel}");
      idx = _holdKey.Items.Count - 1;
    }
    _holdKey.SelectedIndex = idx;
    _handsFree.Checked = Settings.Instance.TapHandsFree;
    _saveHistory.Checked = Settings.Instance.SaveHistory;
    _startup.Checked = _getStartup();
    var mIdx = Array.FindIndex(ModelCatalog.All, m => m.Id == Settings.Instance.ModelId);
    _model.SelectedIndex = mIdx >= 0 ? mIdx : 0;
    UpdateModelNote(ModelCatalog.All[_model.SelectedIndex]);
    _history.Items.Clear();
    foreach (var t in Settings.Instance.History) _history.Items.Add(t);
    _syncing = false;
  }

  void UpdateModelNote(ModelSpec spec) =>
    _modelNote.Text = ModelStore.IsInstalled(spec)
      ? $"{spec.Note} — downloaded."
      : $"{spec.Note} — downloads {spec.SizeLabel} on first use.";

  static Control Header()
  {
    var p = new FlowLayoutPanel
    {
      AutoSize = true,
      WrapContents = false,
      Margin = new Padding(0, 0, 0, 16),
      BackColor = Mono.Bg,
    };
    p.Controls.Add(new LogoMark(48) { Margin = new Padding(0, 2, 12, 0) });
    var text = new FlowLayoutPanel
    {
      FlowDirection = FlowDirection.TopDown,
      AutoSize = true,
      BackColor = Mono.Bg,
    };
    text.Controls.Add(new Label
    {
      Text = "Scribe",
      Font = new Font("Segoe UI", 17f, FontStyle.Bold),
      ForeColor = Mono.Text,
      AutoSize = true,
      Margin = new Padding(0),
    });
    text.Controls.Add(new Label
    {
      Text = "Your on-device transcriber",
      ForeColor = Mono.TextDim,
      AutoSize = true,
      Margin = new Padding(1, 0, 0, 0),
    });
    p.Controls.Add(text);
    return p;
  }

  static Control Section(string title, params Control[] children)
  {
    var outer = new FlowLayoutPanel
    {
      FlowDirection = FlowDirection.TopDown,
      AutoSize = true,
      WrapContents = false,
      Margin = new Padding(0, 0, 0, 16),
      BackColor = Mono.Bg,
    };
    outer.Controls.Add(new Label
    {
      Text = title,
      Font = new Font("Segoe UI", 8.5f, FontStyle.Bold),
      ForeColor = Mono.TextFaint,
      AutoSize = true,
      Margin = new Padding(2, 0, 0, 6),
    });
    var box = new FlowLayoutPanel
    {
      FlowDirection = FlowDirection.TopDown,
      AutoSize = true,
      WrapContents = false,
      BackColor = Mono.Surface,
      Padding = new Padding(14),
      Width = 500,
    };
    foreach (var c in children) box.Controls.Add(c);
    outer.Controls.Add(box);
    return outer;
  }

  static Control Row(string label, Control control)
  {
    var p = new FlowLayoutPanel
    {
      AutoSize = true,
      WrapContents = false,
      BackColor = Mono.Surface,
    };
    p.Controls.Add(new Label
    {
      Text = label,
      AutoSize = true,
      ForeColor = Mono.Text,
      Margin = new Padding(0, 6, 8, 0),
    });
    p.Controls.Add(control);
    return p;
  }

  static Control Note(string text) => new Label
  {
    Text = text,
    ForeColor = Mono.TextDim,
    Font = new Font("Segoe UI", 8.25f),
    AutoSize = true,
    Margin = new Padding(2, 0, 0, 8),
  };
}
