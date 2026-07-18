// swift-tools-version:5.9
import PackageDescription

// libsherpa-onnx-c-api comes from the prebuilt release tarball that build.sh
// downloads into .deps — run build.sh (not bare `swift build`) for a fresh clone.
let sherpaLib = ".deps/sherpa-onnx-v1.13.3-osx-universal2-shared/lib"
// libllama / libggml are built from source by build.sh into .deps/llama/lib, and
// its headers copied into Sources/CLlama/vendor. The exact -l set can vary with
// the llama.cpp tag — adjust here if the first build reports a missing symbol.
let llamaLib = ".deps/llama/lib"

let package = Package(
  name: "Scribe",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "ObjCCatch", path: "Sources/ObjCCatch"),
    .target(name: "CSherpa", path: "Sources/CSherpa"),
    .target(
      name: "CLlama",
      path: "Sources/CLlama",
      cSettings: [.headerSearchPath("vendor")]
    ),
    .executableTarget(
      name: "Scribe",
      dependencies: ["ObjCCatch", "CSherpa", "CLlama"],
      path: "Sources/Scribe",
      linkerSettings: [
        .unsafeFlags([
          "-L", sherpaLib,
          "-lsherpa-onnx-c-api",
          "-L", llamaLib,
          "-lllama",
          "-lggml",
          "-lggml-base",
          "-lggml-cpu",
          "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        ])
      ]
    ),
  ]
)
