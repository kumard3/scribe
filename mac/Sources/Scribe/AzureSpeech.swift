import AVFoundation
import Foundation
import Security
import SwiftUI

struct AzureCredentials: Codable, Equatable {
  var speechKey = ""
  var region = ""
  var endpoint = ""
  var openAIKey = ""
  var openAIEndpoint = ""
  var backupSpeechKey: String?
  var backupEndpoint: String?

  var hasSpeech: Bool { !speechKey.isEmpty && !region.isEmpty && !endpoint.isEmpty }

  var backup: AzureCredentials? {
    guard let key = backupSpeechKey, let url = backupEndpoint, !key.isEmpty, !url.isEmpty else { return nil }
    return AzureCredentials(speechKey: key, region: region, endpoint: url)
  }
  var hasOpenAI: Bool { !openAIKey.isEmpty && !openAIEndpoint.isEmpty }

  func supports(_ spec: ModelSpec) -> Bool {
    AzureSpeech.deployment(spec) == nil ? hasSpeech : hasOpenAI
  }

  private static let keychainQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "ai.scribe.mac.azure",
    kSecAttrAccount as String: "credentials",
  ]

  static var saved: AzureCredentials? {
    var query = keychainQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }
    return try? JSONDecoder().decode(AzureCredentials.self, from: data)
  }

  @discardableResult
  func save() -> Bool {
    guard let data = try? JSONEncoder().encode(self) else { return false }
    SecItemDelete(Self.keychainQuery as CFDictionary)
    var query = Self.keychainQuery
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
  }

  static func fromEnvFiles() -> AzureCredentials? {
    let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    let speech = env(config.appendingPathComponent("azure-speech/bolkit.env"))
    let openAI = env(config.appendingPathComponent("azure-openai/eus2.env"))
    let found = AzureCredentials(
      speechKey: speech["AZURE_SPEECH_KEY"] ?? "", region: speech["AZURE_SPEECH_REGION"] ?? "",
      endpoint: speech["AZURE_SPEECH_ENDPOINT"] ?? "",
      openAIKey: openAI["AZURE_OPENAI_API_KEY"] ?? "", openAIEndpoint: openAI["AZURE_OPENAI_ENDPOINT"] ?? "",
      backupSpeechKey: speech["AZURE_SPEECH_BACKUP_KEY"], backupEndpoint: speech["AZURE_SPEECH_BACKUP_ENDPOINT"])
    return found.hasSpeech || found.hasOpenAI ? found : nil
  }

  private static func env(_ url: URL) -> [String: String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var out: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 2, !parts[0].hasPrefix("#") else { continue }
      let name = parts[0].hasPrefix("export ") ? String(parts[0].dropFirst(7)) : parts[0]
      out[name] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    return out
  }
}

enum AzureError: LocalizedError {
  case noCredentials
  case http(Int, String)

  var errorDescription: String? {
    switch self {
    case .noCredentials: return "Add your Azure key in Dashboard, Models"
    case let .http(code, _) where code == 401 || code == 403:
      return "Azure rejected the key (\(code)), check it in Dashboard, Models"
    case let .http(code, body): return "Azure error \(code): \(body)"
    }
  }
}

enum AzureSpeech {
  static let maiId = "azure-mai-transcribe-2"
  static let realtimeId = "azure-realtime"

  static let specs: [ModelSpec] = [
    ModelSpec(
      id: maiId, kind: .azure, label: "MAI-Transcribe-2",
      note: "Best for meetings, imported files and dictation after you stop speaking.",
      archive: "", sizeBytes: 0, live: false, quality: .best),
    ModelSpec(
      id: realtimeId, kind: .azure, label: "Azure Speech real-time",
      note: "Live words while you speak. Uses the language from Style: English, or Hindi for Hinglish.",
      archive: "", sizeBytes: 0, live: true),
    ModelSpec(
      id: "azure-gpt-4o-transcribe", kind: .azure, label: "GPT-4o Transcribe",
      note: "Needs an Azure OpenAI deployment named bolkit-gpt-4o-transcribe.",
      archive: "", sizeBytes: 0, live: false),
    ModelSpec(
      id: "azure-gpt-4o-mini-transcribe", kind: .azure, label: "GPT-4o mini Transcribe",
      note: "Needs an Azure OpenAI deployment named bolkit-gpt-4o-mini-transcribe.",
      archive: "", sizeBytes: 0, live: false),
  ]

  static func deployment(_ spec: ModelSpec) -> String? {
    spec.id.hasPrefix("azure-gpt-") ? "bolkit-" + spec.id.dropFirst("azure-".count) : nil
  }

  static var liveLocale: String {
    let settings = Settings.shared
    let style = DictationStyle(rawValue: settings.dictationStyle) ?? .auto
    if style == .hinglish || (style == .auto && settings.language == "hi") { return "hi-IN" }
    if style == .english || settings.language == "en" || settings.language == "auto" {
      return Locale.current.region?.identifier == "IN" ? "en-IN" : "en-US"
    }
    return liveLocales[settings.language] ?? "en-US"
  }

  private static let liveLocales = [
    "es": "es-ES", "fr": "fr-FR", "de": "de-DE", "pt": "pt-BR", "it": "it-IT", "nl": "nl-NL",
    "ru": "ru-RU", "ar": "ar-SA", "tr": "tr-TR", "id": "id-ID", "zh": "zh-CN", "ja": "ja-JP",
    "ko": "ko-KR", "bn": "bn-IN", "ta": "ta-IN", "te": "te-IN", "mr": "mr-IN", "gu": "gu-IN",
    "kn": "kn-IN", "ml": "ml-IN", "pa": "pa-IN", "ur": "ur-IN",
  ]

  struct Word {
    let text: String
    let start: Double
    let end: Double
  }

  struct Phrase {
    let speaker: Int?
    let text: String
    let words: [Word]
  }

  /// The real-time model has no file API, so files and retries use MAI.
  static func transcribe(spec: ModelSpec, samples: [Float], sampleRate: Int) async throws -> String {
    guard let credentials = AzureCredentials.saved, credentials.supports(spec) else { throw AzureError.noCredentials }
    let pcm = SileroVAD.resampleTo16k(samples, from: sampleRate)
    if let deployment = deployment(spec) {
      return try await openAI(pcm, deployment: deployment, credentials: credentials)
    }
    return try await mai(pcm, credentials: credentials).map(\.text).joined(separator: " ")
  }

  static func mai(
    _ pcm16k: [Float], speakers: Bool = false, words: Bool = false, credentials: AzureCredentials
  ) async throws -> [Phrase] {
    var enhanced: [String: Any] = ["enabled": true, "model": "MAI-Transcribe-2"]
    if words { enhanced["modelOptions"] = ["timestamps": "word"] }
    var definition: [String: Any] = ["enhancedMode": enhanced]
    if speakers { definition["diarization"] = ["enabled": true] }
    if !Vocabulary.terms.isEmpty { definition["phraseList"] = ["phrases": Vocabulary.terms] }
    let parts = [("audio", try flac(pcm16k)), ("definition", try JSONSerialization.data(withJSONObject: definition))]
    let seconds = Double(pcm16k.count) / 16_000
    let request: (AzureCredentials) async throws -> Data = { resource in
      guard let url = URL(string: trimmed(resource.endpoint) + "/speechtotext/transcriptions:transcribe?api-version=2025-10-15")
      else { throw AzureError.noCredentials }
      return try await post(url, provider: "azure-speech", header: ("Ocp-Apim-Subscription-Key", resource.speechKey),
                            parts: parts, audioSeconds: seconds)
    }
    let body: Data
    if let backup = credentials.backup {
      body = try await hedged(after: 4 + seconds / 10, { try await request(credentials) }, { try await request(backup) })
    } else {
      body = try await request(credentials)
    }
    let response = try JSONDecoder().decode(MaiResponse.self, from: body)
    return (response.phrases ?? []).map { phrase in
      Phrase(speaker: phrase.speaker, text: oneLine(phrase.text), words: (phrase.words ?? []).map {
        let start = Double($0.offsetMilliseconds) / 1000
        return Word(text: $0.text, start: start, end: start + Double(max($0.durationMilliseconds ?? 0, 1)) / 1000)
      })
    }
  }

  static func oneLine(_ text: String) -> String {
    text.replacingOccurrences(of: "\\s*\\n\\s*", with: " ", options: .regularExpression)
  }

  static func selfTest() {
    precondition(oneLine("और 100 CXOs होंगे।\nI am talking\n\n about\r\nit") == "और 100 CXOs होंगे। I am talking about it")
    print("AzureSpeech selftest ok")
  }

  static func openAI(_ pcm16k: [Float], deployment: String, credentials: AzureCredentials) async throws -> String {
    guard let url = URL(string: trimmed(credentials.openAIEndpoint)
      + "/openai/deployments/\(deployment)/audio/transcriptions?api-version=2025-03-01-preview")
    else { throw AzureError.noCredentials }
    var fields: [(String, Data)] = [("response_format", Data("json".utf8))]
    let prompt = ((Settings.shared.romanizeHindi ? [ModelCatalog.hinglishInstruction] : [])
      + (Vocabulary.terms.isEmpty ? [] : ["Names that may appear: \(Vocabulary.terms.joined(separator: ", "))."]))
      .joined(separator: " ")
    if !prompt.isEmpty { fields.append(("prompt", Data(prompt.utf8))) }
    if Settings.shared.language != "auto" { fields.append(("language", Data(Settings.shared.language.utf8))) }
    let chunks = split(pcm16k, maxSeconds: 150)
    var texts = Array(repeating: "", count: chunks.count)
    // ponytail: every chunk at once, the deployment's TPM is the ceiling; 429s retry in post().
    try await withThrowingTaskGroup(of: (Int, String).self) { group in
      for (i, chunk) in chunks.enumerated() {
        group.addTask {
          let body = try await post(url, provider: "azure-openai-transcribe", header: ("api-key", credentials.openAIKey),
                                    parts: [("file", try flac(chunk))] + fields, audioSeconds: Double(chunk.count) / 16_000)
          return (i, try JSONDecoder().decode(OpenAIResponse.self, from: body).text)
        }
      }
      for try await (i, text) in group { texts[i] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    return texts.filter { !$0.isEmpty }.joined(separator: " ")
  }

  /// gpt-4o(-mini)-transcribe silently stops at 2048 output tokens per request, so long audio goes in
  /// pieces, each cut at the quietest 100 ms of its last 20 s.
  static func split(_ pcm: [Float], maxSeconds: Int) -> [[Float]] {
    let rate = 16_000, limit = maxSeconds * rate, window = rate / 10, search = 20 * rate
    var out: [[Float]] = []
    var start = 0
    while pcm.count - start > limit {
      var cut = start + limit, quietest = Float.infinity
      var w = start + limit - search
      while w + window <= start + limit {
        var energy: Float = 0
        for k in w..<(w + window) { energy += pcm[k] * pcm[k] }
        if energy < quietest { quietest = energy; cut = w + window / 2 }
        w += window
      }
      out.append(Array(pcm[start..<cut]))
      start = cut
    }
    out.append(Array(pcm[start...]))
    return out
  }

  static func flac(_ pcm16k: [Float]) throws -> Data {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bolkit-azure-\(UUID().uuidString).flac")
    defer { try? FileManager.default.removeItem(at: url) }
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(pcm16k.count, 1)))
    else { throw CocoaError(.fileWriteUnknown) }
    buffer.frameLength = AVAudioFrameCount(pcm16k.count)
    pcm16k.withUnsafeBufferPointer { src in
      if let base = src.baseAddress { buffer.floatChannelData![0].update(from: base, count: pcm16k.count) }
    }
    do {
      let file = try AVAudioFile(
        forWriting: url,
        settings: [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1],
        commonFormat: .pcmFormatFloat32, interleaved: false)
      try file.write(from: buffer)
    }
    return try Data(contentsOf: url)
  }

  private static let retryable: Set<URLError.Code> = [
    .timedOut, .networkConnectionLost, .secureConnectionFailed, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
  ]

  private static func post(
    _ url: URL, provider: String, header: (String, String), parts: [(String, Data)], audioSeconds: Double
  ) async throws -> Data {
    let boundary = "bolkit-\(UUID().uuidString)"
    var body = Data()
    for (name, data) in parts {
      body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"".utf8))
      body.append(Data((name == "audio" || name == "file"
        ? "; filename=\"audio.flac\"\r\nContent-Type: audio/flac\r\n\r\n" : "\r\n\r\n").utf8))
      body.append(data)
      body.append(Data("\r\n".utf8))
    }
    body.append(Data("--\(boundary)--\r\n".utf8))
    var request = URLRequest(url: url, timeoutInterval: 300)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue(header.1, forHTTPHeaderField: header.0)
    var delay = 1.0
    for attempt in 0..<3 {
      let data: Data
      let response: URLResponse
      do {
        // timeoutInterval only bounds idle gaps: a request that spanned a Mac sleep hung for 16 minutes.
        (data, response) = try await withDeadline(15 + audioSeconds / 4) {
          try await URLSession.shared.upload(for: request, from: body)
        }
      } catch {
        Usage.shared.recordCloud(provider, failed: !Task.isCancelled, audioSeconds: audioSeconds)
        guard attempt < 2, let urlError = error as? URLError, retryable.contains(urlError.code) else { throw error }
        dlog("azure retry \(attempt + 1) after: \(error.localizedDescription)")
        continue
      }
      let http = response as? HTTPURLResponse
      let status = http?.statusCode ?? 0
      let ok = (200..<300).contains(status)
      let usage = ok ? (try? JSONDecoder().decode(TokenUsage.self, from: data))?.usage : nil
      Usage.shared.recordCloud(provider, failed: !ok, audioSeconds: audioSeconds,
                               inputTokens: usage?.input_tokens ?? 0, outputTokens: usage?.output_tokens ?? 0)
      if ok { return data }
      guard [429, 500, 502, 503, 504].contains(status), attempt < 2 else {
        throw AzureError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
      }
      let wait = min(Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? delay, 10)
      try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
      delay *= 2
    }
    throw AzureError.http(0, "no response")
  }

  /// Starts the backup once the primary fails or is still silent after `delay`; the first answer wins.
  private static func hedged(
    after delay: TimeInterval, _ primary: @escaping () async throws -> Data, _ backup: @escaping () async throws -> Data
  ) async throws -> Data {
    try await withThrowingTaskGroup(of: Data?.self) { group in
      defer { group.cancelAll() }
      group.addTask { try await primary() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return nil
      }
      var backupStarted = false
      var lastError: Error?
      while true {
        do {
          guard let next = try await group.next() else { break }
          if let data = next { return data }
        } catch {
          lastError = error
        }
        if !backupStarted {
          backupStarted = true
          dlog("azure: backup speech resource started (\(lastError.map { "\($0)" } ?? "primary slow"))")
          group.addTask { try await backup() }
        }
      }
      throw lastError ?? AzureError.http(0, "no response")
    }
  }

  private static func withDeadline<T>(_ seconds: TimeInterval, _ work: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await work() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw URLError(.timedOut)
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
  }

  private static func trimmed(_ endpoint: String) -> String {
    var s = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix("/") { s.removeLast() }
    return s
  }

  private struct MaiResponse: Decodable {
    struct W: Decodable {
      let text: String
      let offsetMilliseconds: Int
      let durationMilliseconds: Int?
    }
    struct P: Decodable {
      let speaker: Int?
      let text: String
      let words: [W]?
    }
    let phrases: [P]?
  }

  private struct OpenAIResponse: Decodable { let text: String }

  private struct TokenUsage: Decodable {
    struct Tokens: Decodable {
      let input_tokens: Int?
      let output_tokens: Int?
    }
    let usage: Tokens?
  }
}

/// Azure Speech real-time over the Speech SDK's WebSocket protocol (framing from
/// microsoft/cognitive-services-speech-sdk-js), so no SDK binary ships in the app.
final class AzureRealtime: @unchecked Sendable {
  private static let stamp = ISO8601DateFormatter()
  private static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

  private let socket: URLSessionWebSocketTask
  private let credentials: AzureCredentials
  private var audio = Data()
  private let converter = ModernAnalyzerInputConverter(analyzerFormat: AzureRealtime.pcmFormat)
  private let lock = NSLock()
  private var requestId = AzureRealtime.newId()
  private var phrases: [String] = []
  private var hypothesis = ""
  private var finishing = false
  private var closed = false
  private var failed = false
  private var onText: (String) -> Void = { _ in }
  private var onFailure: (String) -> Void = { _ in }
  private var onEnd: ((String) -> Void)?

  init?(credentials: AzureCredentials, locale: String) {
    var url = URLComponents()
    url.scheme = "wss"
    url.host = "\(credentials.region).stt.speech.microsoft.com"
    url.path = "/speech/recognition/conversation/cognitiveservices/v1"
    url.queryItems = [URLQueryItem(name: "language", value: locale), URLQueryItem(name: "format", value: "simple")]
    guard let endpoint = url.url else { return nil }
    self.credentials = credentials
    var request = URLRequest(url: endpoint)
    request.setValue(credentials.speechKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
    request.setValue(Self.newId(), forHTTPHeaderField: "X-ConnectionId")
    socket = URLSession.shared.webSocketTask(with: request)
  }

  func start(onText: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
    self.onText = onText
    self.onFailure = onFailure
    socket.resume()
    receive()
    socket.send(.string(headers("speech.config", type: "application/json") + "\r\n"
      + #"{"context":{"system":{"name":"Bolkit","version":"1"},"os":{"platform":"macOS","name":"macOS"}}}"#)) { _ in }
    sendWaveHeader()
  }

  func feed(_ buffer: AVAudioPCMBuffer) {
    guard let pcm = try? converter.convert(buffer), let samples = pcm.int16ChannelData?[0] else { return }
    let chunk = Data(bytes: samples, count: Int(pcm.frameLength) * 2)
    lock.withLock { audio.append(chunk) }
    send(audio: chunk)
  }

  func finish(timeout: TimeInterval = 8, completion: @escaping (String) -> Void) {
    let dead = lock.withLock {
      finishing = true
      onEnd = completion
      return closed
    }
    if dead { return complete() }
    send(audio: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [self] in
      if lock.withLock({ self.onEnd != nil }) { dlog("azure live: no turn.end after \(Int(timeout)) s") }
      complete()
    }
  }

  func cancel() {
    socket.cancel(with: .normalClosure, reason: nil)
    recordUsage()
  }

  private func recordUsage() {
    let (failed, seconds) = lock.withLock { (self.failed, Double(audio.count) / 32_000) }
    Usage.shared.recordCloud("azure-speech-realtime", failed: failed, audioSeconds: seconds)
  }

  private var text: String { (phrases + (hypothesis.isEmpty ? [] : [hypothesis])).joined(separator: " ") }

  private func complete() {
    let (done, final, recorded): (((String) -> Void)?, String, Data) = lock.withLock {
      defer { onEnd = nil }
      return (onEnd, text, audio)
    }
    guard let done else { return }
    socket.cancel(with: .normalClosure, reason: nil)
    recordUsage()
    guard final.isEmpty, !recorded.isEmpty else { return DispatchQueue.main.async { done(final) } }
    dlog("azure live: no text, falling back to MAI-Transcribe-2")
    let pcm = recorded.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)).map { Float($0) / 32_768 } }
    Task { [credentials] in
      let phrases = (try? await AzureSpeech.mai(pcm, credentials: credentials)) ?? []
      DispatchQueue.main.async { done(phrases.map(\.text).joined(separator: " ")) }
    }
  }

  private func receive() {
    socket.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        lock.withLock { self.closed = true }
        let reason = socket.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if !lock.withLock({ self.finishing }) {
          lock.withLock { self.failed = true }
          let status = (socket.response as? HTTPURLResponse)?.statusCode ?? socket.closeCode.rawValue
          dlog("azure live closed: \(status) \(reason) \(error.localizedDescription)")
          onFailure(status == 401 || status == 403
            ? "Azure rejected the key (\(status)), check it in Dashboard, Models"
            : "Azure real-time stopped (\(status)) \(reason)")
        }
        complete()
      case .success(.string(let message)):
        handle(message)
        receive()
      case .success:
        receive()
      }
    }
  }

  private func handle(_ message: String) {
    let split = message.components(separatedBy: "\r\n\r\n")
    let path = split[0].split(separator: "\r\n").first { $0.lowercased().hasPrefix("path:") }
      .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    let body = Data(split.dropFirst().joined(separator: "\r\n\r\n").utf8)
    switch path {
    case "speech.hypothesis":
      guard let hyp = try? JSONDecoder().decode(Hypothesis.self, from: body) else { return }
      let visible = lock.withLock { hypothesis = hyp.Text; return text }
      onText(visible)
    case "speech.phrase":
      guard let phrase = try? JSONDecoder().decode(Phrase.self, from: body), phrase.RecognitionStatus == "Success"
      else { return }
      let visible = lock.withLock {
        if let display = phrase.DisplayText, !display.isEmpty { phrases.append(display) }
        hypothesis = ""
        return text
      }
      onText(visible)
    case "turn.end":
      if lock.withLock({ finishing }) {
        complete()
      } else {
        // The service closes a turn after ~15 s of silence; a new request id opens the next one.
        lock.withLock { requestId = Self.newId() }
        sendWaveHeader()
      }
    default:
      break
    }
  }

  private func sendWaveHeader() {
    var wav = Data("RIFF".utf8)
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
    le32(0); wav.append(Data("WAVEfmt ".utf8)); le32(16); le16(1); le16(1); le32(16_000); le32(32_000); le16(2); le16(16)
    wav.append(Data("data".utf8)); le32(0)
    send(audio: wav, type: "audio/x-wav")
  }

  private func send(audio: Data?, type: String? = nil) {
    let head = Data(headers("audio", type: type).utf8)
    var message = Data([UInt8(head.count >> 8), UInt8(head.count & 0xff)])
    message.append(head)
    if let audio { message.append(audio) }
    socket.send(.data(message)) { _ in }
  }

  private func headers(_ path: String, type: String?) -> String {
    let id = lock.withLock { requestId }
    return "Path: \(path)\r\nX-RequestId: \(id)\r\nX-Timestamp: \(Self.stamp.string(from: Date()))\r\n"
      + (type.map { "Content-Type: \($0)\r\n" } ?? "")
  }

  private static func newId() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }

  private struct Hypothesis: Decodable { let Text: String }
  private struct Phrase: Decodable {
    let RecognitionStatus: String
    let DisplayText: String?
  }
}

struct AzureSettingsView: View {
  @ObservedObject var settings = Settings.shared
  @State private var credentials = AzureCredentials.saved ?? AzureCredentials()
  @State private var message = ""

  var body: some View {
    Toggle("Use Azure cloud speech", isOn: $settings.azureEnabled)
      .font(.system(size: 13))
    Text("Sends your audio to Microsoft Azure to turn it into text. Off by default. When it is off, everything stays on this Mac.")
      .font(.caption).foregroundColor(Mono.textDim)

    Picker("Model", selection: $settings.azureModelId) {
      ForEach(AzureSpeech.specs) { Text($0.label).tag($0.id) }
    }
    .font(.system(size: 13))
    if let spec = ModelCatalog.spec(settings.azureModelId) {
      Text(spec.note).font(.caption).foregroundColor(Mono.textFaint)
    }

    Divider().overlay(Mono.border)
    Text("Speech resource (MAI-Transcribe-2 and real-time)").font(.system(size: 12, weight: .semibold)).foregroundColor(Mono.text)
    SecureField("Key", text: $credentials.speechKey).textFieldStyle(.roundedBorder)
    TextField("Region, for example southeastasia", text: $credentials.region).textFieldStyle(.roundedBorder)
    TextField("Endpoint, https://<name>.cognitiveservices.azure.com/", text: $credentials.endpoint).textFieldStyle(.roundedBorder)
    Text("Azure OpenAI resource (GPT-4o models only)").font(.system(size: 12, weight: .semibold)).foregroundColor(Mono.text)
    SecureField("Key", text: $credentials.openAIKey).textFieldStyle(.roundedBorder)
    TextField("Endpoint, https://<name>.openai.azure.com/", text: $credentials.openAIEndpoint).textFieldStyle(.roundedBorder)
    HStack {
      Button("Save to Keychain") {
        message = credentials.save() ? "Saved in your Keychain." : "Could not save to the Keychain."
      }
      #if !MAS
      Button("Load from ~/.config/azure-speech/bolkit.env") {
        guard let found = AzureCredentials.fromEnvFiles() else { message = "No Azure keys found in ~/.config."; return }
        credentials = found
        message = found.save() ? "Loaded and saved in your Keychain." : "Loaded, but the Keychain save failed."
      }
      #endif
    }
    .font(.system(size: 12))
    if !message.isEmpty {
      Text(message).font(.caption).foregroundColor(Mono.textDim)
    }
  }
}
