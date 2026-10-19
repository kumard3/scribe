import Foundation

struct UsageDay: Codable, Equatable {
  struct Cloud: Codable, Equatable {
    var calls = 0
    var failures = 0
    var audioSeconds = 0.0
    var inputTokens = 0
    var outputTokens = 0

    mutating func add(_ other: Cloud) {
      calls += other.calls
      failures += other.failures
      audioSeconds += other.audioSeconds
      inputTokens += other.inputTokens
      outputTokens += other.outputTokens
    }
  }

  var words = 0
  var dictations = 0
  var speechSeconds = 0.0
  var cloud: [String: Cloud] = [:]
}

/// Counts only, never transcript text, in ~/Library/Application Support/Scribe/usage.json.
final class Usage: ObservableObject, @unchecked Sendable {
  static let shared = Usage()

  static let providerNames = [
    "azure-speech": "Azure Speech",
    "azure-speech-realtime": "Azure Speech (live)",
    "azure-openai-transcribe": "Azure OpenAI transcription",
  ]

  @Published private(set) var days: [String: UsageDay]

  private struct File: Codable { var days: [String: UsageDay] }

  static var url: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Scribe/usage.json")
  }

  init() {
    days = (try? Data(contentsOf: Self.url)).flatMap { try? JSONDecoder().decode(File.self, from: $0).days } ?? [:]
  }

  func recordDictation(_ text: String, seconds: Double) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let words = Self.wordCount(text)
    update {
      $0.words += words
      $0.dictations += 1
      $0.speechSeconds += max(seconds, 0)
    }
  }

  func recordCloud(_ provider: String, failed: Bool, audioSeconds: Double, inputTokens: Int = 0, outputTokens: Int = 0) {
    let call = UsageDay.Cloud(
      calls: 1, failures: failed ? 1 : 0, audioSeconds: audioSeconds, inputTokens: inputTokens, outputTokens: outputTokens)
    update { $0.cloud[provider, default: UsageDay.Cloud()].add(call) }
  }

  func reset() {
    DispatchQueue.main.async {
      self.days = [:]
      self.save()
    }
  }

  private func update(_ change: @escaping (inout UsageDay) -> Void) {
    let key = Self.key(Date())
    DispatchQueue.main.async {
      var days = self.days
      change(&days[key, default: UsageDay()])
      self.days = Self.trimmed(days)
      self.save()
    }
  }

  private func save() {
    try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(File(days: days)).write(to: Self.url, options: .atomic)
  }

  private static let dayFormat: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  static func key(_ date: Date) -> String { dayFormat.string(from: date) }

  static func trimmed(_ days: [String: UsageDay], keep: Int = 400) -> [String: UsageDay] {
    guard days.count > keep else { return days }
    return Dictionary(uniqueKeysWithValues: days.sorted { $0.key > $1.key }.prefix(keep).map { ($0.key, $0.value) })
  }

  static func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
  }

  static func duration(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
  }

  static func describe(_ c: UsageDay.Cloud) -> String {
    var parts = ["\(c.calls.formatted()) \(c.calls == 1 ? "call" : "calls")" + (c.failures > 0 ? ", \(c.failures.formatted()) failed" : "")]
    parts.append(String(format: "%.1f min audio", c.audioSeconds / 60))
    if c.inputTokens > 0 || c.outputTokens > 0 {
      parts.append("\(c.inputTokens.formatted()) in / \(c.outputTokens.formatted()) out tokens")
    }
    return parts.joined(separator: " · ")
  }

  static func selfTest() {
    precondition(wordCount("Hello, world! - ... 42 नमस्ते ?!") == 4)
    precondition(wordCount("  \n ") == 0)

    let cal = Calendar.current
    let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 10))!
    func day(_ back: Int) -> String { key(cal.date(byAdding: .day, value: -back, to: now)!) }
    let cloud = UsageDay.Cloud(calls: 2, failures: 1, audioSeconds: 30, inputTokens: 100, outputTokens: 20)
    var days: [String: UsageDay] = [
      day(0): UsageDay(words: 10, dictations: 1, speechSeconds: 30),
      day(1): UsageDay(words: 20, dictations: 2, speechSeconds: 20, cloud: ["azure-speech": cloud]),
      day(2): UsageDay(words: 30, dictations: 1, speechSeconds: 10),
      day(4): UsageDay(words: 40, dictations: 1),
      day(10): UsageDay(words: 50, dictations: 1, cloud: ["azure-speech": cloud]),
    ]
    var s = UsageStats(days, now: now)
    precondition(s.todayWords == 10 && s.weekWords == 100 && s.words == 150 && s.dictations == 6)
    precondition(s.streak == 3)
    precondition(s.wpm == 150)
    precondition(s.month["azure-speech"]?.calls == 2 && s.allTime["azure-speech"]?.calls == 4)
    precondition(s.allTime["azure-speech"] == UsageDay.Cloud(calls: 4, failures: 2, audioSeconds: 60, inputTokens: 200, outputTokens: 40))

    days[day(0)] = nil
    s = UsageStats(days, now: now)
    precondition(s.streak == 2)
    precondition(s.wpm == nil)
    precondition(UsageStats([day(2): UsageDay(dictations: 1)], now: now).streak == 0)

    let many = Dictionary(uniqueKeysWithValues: (0..<405).map { (day($0), UsageDay(words: $0)) })
    let kept = trimmed(many)
    precondition(kept.count == 400 && kept[day(0)] != nil && kept[day(399)] != nil && kept[day(400)] == nil)
    precondition(duration(59) == "0m" && duration(3_900) == "1h 5m")
    print("Usage selftest ok")
  }
}

struct UsageStats {
  var todayWords = 0
  var weekWords = 0
  var words = 0
  var dictations = 0
  var speechSeconds = 0.0
  var streak = 0
  var month: [String: UsageDay.Cloud] = [:]
  var allTime: [String: UsageDay.Cloud] = [:]

  var wpm: Int? { speechSeconds >= 60 ? Int((Double(words) / (speechSeconds / 60)).rounded()) : nil }

  init(_ days: [String: UsageDay], now: Date = Date()) {
    let calendar = Calendar.current
    func day(_ back: Int) -> UsageDay? {
      calendar.date(byAdding: .day, value: -back, to: now).flatMap { days[Usage.key($0)] }
    }
    let monthPrefix = Usage.key(now).prefix(8)
    for (key, d) in days {
      words += d.words
      dictations += d.dictations
      speechSeconds += d.speechSeconds
      for (provider, c) in d.cloud {
        allTime[provider, default: UsageDay.Cloud()].add(c)
        if key.hasPrefix(monthPrefix) { month[provider, default: UsageDay.Cloud()].add(c) }
      }
    }
    todayWords = day(0)?.words ?? 0
    weekWords = (0..<7).reduce(0) { $0 + (day($1)?.words ?? 0) }
    var back = (day(0)?.dictations ?? 0) > 0 ? 0 : 1
    while (day(back)?.dictations ?? 0) > 0 {
      streak += 1
      back += 1
    }
  }
}
