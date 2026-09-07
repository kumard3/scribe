import Accelerate
import Compression
import Foundation

/// Reader for the numpy artifacts the Audio8 ONNX bundles ship alongside their
/// graphs: the token embedding table (.npy) and the audio projector (.npz).
enum Npy {
  struct Array {
    let shape: [Int]
    let data: Data       // raw element bytes
    let isFloat16: Bool

    var count: Int { shape.reduce(1, *) }

    /// Copies `count` elements starting at flat index `offset` into floats.
    func floats(offset: Int = 0, count take: Int? = nil) -> [Float] {
      let n = take ?? (count - offset)
      guard n > 0 else { return [] }
      if isFloat16 {
        var half = [UInt16](repeating: 0, count: n)
        _ = half.withUnsafeMutableBytes { dst in
          data.copyBytes(to: dst, from: (offset * 2)..<((offset + n) * 2))
        }
        var out = [Float](repeating: 0, count: n)
        var src = vImage_Buffer(data: &half, height: 1, width: vImagePixelCount(n), rowBytes: n * 2)
        var dst = vImage_Buffer(data: &out, height: 1, width: vImagePixelCount(n), rowBytes: n * 4)
        vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
        return out
      }
      var out = [Float](repeating: 0, count: n)
      _ = out.withUnsafeMutableBytes { dst in
        data.copyBytes(to: dst, from: (offset * 4)..<((offset + n) * 4))
      }
      return out
    }

    /// One row of a 2-D array.
    func row(_ index: Int) -> [Float] {
      guard shape.count == 2 else { return [] }
      return floats(offset: index * shape[1], count: shape[1])
    }
  }

  enum Error: Swift.Error, LocalizedError {
    case malformed(String)
    var errorDescription: String? {
      if case let .malformed(m) = self { return "numpy parse failed: \(m)" }
      return nil
    }
  }

  /// Parses a .npy buffer. Only the little-endian float32/float16 C-order
  /// layouts the bundles actually ship are accepted.
  static func parse(_ data: Data) throws -> Array {
    guard data.count > 10, data[data.startIndex + 1] == 0x4E else {
      throw Error.malformed("bad magic")
    }
    let base = data.startIndex
    let major = data[base + 6]
    let headerLen: Int
    let headerStart: Int
    if major == 1 {
      headerLen = Int(data[base + 8]) | Int(data[base + 9]) << 8
      headerStart = 10
    } else {
      headerLen = Int(data[base + 8]) | Int(data[base + 9]) << 8
        | Int(data[base + 10]) << 16 | Int(data[base + 11]) << 24
      headerStart = 12
    }
    guard let header = String(data: data[(base + headerStart)..<(base + headerStart + headerLen)],
                              encoding: .ascii) else {
      throw Error.malformed("header not ascii")
    }
    guard let descrRange = header.range(of: "'descr':") else { throw Error.malformed("no descr") }
    let descr = header[descrRange.upperBound...].prefix(12)
    let isFloat16 = descr.contains("f2")
    guard isFloat16 || descr.contains("f4") else {
      throw Error.malformed("unsupported dtype \(descr)")
    }
    guard !header.contains("'fortran_order': True") else {
      throw Error.malformed("fortran order unsupported")
    }
    guard let open = header.range(of: "'shape':"),
          let lp = header[open.upperBound...].firstIndex(of: "("),
          let rp = header[lp...].firstIndex(of: ")") else {
      throw Error.malformed("no shape")
    }
    let shape = header[header.index(after: lp)..<rp]
      .split(separator: ",")
      .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    let payload = data[(base + headerStart + headerLen)...]
    return Array(shape: shape, data: Data(payload), isFloat16: isFloat16)
  }

  static func load(url: URL) throws -> Array {
    try parse(try Data(contentsOf: url, options: .mappedIfSafe))
  }

  /// Parses a .npz (a zip of .npy members). `np.savez` stores members
  /// uncompressed and `np.savez_compressed` deflates them; both are handled.
  static func loadZip(url: URL) throws -> [String: Array] {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let base = data.startIndex
    var out: [String: Array] = [:]

    // Walk local file headers; npz never spans archives or uses zip64 here.
    var cursor = base
    while cursor + 30 <= data.endIndex {
      guard u32(data, cursor) == 0x0403_4B50 else { break }
      let method = Int(u16(data, cursor + 8))
      var compressed = Int(u32(data, cursor + 18))
      var uncompressed = Int(u32(data, cursor + 22))
      let nameLen = Int(u16(data, cursor + 26))
      let extraLen = Int(u16(data, cursor + 28))
      let nameStart = cursor + 30
      let name = String(data: data[nameStart..<(nameStart + nameLen)], encoding: .utf8) ?? ""
      let body = nameStart + nameLen + extraLen

      // Streamed entries put the sizes in a trailing descriptor; npz doesn't,
      // but guard anyway so a zero size can't spin the loop.
      if compressed == 0 && uncompressed == 0 { break }
      if compressed == 0 { compressed = uncompressed }

      let raw = data[body..<min(data.endIndex, body + compressed)]
      let member: Data
      if method == 0 {
        member = Data(raw)
      } else if method == 8 {
        member = try inflate(Data(raw), expected: uncompressed)
      } else {
        throw Error.malformed("zip method \(method)")
      }
      if name.hasSuffix(".npy") {
        out[String(name.dropLast(4))] = try parse(member)
      }
      cursor = body + compressed
    }
    guard !out.isEmpty else { throw Error.malformed("npz had no .npy members") }
    return out
  }

  private static func inflate(_ data: Data, expected: Int) throws -> Data {
    var out = Data(count: max(expected, 1))
    let written = out.withUnsafeMutableBytes { dst -> Int in
      data.withUnsafeBytes { src -> Int in
        guard let s = src.baseAddress, let d = dst.baseAddress else { return 0 }
        return compression_decode_buffer(
          d.assumingMemoryBound(to: UInt8.self), max(expected, 1),
          s.assumingMemoryBound(to: UInt8.self), data.count,
          nil, COMPRESSION_ZLIB)
      }
    }
    guard written > 0 else { throw Error.malformed("inflate failed") }
    return out.prefix(written)
  }

  private static func u16(_ d: Data, _ i: Int) -> UInt16 {
    UInt16(d[i]) | UInt16(d[i + 1]) << 8
  }

  private static func u32(_ d: Data, _ i: Int) -> UInt32 {
    UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
  }
}
