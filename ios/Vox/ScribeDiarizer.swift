import Foundation
import AVFoundation
import React

@objc(ScribeDiarizer)
class ScribeDiarizer: NSObject {
  private var sd: OpaquePointer?
  private var loadedKey: String?

  @objc static func requiresMainQueueSetup() -> Bool { return false }

  @objc(isAvailable:rejecter:)
  func isAvailable(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
    resolve(true)
  }

  @objc(diarize:segModel:embModel:numSpeakers:threshold:resolver:rejecter:)
  func diarize(
    _ wavPath: String,
    segModel: String,
    embModel: String,
    numSpeakers: Double,
    threshold: Double,
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let out = try self.run(
          self.clean(wavPath),
          self.clean(segModel),
          self.clean(embModel),
          Int(numSpeakers),
          threshold
        )
        resolve(out)
      } catch {
        reject("diarize_failed", error.localizedDescription, error)
      }
    }
  }

  private func run(_ wav: String, _ seg: String, _ emb: String, _ numSpeakers: Int, _ threshold: Double) throws -> [[String: Any]] {
    let key = "\(seg)|\(emb)"
    if sd == nil || loadedKey != key {
      if let old = sd { SherpaOnnxDestroyOfflineSpeakerDiarization(old); sd = nil }
      let segC = strdup(seg)
      let embC = strdup(emb)
      let provC = strdup("cpu")
      defer { free(segC); free(embC); free(provC) }

      var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
      config.segmentation.pyannote.model = UnsafePointer(segC)
      config.segmentation.num_threads = 2
      config.segmentation.debug = 0
      config.segmentation.provider = UnsafePointer(provC)
      config.embedding.model = UnsafePointer(embC)
      config.embedding.num_threads = 2
      config.embedding.debug = 0
      config.embedding.provider = UnsafePointer(provC)
      config.clustering.num_clusters = Int32(numSpeakers > 0 ? numSpeakers : -1)
      config.clustering.threshold = Float(threshold > 0 ? threshold : 0.5)
      config.min_duration_on = 0.3
      config.min_duration_off = 0.5

      guard let engine = SherpaOnnxCreateOfflineSpeakerDiarization(&config) else {
        throw NSError(domain: "ScribeDiarizer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not load speaker models"])
      }
      sd = engine
      loadedKey = key
    }

    guard let engine = sd else { return [] }
    let rate = Int(SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(engine))
    let samples = try readAudio(wav, sampleRate: rate)
    if samples.isEmpty { return [] }

    let result = SherpaOnnxOfflineSpeakerDiarizationProcess(engine, samples, Int32(samples.count))
    guard let result = result else { return [] }
    defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }

    let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
    guard count > 0, let segs = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else { return [] }
    defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segs) }

    var out: [[String: Any]] = []
    out.reserveCapacity(count)
    for i in 0..<count {
      let s = segs[i]
      out.append(["start": Double(s.start), "end": Double(s.end), "speaker": Int(s.speaker)])
    }
    return out
  }

  private func clean(_ path: String) -> String {
    return path.hasPrefix("file://") ? String(path.dropFirst(7)) : path
  }

  private func readAudio(_ path: String, sampleRate: Int) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = file.processingFormat
    let frames = AVAudioFrameCount(file.length)
    guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return [] }
    try file.read(into: buf)
    let n = Int(buf.frameLength)
    guard n > 0, let chans = buf.floatChannelData else { return [] }

    let channelCount = Int(format.channelCount)
    var mono = [Float](repeating: 0, count: n)
    for i in 0..<n {
      var acc: Float = 0
      for c in 0..<channelCount { acc += chans[c][i] }
      mono[i] = acc / Float(channelCount)
    }
    let inRate = Int(format.sampleRate)
    return inRate == sampleRate ? mono : resample(mono, inRate, sampleRate)
  }

  private func resample(_ input: [Float], _ inRate: Int, _ outRate: Int) -> [Float] {
    if inRate == outRate || input.isEmpty { return input }
    let ratio = Double(inRate) / Double(outRate)
    let outLen = max(1, Int(Double(input.count) / ratio))
    var out = [Float](repeating: 0, count: outLen)
    for i in 0..<outLen {
      let pos = Double(i) * ratio
      let i0 = Int(pos)
      let i1 = (i0 + 1 < input.count) ? i0 + 1 : i0
      let frac = Float(pos - Double(i0))
      out[i] = input[i0] * (1 - frac) + input[i1] * frac
    }
    return out
  }
}
