import UIKit

/// Keyboards can't use the microphone, so Bolkit records. The first mic tap opens Bolkit, which
/// starts a Flow session and listens right away; after the user swipes back, later taps start and
/// stop dictation in place and the text is typed straight into the field.
class KeyboardViewController: UIInputViewController {
  private let status = UILabel()
  private let mic = UIButton(type: .system)
  private let cancel = UIButton(type: .system)
  private let globe = UIButton(type: .system)
  private var phase = FlowPhase.off
  private var visible = false
  private var startCheck: Timer?

  private static func rgb(_ hex: Int) -> UIColor {
    UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }

  private let surface = rgb(0x1C1C1F)
  private let textDim = rgb(0x9A9AA3)

  override func viewDidLoad() {
    super.viewDidLoad()
    buildUI()
    FlowShared.observe(FlowShared.changed) { [weak self] in self?.refresh() }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    visible = true
    refresh()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    visible = false
  }

  override func viewWillLayoutSubviews() {
    globe.isHidden = !needsInputModeSwitchKey
    super.viewWillLayoutSubviews()
  }

  private func buildUI() {
    view.backgroundColor = .black

    status.textColor = textDim
    status.font = .systemFont(ofSize: 14, weight: .medium)
    status.textAlignment = .center
    status.numberOfLines = 2

    circle(mic, size: 72, fill: .white, tint: .black, symbol: "mic.fill", action: #selector(micTapped))
    circle(cancel, size: 48, fill: surface, tint: .white, symbol: "xmark", action: #selector(cancelTapped))
    mic.accessibilityLabel = "Dictate"
    cancel.accessibilityLabel = "Cancel dictation"

    let space = key(title: "space", action: #selector(spaceTapped))
    let row = UIStackView(arrangedSubviews: [
      globe,
      space,
      key(symbol: "delete.left", action: #selector(backspaceTapped)),
      key(symbol: "return", action: #selector(returnTapped)),
    ])
    configure(globe, symbol: "globe")
    globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
    row.spacing = 6
    row.arrangedSubviews.filter { $0 !== space }.forEach { $0.widthAnchor.constraint(equalToConstant: 56).isActive = true }

    [status, mic, cancel, row].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview($0)
    }
    NSLayoutConstraint.activate([
      status.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
      status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      mic.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
      mic.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      cancel.centerYAnchor.constraint(equalTo: mic.centerYAnchor),
      cancel.trailingAnchor.constraint(equalTo: mic.leadingAnchor, constant: -32),
      row.topAnchor.constraint(equalTo: mic.bottomAnchor, constant: 16),
      row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
      row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
      row.heightAnchor.constraint(equalToConstant: 44),
      row.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
    ])
  }

  private func circle(_ b: UIButton, size: CGFloat, fill: UIColor, tint: UIColor, symbol: String, action: Selector) {
    b.backgroundColor = fill
    b.tintColor = tint
    b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.36, weight: .semibold)), for: .normal)
    b.layer.cornerRadius = size / 2
    b.widthAnchor.constraint(equalToConstant: size).isActive = true
    b.heightAnchor.constraint(equalToConstant: size).isActive = true
    b.addTarget(self, action: action, for: .touchUpInside)
  }

  private func configure(_ b: UIButton, symbol: String? = nil, title: String? = nil) {
    b.backgroundColor = surface
    b.tintColor = .white
    b.layer.cornerRadius = 8
    if let symbol { b.setImage(UIImage(systemName: symbol), for: .normal) }
    if let title {
      b.setTitle(title, for: .normal)
      b.setTitleColor(.white, for: .normal)
      b.titleLabel?.font = .systemFont(ofSize: 16)
    }
  }

  private func key(symbol: String? = nil, title: String? = nil, action: Selector) -> UIButton {
    let b = UIButton(type: .system)
    configure(b, symbol: symbol, title: title)
    b.addTarget(self, action: action, for: .touchUpInside)
    return b
  }

  private var requests: [String] {
    get { UserDefaults.standard.stringArray(forKey: "flowRequests") ?? [] }
    set { UserDefaults.standard.set(Array(newValue.suffix(10)), forKey: "flowRequests") }
  }

  private func refresh() {
    let state = FlowShared.read()
    phase = state.alive ? state.phase : .off
    if visible, let request = state.resultRequest, requests.contains(request) {
      requests = []
      if let text = state.resultText, !text.isEmpty, let at = state.resultAt, Date().timeIntervalSince(at) < 60 {
        insert(text)
      }
    }
    render(error: state.error)
  }

  private func render(error: String?) {
    let listening = phase == .listening
    let config = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
    mic.setImage(UIImage(systemName: listening ? "checkmark" : "mic.fill", withConfiguration: config), for: .normal)
    mic.accessibilityLabel = listening ? "Done" : "Dictate"
    mic.isEnabled = phase != .transcribing
    mic.alpha = mic.isEnabled ? 1 : 0.4
    cancel.isHidden = !listening
    if !hasFullAccess {
      status.text = "Turn on Allow Full Access for Bolkit Voice in Settings"
      return
    }
    switch phase {
    case .off: status.text = "Open Bolkit to start: tap the mic"
    case .idle: status.text = error ?? "Tap the mic to dictate"
    case .listening: status.text = "Listening"
    case .transcribing: status.text = "Transcribing"
    }
  }

  private func insert(_ text: String) {
    let before = textDocumentProxy.documentContextBeforeInput ?? ""
    let glue = before.last.map { !$0.isWhitespace } ?? false
    textDocumentProxy.insertText(glue ? " " + text : text)
  }

  @objc private func micTapped() {
    guard hasFullAccess else { return render(error: nil) }
    switch phase {
    case .listening:
      FlowShared.request(FlowShared.stop)
    case .idle:
      status.text = "Starting"
      requests.append(FlowShared.request(FlowShared.start))
      startCheck?.invalidate()
      startCheck = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
        guard let self, self.phase == .idle else { return }
        self.openBolkit()
      }
    case .off:
      openBolkit()
    case .transcribing:
      break
    }
  }

  @objc private func cancelTapped() { FlowShared.request(FlowShared.cancel) }

  // No public API opens the containing app from a keyboard; UIApplication from the responder
  // chain still works on iOS 26 and 27 and is what other dictation keyboards ship.
  private func openBolkit() {
    status.text = "Opening Bolkit"
    guard let url = URL(string: "scribe://flow") else { return }
    requests.append(FlowShared.request(FlowShared.start))
    var responder: UIResponder? = self
    while let r = responder {
      if let app = r as? UIApplication {
        app.open(url, options: [:], completionHandler: nil)
        return
      }
      responder = r.next
    }
  }

  @objc private func spaceTapped() { textDocumentProxy.insertText(" ") }
  @objc private func backspaceTapped() { textDocumentProxy.deleteBackward() }
  @objc private func returnTapped() { textDocumentProxy.insertText("\n") }
}
