import AVFoundation
import CoreAudio

/// Converts any incoming PCM buffer to 16 kHz mono and appends it to an Int16 CAF.
/// CAF stays readable if the app dies mid-meeting; m4a would not.
final class TrackWriter {
  static let format = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: Double(TranscriptionLimits.sampleRate),
    channels: 1, interleaved: false
  )!

  private let file: AVAudioFile
  private var converter: AVAudioConverter?
  private var sourceFormat: AVAudioFormat?
  private let lock = NSLock()
  private(set) var peak: Float = 0
  private(set) var level: Float = 0

  init(url: URL) throws {
    file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: TrackWriter.format.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
      ],
      commonFormat: .pcmFormatFloat32, interleaved: false
    )
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    guard buffer.frameLength > 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    if sourceFormat != buffer.format {
      sourceFormat = buffer.format
      converter = AVAudioConverter(from: buffer.format, to: TrackWriter.format)
      converter?.downmix = true
    }
    guard let converter else { return }
    let ratio = TrackWriter.format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
    guard let out = AVAudioPCMBuffer(pcmFormat: TrackWriter.format, frameCapacity: capacity) else { return }
    var fed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if fed { status.pointee = .noDataNow; return nil }
      fed = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
    var sum: Float = 0
    for i in 0..<Int(out.frameLength) {
      peak = max(peak, abs(ch[0][i]))
      sum += ch[0][i] * ch[0][i]
    }
    level = min(1, (sum / Float(out.frameLength)).squareRoot() * 6)
    try? file.write(from: out)
  }
}

enum SystemAudioTapError: LocalizedError {
  case osStatus(String, OSStatus)

  var errorDescription: String? {
    switch self {
    case let .osStatus(step, status): return "System audio capture failed (\(step), \(status))."
    }
  }
}

/// Records everything the Mac plays, except Bolkit itself, through a Core Audio
/// process tap on a private aggregate device (macOS 14.4+). The first start shows
/// the system audio recording prompt; if the user declines, the track is silent.
@available(macOS 14.4, *)
final class SystemAudioTap {
  private let writer: TrackWriter
  private let queue = DispatchQueue(label: "scribe.meeting.tap")
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?

  var peak: Float { writer.peak }
  private(set) var callbacks = 0
  private(set) var inputPeak: Float = 0
  private(set) var formatLabel = ""

  init(writer: TrackWriter) { self.writer = writer }

  func start() throws {
    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcessObject().map { [$0] } ?? [])
    description.uuid = UUID()
    description.isPrivate = true
    description.muteBehavior = CATapMuteBehavior.unmuted

    try check("create tap", AudioHardwareCreateProcessTap(description, &tapID))

    var asbd = AudioStreamBasicDescription()
    try check("tap format", read(tapID, kAudioTapPropertyFormat, &asbd))

    let outputUID = try defaultOutputUID()
    let aggregate: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Bolkit Meeting Capture",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: outputUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
      kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: description.uuid.uuidString,
      ]],
    ]
    try check("aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

    // The tap reports 48 kHz even when the device clock runs at 44.1 kHz; trusting it made tracks 8% short.
    var rate = Float64(0)
    if read(aggregateID, kAudioDevicePropertyNominalSampleRate, &rate) == noErr, rate > 0 { asbd.mSampleRate = rate }
    guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
      throw SystemAudioTapError.osStatus("tap format", -1)
    }

    formatLabel = "\(tapFormat)"
    let writer = self.writer
    try check("io proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
      self?.callbacks += 1
      guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: input, deallocator: nil) else { return }
      if let self, let ch = buffer.floatChannelData {
        for i in 0..<Int(buffer.frameLength) { self.inputPeak = max(self.inputPeak, abs(ch[0][i])) }
      }
      writer.append(buffer)
    })
    try check("start", AudioDeviceStart(aggregateID, procID))
  }

  func stop() {
    if aggregateID != kAudioObjectUnknown {
      AudioDeviceStop(aggregateID, procID)
      if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
      AudioHardwareDestroyAggregateDevice(aggregateID)
    }
    if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    procID = nil
    aggregateID = AudioObjectID(kAudioObjectUnknown)
    tapID = AudioObjectID(kAudioObjectUnknown)
  }

  private func ownProcessObject() -> AudioObjectID? {
    var pid = getpid()
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address,
      UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
    )
    return status == noErr && object != kAudioObjectUnknown ? object : nil
  }

  private func defaultOutputUID() throws -> String {
    var device = AudioObjectID(kAudioObjectUnknown)
    try check("output device", read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device))
    var uid: CFString = "" as CFString
    try check("output uid", read(device, kAudioDevicePropertyDeviceUID, &uid))
    return uid as String
  }

  private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
    var size = UInt32(MemoryLayout<T>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
  }

  private func check(_ step: String, _ status: OSStatus) throws {
    guard status == noErr else { throw SystemAudioTapError.osStatus(step, status) }
  }
}
