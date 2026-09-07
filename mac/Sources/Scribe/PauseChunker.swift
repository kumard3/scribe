import Foundation

/// Live dictation slicer: speech start → record, pause closes a chunk, a hard
/// cap splits run-on speech, and each chunk re-includes a short overlap so a
/// word cut at the boundary still appears whole in one window.
struct PauseChunker {
  var sampleRate: Int
  var pauseMs: Int
  var hardCapSeconds: Double
  var overlapSeconds: Double
  var speechRms: Float
  var minSpeechSeconds: Double
  var leadPadSeconds: Double

  private var current: [Float] = []
  private var lead: [Float] = []
  private var silent = 0
  private var voiced = 0
  private var inSpeech = false

  init(
    sampleRate: Int = 16_000,
    pauseMs: Int = 550,
    hardCapSeconds: Double = 3,
    overlapSeconds: Double = 0.3,
    speechRms: Float = 0.01,
    minSpeechSeconds: Double = 0.15,
    leadPadSeconds: Double = 0.1
  ) {
    self.sampleRate = max(sampleRate, 1)
    self.pauseMs = pauseMs
    self.hardCapSeconds = hardCapSeconds
    self.overlapSeconds = overlapSeconds
    self.speechRms = speechRms
    self.minSpeechSeconds = minSpeechSeconds
    self.leadPadSeconds = leadPadSeconds
  }

  mutating func reset(sampleRate: Int) {
    self.sampleRate = max(sampleRate, 1)
    current.removeAll(keepingCapacity: true)
    lead.removeAll(keepingCapacity: true)
    silent = 0
    voiced = 0
    inSpeech = false
  }

  mutating func feed(_ samples: [Float]) -> [[Float]] {
    guard !samples.isEmpty else { return [] }
    var out: [[Float]] = []
    let win = max(1, sampleRate / 100)
    var i = 0
    while i < samples.count {
      let end = min(i + win, samples.count)
      let slice = samples[i..<end]
      let rms = Self.rms(slice)
      if rms >= speechRms {
        if !inSpeech {
          current.append(contentsOf: lead)
          lead.removeAll(keepingCapacity: true)
          inSpeech = true
        }
        current.append(contentsOf: slice)
        voiced += slice.count
        silent = 0
      } else if inSpeech {
        current.append(contentsOf: slice)
        silent += slice.count
      } else {
        lead.append(contentsOf: slice)
        let pad = Int(Double(sampleRate) * leadPadSeconds)
        if lead.count > pad {
          lead.removeFirst(lead.count - pad)
        }
      }
      if inSpeech, voiced >= minSpeechSamples,
         silent >= pauseSamples || voiced >= hardCapSamples {
        if let chunk = close() { out.append(chunk) }
      }
      i = end
    }
    return out
  }

  mutating func flush() -> [Float]? {
    close()
  }

  private var pauseSamples: Int { max(1, sampleRate * max(pauseMs, 1) / 1000) }
  private var hardCapSamples: Int { max(pauseSamples, Int(Double(sampleRate) * hardCapSeconds)) }
  private var minSpeechSamples: Int { max(1, Int(Double(sampleRate) * minSpeechSeconds)) }
  private var overlapSamples: Int {
    max(0, Int(Double(sampleRate) * overlapSeconds))
  }

  private mutating func close() -> [Float]? {
    let chunk = current
    guard voiced >= minSpeechSamples else {
      current.removeAll(keepingCapacity: true)
      lead.removeAll(keepingCapacity: true)
      silent = 0
      voiced = 0
      inSpeech = false
      return nil
    }
    let keep = min(overlapSamples, chunk.count)
    current = keep > 0 ? Array(chunk.suffix(keep)) : []
    lead.removeAll(keepingCapacity: true)
    silent = 0
    voiced = 0
    inSpeech = false
    return chunk
  }

  private static func rms(_ slice: ArraySlice<Float>) -> Float {
    guard !slice.isEmpty else { return 0 }
    var sum: Float = 0
    for x in slice { sum += x * x }
    return sqrtf(sum / Float(slice.count))
  }

  static func selfTest() {
    var c = PauseChunker(sampleRate: 16_000, pauseMs: 550)
    let silence = [Float](repeating: 0, count: 16_000)
    precondition(c.feed(silence).isEmpty)
    precondition(c.flush() == nil)

    func tone(_ n: Int, amp: Float = 0.2) -> [Float] {
      (0..<n).map { i in Float(sin(Double(i) / 8.0)) * amp }
    }

    c.reset(sampleRate: 16_000)
    precondition(c.feed(tone(16_000)).isEmpty, "1s of speech must wait for a pause")
    let paused = c.feed([Float](repeating: 0, count: 16_000 * 6 / 10))
    precondition(paused.count == 1, "pause after speech closes one chunk")
    precondition(paused[0].count >= 16_000)
    precondition(c.flush() == nil, "overlap-only remainder is not a new utterance")

    c.reset(sampleRate: 16_000)
    let long = c.feed(tone(Int(16_000 * 3.4)))
    precondition(long.count == 1, "hard cap splits run-on speech: \(long.count)")
    precondition(long[0].count >= 16_000 * 3)
    let tail = c.flush()
    precondition(tail != nil, "audio past the cap survives on flush")

    c.reset(sampleRate: 16_000)
    _ = c.feed(tone(8_000))
    let first = c.feed([Float](repeating: 0, count: 16_000 * 6 / 10))
    precondition(first.count == 1)
    _ = c.feed(tone(8_000))
    let second = c.feed([Float](repeating: 0, count: 16_000 * 6 / 10))
    precondition(second.count == 1)
    let overlap = Int(16_000 * 0.3)
    precondition(second[0].count >= 8_000)
    precondition(second[0].count >= overlap, "second chunk keeps overlap from the first")

    print("PauseChunker selftest ok")
  }
}
