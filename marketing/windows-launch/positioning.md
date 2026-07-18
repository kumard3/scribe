# Scribe for Windows: Positioning

One line: **Native Windows dictation that runs entirely on your machine. No cloud, no account, no subscription.**

## The market moment

Windows is the underserved platform in dictation. The category leader is cloud-only and shipped Windows as an afterthought. The Mac-first challenger's Windows port is immature. Dragon abandoned consumers. The built-in option is widely considered poor. The loudest complaints across the category are cloud privacy, subscription fatigue, Windows neglect, accent accuracy, and reliability collapse after payment. Scribe's architecture answers the first three by design and the fourth by model choice.

## Who we win first

Ordered by fit and reachability.

### 1. Privacy-conscious professionals
Lawyers, doctors, therapists, journalists, anyone whose dictation contains things that must not transit a third-party server. Wispr Flow's screenshot incident made this segment actively distrustful of cloud dictation [1]. For them "on-device" is not a feature, it is the purchase criterion. Scribe's claim is absolute and auditable: the code is MIT-licensed, and no audio or text ever leaves the machine.

### 2. Dragon orphans and RSI/accessibility users
People who paid $150-699 for Dragon consumer editions that are now discontinued, with only a $699 enterprise product left [2]. Many dictate out of necessity, not preference. They already proved they will pay one-time prices for software they depend on. They need reliability, hands-free operation (Scribe has tap-to-toggle), and a vendor that will not orphan them. Approach with respect: these are expert dictation users who will notice every rough edge.

### 3. Developers dictating AI prompts
The new dictation use case: talking to Claude, Cursor, and ChatGPT is faster than typing paragraphs of prompt. Developers are the most privacy-literate and subscription-fatigued segment, they distrust Electron, and they respect a native tray app with a small footprint. They are also where Handy's 20k GitHub stars came from, which proves the demand and the channel.

### 4. Non-native English speakers, including Hinglish users
Accent accuracy is a top complaint against every incumbent. Scribe ships dedicated Hindi and Hinglish modes and multilingual models (Nemotron multilingual covers 40+ languages), all on-device. Nobody else is marketing to the Hinglish dictation user on Windows at all. Small wedge globally, enormous wedge in India, and the diaspora tech workforce overlaps heavily with segment 3.

## One-sentence wedge per competitor

- **vs Wispr Flow:** Everything you dictate to Wispr goes to their servers, and their Windows app is a heavy Electron port; Scribe is a native tray app and nothing you say leaves your machine. [1][3]
- **vs Superwhisper:** Superwhisper is a Mac app first, its Windows port came second, and its lifetime price is $249.99; Scribe is built for Windows and the Pro license is a fraction of that. [4]
- **vs Dragon:** Dragon left its consumer users behind with only a $699 enterprise product remaining; Scribe is the one-time-purchase successor for people who dictate because they must. [2]
- **vs Handy:** Handy proved free on-device dictation works and we respect it; Scribe adds what verbatim transcription cannot do: on-device AI cleanup, Hindi/Hinglish modes, and a wider model catalog, still with zero cloud.
- **vs Win+H:** The built-in voice typing needs an internet connection and its accuracy is a common complaint; Scribe is fully offline and lets you pick the model that fits your voice.

## The honest "why us"

Three things, all literally true:

1. **Native and on-device.** A .NET tray app using sherpa-onnx on CPU. Streaming recognition, push-to-talk or hands-free, text lands in whatever app has focus and your clipboard is restored afterward. No Electron, no webview shell around a cloud API.
2. **Cleanup without the cloud.** Optional on-device LLM cleanup (Gemma via llama.cpp) turns verbatim speech into clean text. This is the feature the subscription apps use to justify $15/mo, running locally, paid for once.
3. **No subscription, no account, no telemetry.** Free core forever. One-time Pro license. The source is MIT on GitHub, so the privacy claim is inspectable, not marketing.

## What we do not claim

Honesty is the brand. Do not claim: medical/legal certification, Dragon-level custom command grammars (Dragon Professional still wins for full voice control of the OS), voice editing of arbitrary text, or accuracy superiority without benchmarks we have run. When a competitor is better at something, say so.

---

[1] Wispr Flow screenshot capture and user ban, later acknowledged with a public apology from the CTO: https://modelpiper.com/blog/wispr-flow-privacy-incident and https://embertype.com/blog/the-day-wispr-flow-banned-a-user/
[2] Dragon consumer editions discontinued; Dragon Professional from $699 remains: https://en.wikipedia.org/wiki/Dragon_NaturallySpeaking and https://www.dictationdaddy.com/blog/dragon-speak-software
[3] Wispr Flow Trustpilot 2.7/5: https://www.trustpilot.com/review/wisprflow.ai ; Windows Electron app resource usage and freezing reports: https://spokenly.app/blog/wispr-flow-review
[4] Superwhisper pricing $8.49/mo or $249.99 lifetime: https://www.getvoibe.com/resources/superwhisper-pricing/
