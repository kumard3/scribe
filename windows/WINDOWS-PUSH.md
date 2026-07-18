# Windows Push: Audit and Order of Work

Audit date: 2026-07-18. Goal: "installable paid beta a stranger can run", positioned as
native + fully on-device + offline LLM cleanup quality, against Wispr Flow's Electron port
(above) and Handy's free verbatim OSS (below).

## 1. Current state inventory

12 C# files, ~1,900 lines, WinForms tray app, net8.0-windows, no external UI framework.
Dependencies: org.k2fsa.sherpa.onnx (1.*), NAudio 2.2.1, SharpCompress.

| Area | State |
|---|---|
| Architecture | `Program.cs` TrayApp (ApplicationContext) wires KeyHook, Dictation, Overlay, SettingsForm, Paster. Clean, small, native. |
| ASR engines | 13 sherpa-onnx models in `ModelCatalog.cs`: Zipformer streaming EN (default), Nemotron 3.5 streaming multi (40 lang) + Nemotron streaming EN, Moonshine tiny/base, Parakeet 110M/0.6B v2/v3, Canary 180M, Whisper tiny/small/turbo, Dolphin base (Hindi). Live models decode as you speak; offline models buffer (15 min cap) and transcribe on release. CPU only, greedy search, int8 preferred. |
| Hotkey/PTT | Low-level keyboard hook (`KeyHook.cs`). Hold = push-to-talk, quick tap (<0.4 s) = hands-free toggle. 6 presets (Right Ctrl default) plus "press any key" capture. Non-modifier hold keys are swallowed so they do not double-act. |
| Text injection | `Paster.cs`: set clipboard, synthesize Ctrl+V via deprecated `keybd_event`, restore previous clipboard text after a 1 s timer. Text only; images/files on the clipboard are lost. |
| Overlay | Bottom-center black pill on primary monitor: level bars, rolling partial text, "Inserted" flash, download/status messages. Click-through, no-activate. |
| AI cleanup | **Not present.** No llama.cpp, no Gemma, no post-processing of any kind. Mac has `LLMEngine.swift` (Gemma resident ~2.3 GB, cleanup prompt covers Hindi/Hinglish). Windows inserts raw ASR output. |
| Hindi/Hinglish | Partial. Whisper language pinning (25 langs incl. Hindi and 8 other Indic) and Dolphin for Hindi exist. **No Romanizer** (Mac `Romanizer.swift` converts Devanagari to Hinglish) and no Srota Hinglish gguf ASR model (Mac-only, qwenAsr kind not wired here). |
| Voice commands | Not present (Mac has `VoiceCommands.swift`). |
| Onboarding | `WelcomeForm` on first run: 3-step explainer + hold-key picker. No mic-permission check, no model pre-download step, no test dictation. |
| Settings | pureMono dashboard (`SettingsForm.cs`): hold key, hands-free toggle, model picker with download-on-select, Whisper language picker, launch-at-startup (HKCU Run key), transcript history (50 items, opt-out) with copy. Persisted to `%LOCALAPPDATA%\Scribe\settings.json`. |
| Tray UX | NotifyIcon with **stock `SystemIcons.Application` icon** (generic white window; reads as unfinished/malware for a paid product). Menu: status, start/stop, paste last, dashboard, startup, quit. No custom .ico anywhere in windows/. |
| Models storage | Download from k2-fsa GitHub releases to `%LOCALAPPDATA%\Scribe\models\<id>`, percent progress in overlay, extract via SharpCompress, failed dir cleaned up. No resume on interrupted download. |
| Installer/packaging | **None.** README documents `dotnet publish` only. Publish output is Scribe.exe (149 MB) **plus 7 loose native DLLs** (onnxruntime, sherpa-onnx-c-api, WPF/vcruntime libs, ~172 MB total). "Single file" does not bundle native libs, so a bare exe download does not work. No zip step, no Inno/MSIX/WiX, no build script (Mac has build.sh; Windows has nothing). |
| Auto-update | None. |
| Code signing | None. No cert, no signing step, no SmartScreen story. |
| Telemetry/licensing | None of either. No crash reporting, no log file, no license/payment mechanism. |
| Single instance | No mutex; launching twice gives two hooks and two tray icons. |
| Mic capture | NAudio `WaveInEvent` (legacy WinMM, not WASAPI) at 16 kHz/16-bit/mono. Default device only, no picker, no device-loss handling (`RecordingStopped` not subscribed). |

## 2. Build verification (2026-07-18, macOS cross-compile)

Both commands pass clean with `~/.dotnet/dotnet`:

```
dotnet build -c Release /p:EnableWindowsTargeting=true          -> 0 warnings, 0 errors
dotnet publish -c Release -r win-x64 --self-contained \
  -p:PublishSingleFile=true -p:EnableWindowsTargeting=true      -> Scribe.exe 149 MB + native DLLs
```

Compiles, but per repo history it has **never been executed on a real Windows machine**.
The entire runtime path (hook install, WinMM capture, sherpa native DLL load, overlay,
paste) is unverified.

## 3. Gap analysis vs the winning spec

Winning spec: native, fast, fully on-device, local LLM cleanup, strong on non-native
accents, cheap/one-time pricing. Already native, on-device, small footprint (~172 MB vs
Wispr's ~800 MB Electron), and multi-model accent coverage is genuinely good. The gaps:

| Gap | Class | Notes |
|---|---|---|
| Never run on Windows; zero end-to-end validation | **BLOCKER** | Cannot charge for software never executed on its target OS. Needs a machine or VM. |
| No installer / distributable artifact | **BLOCKER** | Publish output is exe + loose DLLs. A stranger has nothing to download and double-click. |
| Unsigned binary: SmartScreen "unknown publisher" wall + Defender reputation | **BLOCKER** | For a paid product the scary red screen kills conversion. Extra risk: LL keyboard hook + synthesized keystrokes + clipboard writes is exactly keylogger-shaped behavior for AV heuristics, and single-file self-extracting exes are a known Defender false-positive pattern. Cheapest path: Azure Trusted Signing (~$10/mo, individual/org verification). Classic OV cert $200-400/yr and requires HSM/token since 2023; EV (~$300-500/yr) buys instant SmartScreen reputation. |
| Stock Windows-default tray/app icon | **BLOCKER** (cheap) | Paid app with the generic icon reads as malware. `scripts/make-icons.mjs` assets exist; needs an .ico + `ApplicationIcon` + NotifyIcon wiring. |
| No local LLM cleanup on Windows | **IMPORTANT (strategic)** | This is the entire differentiation ("Wispr-quality output offline"). Without it, Windows Scribe is a verbatim tool competing with free Handy. Mac's `LLMEngine.swift` prompt + Gemma gguf port via llama.cpp prebuilt Windows binaries or LLamaSharp. Beta can technically ship verbatim-first, but pricing power depends on this. |
| No crash logging | IMPORTANT | Strangers will hit failures you cannot see. Minimum: log file in `%LOCALAPPDATA%\Scribe\logs` + top-level exception handler. |
| Paster fragility | IMPORTANT | `keybd_event` is deprecated (use `SendInput`); fixed 1 s clipboard restore can clobber a slow target app's paste; non-text clipboard content is destroyed; no fallback for apps where Ctrl+V is not paste (terminals). |
| Elevated/admin windows | IMPORTANT | A non-elevated process's LL hook receives no keys and cannot inject while an elevated window has focus. Dictation silently does nothing there. Needs at minimum detection + a visible "cannot type into admin windows" hint. |
| No single-instance mutex | IMPORTANT | Double-launch = duplicate hooks and tray icons. A few lines. |
| No auto-update | IMPORTANT | Paid beta will need fixes shipped fast. Velopack solves installer + delta updates together. |
| Mic capture robustness | IMPORTANT | Default device only; no device picker; unplugging the mic mid-take is unhandled; Windows privacy toggle (Settings > Privacy > Microphone) silently yields silence with no diagnostic. |
| Onboarding gaps | IMPORTANT | No mic permission/level check, no guided first dictation, model download happens after the welcome window closes with only the pill as feedback. |
| No Hinglish romanizer / Srota model | IMPORTANT | Accent/India story is half of the differentiation; Mac already has both. Romanizer is a mechanical port; Srota needs the qwen-asr runtime, so start with Romanizer + Dolphin/Whisper-hi. |
| No licensing/payment hook | IMPORTANT (decision) | Beta can sell via Gumroad/Dodo link + honor system, but decide before launch; retrofitting license checks post-purchase is messy. |
| Default model is Zipformer-2023 | LATER (S) | Oldest, weakest model as first impression. Nemotron streaming EN is the better default (punctuated, instant); 464 MB vs 366 MB download. |
| Overlay on primary monitor only | LATER | Multi-monitor users get the pill on the wrong screen. |
| No download resume | LATER | 370-640 MB downloads restart from zero on failure. |
| Voice commands, custom vocabulary, GPU (DirectML), win-arm64 (Snapdragon laptops), MSIX/Store, history search | LATER | Nice-to-haves; arm64 is worth a flag since new Windows laptops are increasingly ARM. |

## 4. Order of work to "installable paid beta"

| # | Item | Effort |
|---|---|---|
| 1 | Get a Windows machine/VM; run the app end to end; fix what breaks (hook, capture, sherpa DLL load, paste into Notepad/Word/Chrome/Slack/terminal/elevated) | M (gates everything) |
| 2 | App + tray .ico from existing brand assets; `ApplicationIcon` in csproj | S |
| 3 | Single-instance mutex; global exception handler + file logging | S |
| 4 | Paster hardening: `SendInput`, clipboard sequence-check before restore, preserve non-text clipboard or skip restore, elevated-window detection with visible hint | M |
| 5 | Installer + updates: Velopack (or Inno Setup + separate update check), per-user install, no admin required, Run-key startup preserved | M |
| 6 | Code signing: Azure Trusted Signing account + sign step in the build; submit installer to Microsoft for Defender false-positive pre-scan | M + ~$10/mo |
| 7 | Onboarding polish: mic check with live level, guided first dictation, model download inside the welcome flow; switch default model to Nemotron streaming EN | M |
| 8 | Local LLM cleanup: llama.cpp/LLamaSharp + Gemma gguf, port the Mac cleanup prompt, toggle in dashboard, lazy-load with RAM guard | L (the differentiator) |
| 9 | Hinglish: port `Romanizer.swift` to C#, wire to Dolphin/Whisper-hi output | M |
| 10 | Payment/licensing: checkout link + simple offline license key in settings | S-M |
| 11 | Mic device picker + device-loss handling; privacy-toggle diagnostic ("mic access is off in Windows Settings") | M |

Items 1-7 plus 10 make a sellable verbatim beta (roughly 1.5-2 focused weeks with
hardware in hand). Item 8 is what justifies charging against free Handy; with it,
roughly 3-4 weeks total to a beta that matches the market thesis.

## 5. Three highest-risk unknowns (need a real Windows machine)

1. **Does the pipeline run at all, and does injection work where users live?** Native
   sherpa/onnxruntime DLL load, WinMM 16 kHz capture, hook timing, and Ctrl+V paste into
   Word, Chrome, Electron apps (Slack/VS Code), Windows Terminal, UWP apps, and elevated
   windows. Zero of this has ever executed.
2. **Streaming ASR + resident Gemma on median consumer hardware.** Nemotron int8
   real-time factor and UI responsiveness on a typical 8 GB, non-AVX512 laptop, and
   whether a ~2-3 GB resident LLM alongside is viable there. This decides whether the
   "cleanup offline" thesis works for the mass market or only for 16 GB machines.
3. **Defender/SmartScreen verdict on the signed artifact.** Global keyboard hook +
   synthesized keystrokes + clipboard manipulation is behaviorally a keylogger; will
   Defender or SmartScreen flag the signed installer, and how long does reputation take
   to build on a fresh Trusted Signing identity?
