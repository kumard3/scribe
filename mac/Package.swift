// swift-tools-version:6.2
import PackageDescription

// libsherpa-onnx-c-api comes from the prebuilt release tarball that build.sh
// downloads into .deps, run build.sh (not bare `swift build`) for a fresh clone.
let sherpaLib = ".deps/sherpa-onnx-v1.13.3-osx-universal2-shared/lib"
// libllama / libggml are built from source by build.sh into .deps/llama/lib, and
// its headers copied into Sources/CLlama/vendor. The exact -l set can vary with
// the llama.cpp tag, adjust here if the first build reports a missing symbol.
let llamaLib = ".deps/llama/lib"

let package = Package(
  name: "Scribe",
  // FluidAudio (CoreML/ANE Parakeet) requires macOS 14; it runs in-process
  // alongside sherpa rather than replacing it, so the sherpa models are
  // untouched and the two can be compared on the same audio.
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.9.0"),
    // 3.31.4 strips Gemma 4 audio_tower. PR #392 (feat/gemma4-audio-encoder)
    // keeps the Conformer and wires ChatSession.respond(audios:).
    .package(
      url: "https://github.com/ml-explore/mlx-swift-lm",
      revision: "8c14b17a1eaa465606803c20e9907f968d8c0182",
      // Its FoundationModels adapter targets the 27 beta API and fails on the
      // Xcode 27.0 SDK; Scribe doesn't use it.
      traits: []
    ),
    .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
  ],
  targets: [
    .target(name: "ObjCCatch", path: "Sources/ObjCCatch"),
    .target(name: "CSherpa", path: "Sources/CSherpa"),
    // libonnxruntime already ships inside the app: sherpa-onnx links it and
    // build.sh copies it into Contents/Frameworks. CORT only adds the headers.
    .target(name: "CORT", path: "Sources/CORT"),
    .target(
      name: "CLlama",
      path: "Sources/CLlama",
      cSettings: [.headerSearchPath("vendor")]
    ),
    .executableTarget(
      name: "Scribe",
      dependencies: [
        "ObjCCatch", "CSherpa", "CLlama", "CORT",
        .product(name: "Sparkle", package: "Sparkle"),
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXVLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Tokenizers", package: "swift-transformers"),
      ],
      path: "Sources/Scribe",
      swiftSettings: [
        .swiftLanguageMode(.v5),
      ],
      linkerSettings: [
        .unsafeFlags([
          "-L", sherpaLib,
          "-lsherpa-onnx-c-api",
          "-lonnxruntime",
          "-L", llamaLib,
          "-lllama",
          "-lmtmd",
          "-lggml",
          "-lggml-base",
          "-lggml-cpu",
          "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
          // FoundationModels only exists on macOS 26+; the app still launches on 14.
          "-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels",
        ])
      ]
    ),
  ]
)
