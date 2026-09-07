# Scribe for Windows

Dedicated Windows app. Do not build this from `mac/`. Mac is Swift + MLX/Metal
in `mac/`; this folder is C# WinForms + sherpa-onnx and has its own CI
(`.github/workflows/build-windows.yml`).

Same product shape as Mac (hold a key, speak, release, text lands in the
focused app), different engine and different binary.

100% offline. Processor is auto-detected: NVIDIA CUDA if the driver is present,
otherwise DirectML on AMD/Intel/NVIDIA, otherwise CPU. The dashboard
**Processor** row can override this. The NuGet `org.k2fsa.sherpa.onnx` package
is still CPU-built ([k2-fsa/sherpa-onnx#3717](https://github.com/k2-fsa/sherpa-onnx/issues/3717));
setting `provider` to `cuda` or `directml` only *runs* on GPU when GPU-enabled
sherpa/onnxruntime native libs sit next to the exe (CUDA tarball from
[sherpa-onnx releases](https://github.com/k2-fsa/sherpa-onnx/releases), or a
DirectML build with `-DSHERPA_ONNX_ENABLE_DIRECTML=ON`). Without those libs it
falls back to CPU.

## How it works

- **Hold Right Ctrl** (configurable), push-to-talk: record while held,
  release to insert.
- **Tap Right Ctrl**, hands-free: keeps recording until the next tap
  (can be turned off in the dashboard).
- A black pill at the bottom of the screen shows live levels + partial text,
  then "Inserted" when the text lands.
- Inserting uses Ctrl+V but **restores your previous clipboard** afterwards.
- **Dashboard** (tray icon double-click or menu): pureMono black UI matching
  the mobile app, change the hold key (Right Ctrl / Right Alt / Caps Lock /
  F8 / Scroll Lock / Pause), hands-free toggle, launch at startup, and a
  recent-transcripts list. Settings persist in
  `%LOCALAPPDATA%\Scribe\settings.json`.
- First launch downloads the speech model once (~370 MB) to
  `%LOCALAPPDATA%\Scribe\models`, the pill shows progress.

## Build (on Windows)

Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).

```powershell
cd windows\Scribe
dotnet run -c Release            # build + run
# or produce a standalone exe:
dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true
# → bin\Release\net8.0-windows\win-x64\publish\Scribe.exe
```

The project cross-compiles on macOS/Linux for CI-style checks with
`dotnet build /p:EnableWindowsTargeting=true`, but it can only *run* on
Windows (WinForms + the sherpa-onnx native runtime).

## Notes

- The streaming API follows the official sherpa-onnx `dotnet-examples`
  (speech-recognition-from-microphone): `OnlineRecognizer` + `AcceptWaveform`
  / `IsReady` / `Decode` / `GetResult` / `IsEndpoint` / `Reset`.
  `ModelConfig.Provider` is `cpu`, `cuda`, or `directml` (C++ enum in
  `csrc/provider.h`; C# help text still says cpu/coreml).
- GPU detection: WMI `Win32_VideoController` + `nvcuda.dll`. CUDA is NVIDIA
  only and needs the matching toolkit if you swap in the CUDA native build.
  DirectML is the cross-vendor Windows GPU path.
- No audio or text ever leaves the machine.
- Gemma 4 E2B, Oriserve Swift/Apex, and Whisper Turbo are **Windows-native**
  (whisper.cpp + llama.cpp). MLX is Mac only. Hinglish toggle uses the same
  prompt as Mac plus a C# Devanagari romanizer. Processor auto-picks CUDA
  (NVIDIA), Vulkan (other GPU) for llama.cpp, or CPU.
