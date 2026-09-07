import Accelerate
import Foundation

/// Runs the ARK-ASR ONNX bundles (ark-asr-0.6b-int8-onnx). Same `arkasr` family
/// as ArkasrEngine and the same prompt shape, but a different graph split: a
/// Whisper encoder plus a merge/adapter pair for audio, an ONNX embedding
/// lookup, and one LLM graph serving both prefill and decode with a
/// time-major KV cache.
///
/// Ported from `infer_ark_audio_onnx.py` in the bundle.
final class ArkEngine: OfflineAsrEngine {
  struct Config: Equatable {
    var nMel = 128
    var framesPadded = 3000
    var hop = 160
    var mergeFactor = 4
    var maxAudioSeconds = 30
    var sampleRate = 16000
    var encoderHidden = 1280
    var numLayers = 24
    var numKVHeads = 2
    var headDim = 64
    var maxTotalLen = 2048
    var maxNewTokens = 256
    var audioTokenId = 151663
    var userTokenId = 151665
    var beginAudioTokenId = 151666
    var endAudioTokenId = 151667
    var assistantTokenId = 151668
    var stopTokenIds: Set<Int> = [151645, 151643, 151665]
    /// Everything from here up is a special token; only `keepTokenId` survives,
    /// which is what `build_bad_token_ids` plus the default
    /// `asr_block_token_id_from` come to.
    var blockFromId = 151643
    var keepTokenId = 151645
    var promptSuffix = [5501, 1356, 3114, 419, 7699, 13]
  }

  private let config: Config
  private let encoder: Ort.Session
  private let adapter: Ort.Session
  private let embedder: Ort.Session
  private let llm: Ort.Session
  private let tokenizer: ArkasrTokenizer
  private var hiddenSize = 0

  init(dir: URL, config: Config = Config()) throws {
    self.config = config
    let threads = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))

    func pick(_ needle: String) throws -> String {
      guard let url = ModelStore.find(needle, in: dir, preferInt8: true) else {
        throw Ort.Error(message: "\(needle) graph missing from \(dir.lastPathComponent)")
      }
      return url.path
    }
    encoder = try Ort.Session(path: try pick("audio_encoder_whisper"), threads: threads)
    adapter = try Ort.Session(path: try pick("audio_encoder_adapter"), threads: threads)
    embedder = try Ort.Session(path: try pick("embedding"), threads: threads)
    llm = try Ort.Session(path: try pick("llm_kv"), threads: threads)
    tokenizer = try ArkasrTokenizer(vocabURL: dir.appendingPathComponent("vocab.json"))
  }

  private func audioTokenCount(samples: Int) -> Int {
    let melFrames = samples / config.hop
    return max(1, ((melFrames + 1) / 2) / config.mergeFactor)
  }

  func transcribe(samples input: [Float], sampleRate: Int) throws -> String {
    var samples = SileroVAD.resampleTo16k(input, from: sampleRate)
    let maxSamples = config.maxAudioSeconds * config.sampleRate
    if samples.count > maxSamples { samples = Array(samples[0..<maxSamples]) }
    guard samples.count >= config.hop else { return "" }

    let wanted = audioTokenCount(samples: samples.count)
    var ids = [config.userTokenId, config.beginAudioTokenId]
    ids.append(contentsOf: Array(repeating: config.audioTokenId, count: wanted))
    ids.append(config.endAudioTokenId)
    ids.append(contentsOf: config.promptSuffix)
    ids.append(config.assistantTokenId)
    guard ids.count + config.maxNewTokens <= config.maxTotalLen else {
      throw Ort.Error(message: "prompt of \(ids.count) exceeds cache length \(config.maxTotalLen)")
    }

    var embeds = try embed(ids)
    hiddenSize = embeds.count / ids.count
    let audioEmbeds = try encodeAudio(samples, wanted: wanted)
    for (slot, position) in ids.enumerated().filter({ $0.element == config.audioTokenId })
      .map({ $0.offset }).enumerated() {
      guard slot < audioEmbeds.count else { break }
      let row = audioEmbeds[slot]
      for d in 0..<min(hiddenSize, row.count) { embeds[position * hiddenSize + d] = row[d] }
    }

    return try generate(promptEmbeds: embeds, promptLen: ids.count)
  }

  private func embed(_ ids: [Int]) throws -> [Float] {
    let out = try embedder.run(
      floats: [:],
      int64s: ["input_ids": (ids.map { Int64($0) }, [1, Int64(ids.count)])])
    guard let first = out.first else { throw Ort.Error(message: "embedding graph returned nothing") }
    return first.data
  }

  /// Whisper encoder, then 4-frame merge, then the adapter down to the LM width.
  private func encodeAudio(_ samples: [Float], wanted: Int) throws -> [[Float]] {
    let (mel, frames) = WhisperMel.logMel(samples: samples, nMel: config.nMel)
    let padded = WhisperMel.padFrames(
      mel, nMel: config.nMel, frames: frames, to: config.framesPadded)

    let encoded = try encoder.run(
      floats: ["audios": (padded, [1, Int64(config.nMel), Int64(config.framesPadded)])],
      int64s: [:])
    guard let enc = encoded.first, enc.shape.count == 3 else {
      throw Ort.Error(message: "audio encoder returned an unexpected shape")
    }
    let seq = Int(enc.shape[1])
    let dim = Int(enc.shape[2])
    guard dim == config.encoderHidden else {
      throw Ort.Error(message: "audio hidden \(dim) != \(config.encoderHidden)")
    }

    let merge = config.mergeFactor
    let mergedSeq = max(1, seq / merge)
    var merged = [Float](repeating: 0, count: mergedSeq * dim * merge)
    let copy = min(enc.data.count, mergedSeq * merge * dim)
    merged.replaceSubrange(0..<copy, with: enc.data[0..<copy])

    let adapted = try adapter.run(
      floats: ["merged_audio_features": (merged, [1, Int64(mergedSeq), Int64(dim * merge)])],
      int64s: [:])
    guard let out = adapted.first, out.shape.count == 3 else {
      throw Ort.Error(message: "audio adapter returned an unexpected shape")
    }
    let outDim = Int(out.shape[2])
    let rows = Int(out.shape[1])
    return (0..<min(wanted, rows)).map { i in
      Array(out.data[(i * outDim)..<((i + 1) * outDim)])
    }
  }

  private func generate(promptEmbeds: [Float], promptLen: Int) throws -> String {
    let layers = config.numLayers
    let heads = config.numKVHeads
    let dim = config.headDim
    let total = config.maxTotalLen
    // Cache is [1, max_total_len, kv_heads, head_dim]: time major, unlike the
    // head-major layout the 0.1B bundle uses.
    var caches = [[Float]](
      repeating: [Float](repeating: 0, count: total * heads * dim), count: layers * 2)

    func feed(embeds: [Float], length: Int, positions: [Int64], validLen: Int)
      throws -> [(data: [Float], shape: [Int64])] {
      var mask = [Int64](repeating: 0, count: total)
      for i in 0..<min(validLen, total) { mask[i] = 1 }
      var floats: [String: (data: [Float], shape: [Int64])] = [
        "inputs_embeds": (embeds, [1, Int64(length), Int64(hiddenSize)])
      ]
      for l in 0..<layers {
        floats["cache_key_\(l)"] = (caches[2 * l], [1, Int64(total), Int64(heads), Int64(dim)])
        floats["cache_value_\(l)"] = (caches[2 * l + 1], [1, Int64(total), Int64(heads), Int64(dim)])
      }
      return try llm.run(floats: floats, int64s: [
        "attention_mask": (mask, [1, Int64(total)]),
        "cache_position": (positions, [Int64(positions.count)]),
      ])
    }

    /// Writes a [1, n, heads, dim] delta into the cache starting at `at`.
    func store(_ out: [(data: [Float], shape: [Int64])], at: Int, count: Int) {
      for l in 0..<(layers * 2) {
        let src = out[1 + l].data
        let width = heads * dim
        for t in 0..<count {
          let s = t * width
          let d = (at + t) * width
          guard s + width <= src.count, d + width <= caches[l].count else { continue }
          caches[l].replaceSubrange(d..<(d + width), with: src[s..<(s + width)])
        }
      }
    }

    var out = try feed(embeds: promptEmbeds, length: promptLen,
                       positions: (0..<Int64(promptLen)).map { $0 }, validLen: promptLen)
    guard out.count >= 1 + layers * 2 else {
      throw Ort.Error(message: "llm returned \(out.count) outputs, want \(1 + layers * 2)")
    }
    store(out, at: 0, count: promptLen)

    var generated: [Int] = []
    var totalLen = promptLen

    for _ in 0..<config.maxNewTokens {
      var logits = Self.lastRow(out[0])
      for id in config.blockFromId..<logits.count where id != config.keepTokenId {
        logits[id] = -.infinity
      }
      var best: Float = -.infinity
      var next = config.keepTokenId
      for (i, v) in logits.enumerated() where v > best { best = v; next = i }
      if config.stopTokenIds.contains(next) { break }
      generated.append(next)
      guard totalLen < total else { break }

      out = try feed(embeds: try embed([next]), length: 1,
                     positions: [Int64(totalLen)], validLen: totalLen + 1)
      guard out.count >= 1 + layers * 2 else {
        throw Ort.Error(message: "llm returned \(out.count) outputs")
      }
      store(out, at: totalLen, count: 1)
      totalLen += 1
    }

    return ArkasrTokenizer.normalize(tokenizer.decode(generated))
  }

  private static func lastRow(_ tensor: (data: [Float], shape: [Int64])) -> [Float] {
    guard let vocab = tensor.shape.last.map({ Int($0) }), vocab > 0 else { return tensor.data }
    let start = tensor.data.count - vocab
    guard start >= 0 else { return tensor.data }
    return Array(tensor.data[start...])
  }
}
