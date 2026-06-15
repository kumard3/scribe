import Foundation
import AVFoundation
import React

// Native 16 kHz mono PCM recorder. AVAudioEngine taps the mic at the hardware
// rate and we resample to exactly 16 kHz / mono / Int16 so Whisper & co. get a
// correct WAV (expo-audio's iOS recorder mislabels the sample rate).
@objc(ScribeAudioRecorder)
class ScribeAudioRecorder: RCTEventEmitter {
  private let engine = AVAudioEngine()
  private var converter: AVAudioConverter?
  private var targetFormat: AVAudioFormat!
  private var pcm = Data()
  private var recording = false
  private var listening = false

  override init() {
    super.init()
    targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 16000,
      channels: 1,
      interleaved: true
    )
  }

  override static func requiresMainQueueSetup() -> Bool { return false }
  override func supportedEvents() -> [String]! { return ["ScribeAudioLevel"] }
  override func startObserving() { listening = true }
  override func stopObserving() { listening = false }

  @objc(start:rejecter:)
  func start(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
    if recording { resolve(nil); return }
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.record, mode: .default, options: [.allowBluetooth])
      try session.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      reject("session", "Audio session error: \(error.localizedDescription)", error)
      return
    }

    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      reject("input", "No microphone input available.", nil)
      return
    }
    converter = AVAudioConverter(from: inputFormat, to: targetFormat)
    pcm = Data()

    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
      self?.handle(buffer)
    }
    engine.prepare()
    do {
      try engine.start()
      recording = true
      resolve(nil)
    } catch {
      reject("engine", "Could not start recording: \(error.localizedDescription)", error)
    }
  }

  private func handle(_ buffer: AVAudioPCMBuffer) {
    guard let converter = converter else { return }
    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
    guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

    var consumed = false
    var err: NSError?
    converter.convert(to: out, error: &err) { _, status in
      if consumed {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return buffer
    }
    if err != nil { return }

    let n = Int(out.frameLength)
    guard n > 0, let ch = out.int16ChannelData else { return }
    let ptr = ch[0]
    pcm.append(Data(bytes: ptr, count: n * 2))

    var sum = 0.0
    for i in 0..<n {
      let s = Double(ptr[i]) / 32768.0
      sum += s * s
    }
    let rms = (n > 0) ? sqrt(sum / Double(n)) : 0
    if listening {
      sendEvent(withName: "ScribeAudioLevel", body: ["rms": rms])
    }
  }

  @objc(stop:rejecter:)
  func stop(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
    guard recording else { resolve(nil); return }
    teardown()
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-\(UUID().uuidString).wav")
    do {
      try wav(from: pcm, sampleRate: 16000, channels: 1, bits: 16).write(to: url)
      resolve(url.absoluteString)
    } catch {
      reject("write", "Could not save recording: \(error.localizedDescription)", error)
    }
  }

  @objc(cancel:rejecter:)
  func cancel(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
    teardown()
    pcm = Data()
    resolve(nil)
  }

  private func teardown() {
    if recording {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      recording = false
    }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func wav(from data: Data, sampleRate: Int, channels: Int, bits: Int) -> Data {
    let byteRate = sampleRate * channels * bits / 8
    let blockAlign = channels * bits / 8
    var header = Data()
    func str(_ s: String) { header.append(s.data(using: .ascii)!) }
    func u32(_ v: UInt32) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 2)) }
    str("RIFF"); u32(UInt32(36 + data.count)); str("WAVE")
    str("fmt "); u32(16); u16(1); u16(UInt16(channels))
    u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bits))
    str("data"); u32(UInt32(data.count))
    var out = header
    out.append(data)
    return out
  }
}
