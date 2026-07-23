namespace Scribe;

/// First-run onboarding: what Scribe does, pick the hold key, done.
sealed class WelcomeForm : Form
{
  readonly ComboBox _holdKey = new()
  {
    DropDownStyle = ComboBoxStyle.DropDownList,
    Width = 200,
    FlatStyle = FlatStyle.Flat,
    BackColor = Mono.SurfaceAlt,
    ForeColor = Mono.Text,
  };

  public WelcomeForm(Action<Action<int>> armCapture)
  {
    Text = "Welcome to Scribe";
    Size = new Size(460, 480);
    BackColor = Mono.Bg;
    ForeColor = Mono.Text;
    Font = new Font("Segoe UI", 9.5f);
    StartPosition = FormStartPosition.CenterScreen;
    MaximizeBox = false;
    MinimizeBox = false;
    FormBorderStyle = FormBorderStyle.FixedSingle;
    TopMost = true;

    var layout = new FlowLayoutPanel
    {
      Dock = DockStyle.Fill,
      FlowDirection = FlowDirection.TopDown,
      WrapContents = false,
      Padding = new Padding(28),
      BackColor = Mono.Bg,
    };

    var logoRow = new FlowLayoutPanel { AutoSize = true, BackColor = Mono.Bg, Margin = new Padding(0, 0, 0, 4) };
    logoRow.Controls.Add(new LogoMark(56) { Margin = new Padding(0, 0, 0, 0) });
    layout.Controls.Add(logoRow);

    layout.Controls.Add(new Label
    {
      Text = "Welcome to Scribe",
      Font = new Font("Segoe UI", 16f, FontStyle.Bold),
      ForeColor = Mono.Text,
      AutoSize = true,
      Margin = new Padding(0, 8, 0, 2),
    });
    layout.Controls.Add(new Label
    {
      Text = "Hold a key, speak, release, your words land in any app.\nEverything is transcribed on this PC.",
      ForeColor = Mono.TextDim,
      AutoSize = true,
      Margin = new Padding(0, 0, 0, 14),
    });

    layout.Controls.Add(new Label
    {
      Text = "1 · The speech model downloads once on first use.\n" +
             "2 · Hold your key and talk; release to paste.\n" +
             "3 · Quick tap = hands-free mode, tap again to stop.",
      ForeColor = Mono.Text,
      AutoSize = true,
      Margin = new Padding(0, 0, 0, 16),
    });

    foreach (var (label, _) in Settings.HoldKeys) _holdKey.Items.Add(label);
    var idx = Array.FindIndex(Settings.HoldKeys, k => k.Vk == Settings.Instance.HoldKeyVk);
    _holdKey.SelectedIndex = idx >= 0 ? idx : 0;
    _holdKey.SelectedIndexChanged += (_, _) =>
    {
      if (_holdKey.SelectedIndex < Settings.HoldKeys.Length)
      {
        Settings.Instance.HoldKeyVk = Settings.HoldKeys[_holdKey.SelectedIndex].Vk;
        Settings.Instance.Save();
      }
    };

    var keyLabel = new Label
    {
      Text = "Hold-to-talk key:",
      ForeColor = Mono.Text,
      AutoSize = true,
      Margin = new Padding(0, 6, 8, 0),
    };
    var anyKey = new Button
    {
      Text = "Set any key…",
      AutoSize = true,
      FlatStyle = FlatStyle.Flat,
      BackColor = Mono.SurfaceAlt,
      ForeColor = Mono.Text,
    };
    anyKey.FlatAppearance.BorderColor = Mono.Border;
    anyKey.Click += (_, _) =>
    {
      anyKey.Text = "Press any key…";
      armCapture(vk => BeginInvoke(() =>
      {
        Settings.Instance.HoldKeyVk = vk;
        Settings.Instance.Save();
        anyKey.Text = $"Custom: {Settings.Instance.HoldKeyLabel}";
      }));
    };
    var keyRow = new FlowLayoutPanel { AutoSize = true, BackColor = Mono.Bg, Margin = new Padding(0, 0, 0, 18) };
    keyRow.Controls.Add(keyLabel);
    keyRow.Controls.Add(_holdKey);
    keyRow.Controls.Add(anyKey);
    layout.Controls.Add(keyRow);

    var start = new Button
    {
      Text = "Get started",
      AutoSize = true,
      FlatStyle = FlatStyle.Flat,
      BackColor = Color.White,
      ForeColor = Color.Black,
      Font = new Font("Segoe UI", 10f, FontStyle.Bold),
      Padding = new Padding(14, 4, 14, 4),
    };
    start.FlatAppearance.BorderSize = 0;
    start.Click += (_, _) =>
    {
      Settings.Instance.FirstRun = false;
      Settings.Instance.Save();
      Close();
    };
    layout.Controls.Add(start);

    Controls.Add(layout);
  }
}
