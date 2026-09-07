import Foundation
import CORT

/// Minimal Swift wrapper over the ONNX Runtime C API. The dylib already ships
/// with the app: sherpa-onnx links it, and build.sh copies libonnxruntime*.dylib
/// into Contents/Frameworks.
enum Ort {
  final class Env {
    static let shared = Env()
    let ptr: OpaquePointer?
    private init() {
      var p: OpaquePointer?
      _ = api.pointee.CreateEnv(ORT_LOGGING_LEVEL_ERROR, "scribe", &p)
      ptr = p
    }
  }

  static let api: UnsafePointer<OrtApi> = {
    guard let base = OrtGetApiBase(), let a = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
      fatalError("ONNX Runtime C API unavailable")
    }
    return a
  }()

  struct Error: Swift.Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static func check(_ status: OpaquePointer?) throws {
    guard let status else { return }
    let raw = api.pointee.GetErrorMessage(status)
    let msg = raw.map { String(cString: $0) } ?? "unknown ONNX Runtime error"
    api.pointee.ReleaseStatus(status)
    throw Error(message: msg)
  }

  /// A loaded graph. Input and output names are read once at load so `run`
  /// can feed by name without re-querying.
  final class Session {
    private let session: OpaquePointer
    private let allocator: UnsafeMutablePointer<OrtAllocator>
    let inputNames: [String]
    let outputNames: [String]

    init(path: String, threads: Int) throws {
      var opts: OpaquePointer?
      try check(Ort.api.pointee.CreateSessionOptions(&opts))
      defer { Ort.api.pointee.ReleaseSessionOptions(opts) }
      try check(Ort.api.pointee.SetIntraOpNumThreads(opts, Int32(threads)))
      try check(Ort.api.pointee.SetSessionGraphOptimizationLevel(opts, ORT_ENABLE_ALL))
      // Each graph runs sequentially inside its own session; the outer queue
      // already serializes calls, so an inter-op pool would only add threads.
      try check(Ort.api.pointee.SetSessionExecutionMode(opts, ORT_SEQUENTIAL))

      var s: OpaquePointer?
      try check(Ort.api.pointee.CreateSession(Env.shared.ptr, path, opts, &s))
      guard let s else { throw Error(message: "CreateSession returned null for \(path)") }
      session = s

      var alloc: UnsafeMutablePointer<OrtAllocator>?
      try check(Ort.api.pointee.GetAllocatorWithDefaultOptions(&alloc))
      guard let alloc else { throw Error(message: "no default allocator") }
      allocator = alloc

      var nIn = 0, nOut = 0
      try check(Ort.api.pointee.SessionGetInputCount(s, &nIn))
      try check(Ort.api.pointee.SessionGetOutputCount(s, &nOut))
      func names(_ count: Int, _ get: (OpaquePointer, Int, UnsafeMutablePointer<OrtAllocator>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> OpaquePointer?) throws -> [String] {
        try (0..<count).map { i in
          var raw: UnsafeMutablePointer<CChar>?
          try check(get(s, i, alloc, &raw))
          guard let raw else { return "" }
          defer { _ = Ort.api.pointee.AllocatorFree(alloc, raw) }
          return String(cString: raw)
        }
      }
      inputNames = try names(nIn) { Ort.api.pointee.SessionGetInputName($0, $1, $2, $3) }
      outputNames = try names(nOut) { Ort.api.pointee.SessionGetOutputName($0, $1, $2, $3) }
    }

    deinit { Ort.api.pointee.ReleaseSession(session) }

    /// Runs the graph. `floats` and `int64s` are fed by input name; every
    /// output is returned as a flat Float array plus its shape. Int64 outputs
    /// are converted, bool outputs are surfaced as 1.0/0.0.
    func run(floats: [String: (data: [Float], shape: [Int64])],
             int64s: [String: (data: [Int64], shape: [Int64])]) throws -> [(data: [Float], shape: [Int64])] {
      var memInfo: OpaquePointer?
      try check(Ort.api.pointee.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memInfo))
      defer { Ort.api.pointee.ReleaseMemoryInfo(memInfo) }

      var values: [OpaquePointer?] = []
      var order: [String] = []
      defer { for v in values { Ort.api.pointee.ReleaseValue(v) } }

      // Buffers must outlive the run: CreateTensorWithDataAsOrtValue borrows.
      var floatStore: [[Float]] = []
      var intStore: [[Int64]] = []

      for (name, t) in floats {
        floatStore.append(t.data)
        var v: OpaquePointer?
        try floatStore[floatStore.count - 1].withUnsafeMutableBufferPointer { buf in
          var shape = t.shape
          try check(Ort.api.pointee.CreateTensorWithDataAsOrtValue(
            memInfo, buf.baseAddress, buf.count * MemoryLayout<Float>.size,
            &shape, shape.count, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &v))
        }
        values.append(v)
        order.append(name)
      }
      for (name, t) in int64s {
        intStore.append(t.data)
        var v: OpaquePointer?
        try intStore[intStore.count - 1].withUnsafeMutableBufferPointer { buf in
          var shape = t.shape
          try check(Ort.api.pointee.CreateTensorWithDataAsOrtValue(
            memInfo, buf.baseAddress, buf.count * MemoryLayout<Int64>.size,
            &shape, shape.count, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &v))
        }
        values.append(v)
        order.append(name)
      }

      let inCStrings = order.map { strdup($0) }
      defer { inCStrings.forEach { free($0) } }
      let outCStrings = outputNames.map { strdup($0) }
      defer { outCStrings.forEach { free($0) } }

      var outputs = [OpaquePointer?](repeating: nil, count: outputNames.count)
      try inCStrings.withUnsafeBufferPointer { inNames in
        try outCStrings.withUnsafeBufferPointer { outNames in
          try values.withUnsafeMutableBufferPointer { ins in
            try outputs.withUnsafeMutableBufferPointer { outs in
              try check(Ort.api.pointee.Run(
                session, nil,
                inNames.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: UnsafePointer<CChar>?.self) },
                ins.baseAddress, ins.count,
                outNames.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: UnsafePointer<CChar>?.self) },
                outs.count, outs.baseAddress))
            }
          }
        }
      }
      defer { for o in outputs { Ort.api.pointee.ReleaseValue(o) } }

      return try outputs.map { try Self.readTensor($0) }
    }

    private static func readTensor(_ value: OpaquePointer?) throws -> (data: [Float], shape: [Int64]) {
      guard let value else { return ([], []) }
      var info: OpaquePointer?
      try check(Ort.api.pointee.GetTensorTypeAndShape(value, &info))
      defer { Ort.api.pointee.ReleaseTensorTypeAndShapeInfo(info) }
      var dims = 0
      try check(Ort.api.pointee.GetDimensionsCount(info, &dims))
      var shape = [Int64](repeating: 0, count: dims)
      try check(Ort.api.pointee.GetDimensions(info, &shape, dims))
      var count = 0
      try check(Ort.api.pointee.GetTensorShapeElementCount(info, &count))
      var type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
      try check(Ort.api.pointee.GetTensorElementType(info, &type))

      var raw: UnsafeMutableRawPointer?
      try check(Ort.api.pointee.GetTensorMutableData(value, &raw))
      guard let raw else { return ([], shape) }

      switch type {
      case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:
        let p = raw.assumingMemoryBound(to: Float.self)
        return (Array(UnsafeBufferPointer(start: p, count: count)), shape)
      case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64:
        let p = raw.assumingMemoryBound(to: Int64.self)
        return ((0..<count).map { Float(p[$0]) }, shape)
      case ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL:
        let p = raw.assumingMemoryBound(to: Bool.self)
        return ((0..<count).map { p[$0] ? 1 : 0 }, shape)
      default:
        throw Error(message: "unsupported output tensor type \(type.rawValue)")
      }
    }
  }
}
