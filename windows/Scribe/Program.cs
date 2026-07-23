using Microsoft.Win32;

namespace Scribe;

static class Program
{
  [STAThread]
  static void Main()
  {
    ApplicationConfiguration.Initialize();
    Application.Run(new TrayApp());
  }
}

sealed class TrayApp : ApplicationContext
{
  const string AppName = "Scribe";
  const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

  readonly NotifyIcon _tray;
  readonly Overlay _overlay = new();
  readonly Dictation _dictation;
  readonly KeyHook _hook = new();
  readonly SettingsForm _settingsForm;
  readonly ToolStripMenuItem _statusItem = new("Loading model…") { Enabled = false };
  readonly ToolStripMenuItem _toggleItem = new("Start dictation");
  readonly ToolStripMenuItem _pasteLastItem = new("Paste last transcript") { Enabled = false };
  readonly ToolStripMenuItem _startupItem = new("Launch at startup") { CheckOnClick = true };

  bool _stoppedOnPress;
  string _lastText = "";

  public TrayApp()
  {
    var _ = _overlay.Handle; // create handle on UI thread so BeginInvoke works
    _settingsForm = new SettingsForm(
      IsStartupEnabled, SetStartup, SwitchModelAsync, cb => _hook.CaptureNext = cb);

    _dictation = new Dictation(_overlay);
    _dictation.Finished += raw =>
    {
      if (raw.Length == 0) return;
      Task.Run(() =>
      {
        var spec = ModelCatalog.Get(Settings.Instance.ModelId);
        var text = Polish.ApplyVoiceCommands(raw);
        if (!spec.Punctuated) text = Punctuation.Apply(text, s => _overlay.ShowStatus(s));
        text = Polish.Format(text);
        if (text.Length == 0) return;
        _overlay.BeginInvoke(() =>
        {
          _lastText = text;
          _pasteLastItem.Enabled = true;
          _pasteLastItem.ToolTipText = text.Length > 80 ? text[..80] + "…" : text;
          Settings.Instance.AddHistory(text);
          if (_settingsForm.Visible) _settingsForm.Sync();
          Paster.Insert(text);
        });
      });
    };
    _dictation.StateChanged += recording => _overlay.BeginInvoke(() =>
      _toggleItem.Text = recording ? "Stop dictation" : "Start dictation");

    _toggleItem.Click += (_, _) => _dictation.Toggle();
    _pasteLastItem.Click += (_, _) => Paster.Insert(_lastText);
    _startupItem.Checked = IsStartupEnabled();
    _startupItem.CheckedChanged += (_, _) => SetStartup(_startupItem.Checked);

    var dashboard = new ToolStripMenuItem("Dashboard…");
    dashboard.Click += (_, _) => ShowDashboard();

    var importItem = new ToolStripMenuItem("Transcribe audio file…");
    importItem.Click += (_, _) => ImportAudioFile();

    var menu = new ContextMenuStrip();
    menu.Items.Add(_statusItem);
    menu.Items.Add(new ToolStripSeparator());
    menu.Items.Add(_toggleItem);
    menu.Items.Add(_pasteLastItem);
    menu.Items.Add(importItem);
    menu.Items.Add(dashboard);
    menu.Items.Add(_startupItem);
    menu.Items.Add(new ToolStripSeparator());
    var quit = new ToolStripMenuItem("Quit Scribe");
    quit.Click += (_, _) => Quit();
    menu.Items.Add(quit);

    _tray = new NotifyIcon
    {
      Icon = SystemIcons.Application,
      Visible = true,
      Text = $"Scribe, hold {Settings.Instance.HoldKeyLabel} to dictate",
      ContextMenuStrip = menu,
    };
    _tray.DoubleClick += (_, _) => ShowDashboard();

    _hook.Press = () =>
    {
      if (!_dictation.Ready) return;
      if (_dictation.IsRecording)
      {
        _dictation.Stop();
        _stoppedOnPress = true;
      }
      else
      {
        _dictation.Start();
        _stoppedOnPress = false;
      }
    };
    _hook.Release = held =>
    {
      if (_stoppedOnPress) return;
      // held = push-to-talk; quick tap = hands-free (if enabled in dashboard)
      if (held.TotalSeconds >= 0.4 || !Settings.Instance.TapHandsFree) _dictation.Stop();
    };
    _hook.Install();

    if (Settings.Instance.FirstRun)
    {
      new WelcomeForm(cb => _hook.CaptureNext = cb).Show();
    }

    Task.Run(async () =>
    {
      try
      {
        await _dictation.PrepareAsync();
        _overlay.BeginInvoke(() =>
          _statusItem.Text = $"Ready, hold {Settings.Instance.HoldKeyLabel} to dictate");
      }
      catch (Exception ex)
      {
        _overlay.BeginInvoke(() =>
        {
          _statusItem.Text = "Model setup failed, click to retry";
          _statusItem.Enabled = true;
          _statusItem.Click += (_, _) => Application.Restart();
          _overlay.ShowStatus("Model setup failed: " + ex.Message, autoHideSeconds: 6);
        });
      }
    });
  }

  void ShowDashboard()
  {
    _settingsForm.Sync();
    _settingsForm.Show();
    _settingsForm.Activate();
  }

  void ImportAudioFile()
  {
    if (!_dictation.Ready) return;
    using var dlg = new OpenFileDialog
    {
      Title = "Transcribe audio file",
      Filter = "Audio files|*.mp3;*.m4a;*.wav;*.aac|All files|*.*",
    };
    if (dlg.ShowDialog() != DialogResult.OK) return;
    var path = dlg.FileName;

    _overlay.ShowStatus("Reading audio file…");
    Task.Run(async () =>
    {
      try
      {
        var samples = AudioFile.Decode16kMono(path);
        if (samples.Length == 0)
        {
          _overlay.ShowStatus("Could not read that audio file.", 5);
          return;
        }
        _overlay.ShowStatus("Transcribing…");
        var text = await _dictation.TranscribeSamplesAsync(samples);
        if (text.Trim().Length == 0)
        {
          _overlay.ShowStatus("No speech found in that file.", 5);
          return;
        }

        var spec = ModelCatalog.Get(Settings.Instance.ModelId);
        if (!spec.Punctuated)
        {
          try
          {
            await Punctuation.EnsureAsync(s => _overlay.ShowStatus(s));
            text = Punctuation.Apply(text, s => _overlay.ShowStatus(s));
          }
          catch { }
        }

        if (Settings.Instance.DiarizeImport)
        {
          try
          {
            _overlay.ShowStatus("Identifying speakers…");
            await Diarization.EnsureAsync(s => _overlay.ShowStatus(s));
            text = Diarization.Compose(text, samples, Settings.Instance.DiarizeSpeakers);
          }
          catch { }
        }

        var final = text;
        _overlay.BeginInvoke(() =>
        {
          _lastText = final;
          _pasteLastItem.Enabled = true;
          _pasteLastItem.ToolTipText = final.Length > 80 ? final[..80] + "…" : final;
          Settings.Instance.AddHistory(final);
          if (_settingsForm.Visible) _settingsForm.Sync();
          try { Clipboard.SetText(final); } catch { }
          _overlay.ShowStatus("Transcript copied to clipboard", 4);
        });
      }
      catch (Exception ex)
      {
        _overlay.ShowStatus("Audio import failed: " + ex.Message, 6);
      }
    });
  }

  async Task SwitchModelAsync(ModelSpec spec)
  {
    _overlay.BeginInvoke(() => _statusItem.Text = $"Switching to {spec.Label}…");
    try
    {
      await _dictation.SwitchAsync(spec);
      _overlay.BeginInvoke(() =>
        _statusItem.Text = $"Ready, hold {Settings.Instance.HoldKeyLabel} to dictate");
    }
    catch
    {
      _overlay.BeginInvoke(() => _statusItem.Text = "Model setup failed, pick another model");
      throw;
    }
  }

  bool IsStartupEnabled()
  {
    using var key = Registry.CurrentUser.OpenSubKey(RunKey);
    return key?.GetValue(AppName) != null;
  }

  void SetStartup(bool on)
  {
    using var key = Registry.CurrentUser.CreateSubKey(RunKey);
    if (on) key.SetValue(AppName, $"\"{Application.ExecutablePath}\"");
    else key.DeleteValue(AppName, throwOnMissingValue: false);
  }

  void Quit()
  {
    _hook.Uninstall();
    _dictation.Dispose();
    _tray.Visible = false;
    _tray.Dispose();
    Application.Exit();
  }
}
