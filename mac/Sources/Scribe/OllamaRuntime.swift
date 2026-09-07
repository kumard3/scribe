import Foundation

/// Talks to a local Ollama server over its two JSON endpoints. Every model the
/// user has pulled (`ollama pull gemma4:e2b`) becomes a cleanup/summary engine
/// without Scribe downloading or managing a single byte.
///
/// Text only: Ollama's API takes `images`, never audio, so transcription stays
/// on the llama.cpp path.
enum OllamaRuntime {
  static var host: String {
    let raw = Settings.shared.ollamaHost.trimmingCharacters(in: .whitespaces)
    let base = raw.isEmpty ? "http://127.0.0.1:11434" : raw
    return base.hasSuffix("/") ? String(base.dropLast()) : base
  }

  /// Installed model names, newest first. Empty when the server is not running.
  static func list(completion: @escaping ([String]) -> Void) {
    guard let url = URL(string: "\(host)/api/tags") else {
      completion([])
      return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 4
    URLSession.shared.dataTask(with: request) { data, _, _ in
      let models = (data.flatMap {
        try? JSONDecoder().decode(TagsResponse.self, from: $0)
      })?.models.map(\.name) ?? []
      DispatchQueue.main.async { completion(models) }
    }.resume()
  }

  /// nil = server unreachable, model missing, or empty output.
  static func chat(model: String, instruction: String, text: String,
                   maxTokens: Int, completion: @escaping (String?) -> Void) {
    guard !model.isEmpty, let url = URL(string: "\(host)/api/chat") else {
      completion(nil)
      return
    }
    let body: [String: Any] = [
      "model": model,
      "stream": false,
      "think": false,
      "messages": [
        ["role": "system", "content": instruction],
        ["role": "user", "content": text],
      ],
      "options": ["temperature": 0.2, "num_predict": maxTokens],
    ]
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    // A cold 3 GB model on a laptop CPU can take a minute to load and answer.
    request.timeoutInterval = 180
    URLSession.shared.dataTask(with: request) { data, _, error in
      var out: String?
      if let data, let reply = try? JSONDecoder().decode(ChatResponse.self, from: data) {
        out = strippedThinking(reply.message.content)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      } else if let error {
        dlog("ollama failed: \(error.localizedDescription)")
      }
      DispatchQueue.main.async { completion(out?.isEmpty == false ? out : nil) }
    }.resume()
  }

  /// Reasoning models leak a <think> block into content when the server is too
  /// old to honour "think": false. Cleanup must never paste that into the
  /// user's document.
  static func strippedThinking(_ s: String) -> String {
    guard let open = s.range(of: "<think>") else { return s }
    guard let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) else {
      return String(s[..<open.lowerBound])
    }
    return String(s[..<open.lowerBound]) + String(s[close.upperBound...])
  }

  static func selfTest() {
    precondition(strippedThinking("<think>weighing</think>Done.") == "Done.")
    precondition(strippedThinking("Head <think>x</think> tail") == "Head  tail")
    // An unterminated block means the model was cut off mid-reasoning; keeping
    // the tail would paste the reasoning itself into the user's document.
    precondition(strippedThinking("Keep me.<think>cut off") == "Keep me.")
    precondition(strippedThinking("plain text") == "plain text")
  }

  private struct TagsResponse: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
  }

  private struct ChatResponse: Decodable {
    struct Message: Decodable { let content: String }
    let message: Message
  }
}
