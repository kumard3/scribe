// swift-tools-version:5.9
import PackageDescription

// libsherpa-onnx-c-api comes from the prebuilt release tarball that build.sh
// downloads into .deps — run build.sh (not bare `swift build`) for a fresh clone.
let sherpaLib = ".deps/sherpa-onnx-v1.13.2-osx-universal2-shared/lib"

let package = Package(
  name: "Scribe",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "ObjCCatch", path: "Sources/ObjCCatch"),
    .target(name: "CSherpa", path: "Sources/CSherpa"),
    .executableTarget(
      name: "Scribe",
      dependencies: ["ObjCCatch", "CSherpa"],
      path: "Sources/Scribe",
      linkerSettings: [
        .unsafeFlags([
          "-L", sherpaLib,
          "-lsherpa-onnx-c-api",
          "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        ])
      ]
    ),
  ]
)
