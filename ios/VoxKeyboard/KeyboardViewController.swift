import UIKit

// Vox voice keyboard (iOS). Apple forbids keyboard extensions from using the
// microphone, so this keyboard hands off to the main Vox app to record
// on-device. Same pattern Wispr Flow uses, but transcription stays on-device.
//
// Handoff: tap Dictate -> opens Vox via vox://dictate-session -> speak (on-device)
// -> Vox copies the result to the clipboard -> swipe back -> tap Paste to insert.
// (Clipboard is used instead of an App Group so no special provisioning is needed.)
class KeyboardViewController: UIInputViewController {
  private var statusLabel: UILabel!

  override func viewDidLoad() {
    super.viewDidLoad()
    buildUI()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    refreshHint()
  }

  private func buildUI() {
    view.backgroundColor = UIColor(red: 0x0E / 255, green: 0x0F / 255, blue: 0x13 / 255, alpha: 1)

    statusLabel = UILabel()
    statusLabel.textColor = UIColor(white: 0.62, alpha: 1)
    statusLabel.font = .systemFont(ofSize: 14)
    statusLabel.textAlignment = .center

    let mic = UIButton(type: .system)
    mic.setTitle("🎤  Dictate", for: .normal)
    mic.setTitleColor(.white, for: .normal)
    mic.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
    mic.backgroundColor = UIColor(red: 0x14 / 255, green: 0xB8 / 255, blue: 0xA6 / 255, alpha: 1)
    mic.layer.cornerRadius = 12
    mic.addTarget(self, action: #selector(startDictation), for: .touchUpInside)
    mic.heightAnchor.constraint(equalToConstant: 56).isActive = true

    let row = UIStackView(arrangedSubviews: [
      secondaryButton("⌨", #selector(nextKeyboard)),
      secondaryButton("📋 Paste", #selector(pasteDictation)),
      secondaryButton("space", #selector(space)),
      secondaryButton("⌫", #selector(backspace)),
      secondaryButton("⏎", #selector(newline)),
    ])
    row.axis = .horizontal
    row.distribution = .fillEqually
    row.spacing = 8

    let stack = UIStackView(arrangedSubviews: [statusLabel, mic, row])
    stack.axis = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
    ])
  }

  private func secondaryButton(_ title: String, _ action: Selector) -> UIButton {
    let b = UIButton(type: .system)
    b.setTitle(title, for: .normal)
    b.setTitleColor(UIColor(white: 0.9, alpha: 1), for: .normal)
    b.titleLabel?.font = .systemFont(ofSize: 15)
    b.backgroundColor = UIColor(red: 0x1B / 255, green: 0x1D / 255, blue: 0x24 / 255, alpha: 1)
    b.layer.cornerRadius = 10
    b.heightAnchor.constraint(equalToConstant: 46).isActive = true
    b.addTarget(self, action: action, for: .touchUpInside)
    return b
  }

  private func refreshHint() {
    if let s = UIPasteboard.general.string, !s.isEmpty {
      statusLabel.text = "Tap 📋 Paste to insert your dictation"
    } else {
      statusLabel.text = "Tap Dictate to speak in Vox"
    }
  }

  @objc private func startDictation() {
    statusLabel.text = "Dictate in Vox, then swipe back and tap Paste"
    openContainingApp(URL(string: "vox://dictate-session")!)
  }

  // A keyboard extension can't call UIApplication.open directly, so walk the
  // responder chain to whoever responds to openURL: — the standard workaround.
  private func openContainingApp(_ url: URL) {
    let selector = sel_registerName("openURL:")
    var responder: UIResponder? = self
    while let r = responder {
      if r.responds(to: selector) {
        r.perform(selector, with: url)
        return
      }
      responder = r.next
    }
  }

  @objc private func pasteDictation() {
    guard let s = UIPasteboard.general.string, !s.isEmpty else { return }
    textDocumentProxy.insertText(s)
  }

  @objc private func nextKeyboard() { advanceToNextInputMode() }
  @objc private func space() { textDocumentProxy.insertText(" ") }
  @objc private func backspace() { textDocumentProxy.deleteBackward() }
  @objc private func newline() { textDocumentProxy.insertText("\n") }
}
