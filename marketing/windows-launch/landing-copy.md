# Scribe for Windows: Landing Page Copy

Design notes: monochrome, white/grey text on black. The black pill overlay from the app is the hero visual. No stock photos, no gradients. All body copy plain and confident. Verify every spec marked [verify] against the shipped build before publishing.

---

## Hero

**Headline:**
Dictation that stays on your machine.

**Subhead:**
Scribe is a native Windows app. Hold a key, speak, release, and the text lands in whatever app you are using. Every word is transcribed on your CPU. Nothing is sent anywhere, ever.

**Primary CTA:** Download for Windows (free)
**Secondary CTA:** Read the source on GitHub

**Under-CTA line:** Windows 10/11, x64. No account. No telemetry. ~370 MB one-time model download.

---

## The three pains

### Your voice is not cloud data
Most dictation apps upload everything you say to their servers, and some have shipped more than your voice. Wispr Flow was found capturing screenshots of users' active windows and sending them to cloud servers, and banned the user who reported it before apologizing publicly [1]. Scribe cannot have that problem. There is no server. The recognition model runs on your CPU and the code is open for anyone to check.

### Built for Windows, not ported to it
Windows users get the leftovers in this category: an 800 MB Electron port that users report freezing their editors [2], or Mac apps with a young Windows build. Scribe's Windows app is a native .NET tray app. It idles quietly, draws a small black pill when you speak, and types into any app that accepts text.

### Software you buy once
Dictation subscriptions run up to $180 a year, and Dragon's consumer editions were discontinued entirely, leaving people who paid up to $699 with no upgrade path [3]. Scribe's core is free forever. The Pro features are a single one-time purchase. No account to cancel, because there is no account.

---

## How it works

1. **Hold Right Ctrl and speak.** Push-to-talk, or tap once for hands-free until you tap again. The hotkey is configurable.
2. **Watch it appear.** A black pill at the bottom of the screen shows live audio levels and the words as they are recognized.
3. **Release.** The text is inserted into whatever field has focus, and your previous clipboard is restored.
4. **That is the whole loop.** First launch downloads the speech model once. After that, airplane mode works fine.

---

## Features

- Native Windows tray app (.NET, no Electron)
- Streaming on-device recognition on CPU, no GPU required
- Push-to-talk or hands-free tap-to-toggle
- Types into any focused app, restores your clipboard afterward
- Configurable hotkey: Right Ctrl, Right Alt, Caps Lock, F8, Scroll Lock, Pause
- Model choice: streaming default, plus Whisper, Moonshine, Parakeet, Nemotron [verify shipped list]
- Hindi and Hinglish modes, multilingual models for 40+ languages
- Pro: on-device AI cleanup (Gemma) that turns rambling speech into clean text, still fully offline
- Recent-transcripts list in a dashboard that matches the pill: white on black, nothing else
- No account, no telemetry, no network traffic after model download
- MIT-licensed source

---

## Comparison

Every row below is verifiable; footnotes cite sources for competitor claims.

| | Scribe | Wispr Flow (Windows) | Superwhisper (Windows) | Handy | Win+H voice typing |
|---|---|---|---|---|---|
| Where speech is processed | On your device | Cloud servers [1] | Local or cloud models | On your device | Microsoft online service [5] |
| Works offline | Yes | No | Partly (local models) | Yes | No |
| Price | Free; Pro $49 one-time | $15/mo, $12/mo annual [4] | $8.49/mo or $249.99 lifetime [4] | Free (MIT) | Free (built in) |
| Account required | No | Yes | No | No | No |
| Windows app | Native .NET tray app | Electron port; ~800 MB RAM reported [2] | Windows port of a Mac-first app [4] | Native (Tauri) | Built in |
| AI cleanup of transcript | Yes, on-device (Pro) | Yes, in the cloud | Yes, cloud or local | No, verbatim only | No |
| Hindi/Hinglish modes | Yes | Not offered as a dedicated mode | Not offered as a dedicated mode | Not offered | No |
| Open source | Yes, MIT | No | No | Yes, MIT | No |

---

## Download / pricing CTA block

**Scribe Free**
Everything you need to dictate: streaming on-device recognition, all hotkeys, hands-free mode, every language model. Free forever. Not a trial.

**Scribe Pro: $49, once**
On-device AI cleanup, custom vocabulary [verify shipped], and priority support. One license, yours permanently, all future updates. Launch price $39 for the first month.

**Accessibility program:** If you dictate because of RSI, injury, or disability and the price is a barrier, write to us and we will send you a Pro license. No proof required.

CTA button: **Download Scribe for Windows**
Fine print: Unsigned beta builds may show a SmartScreen prompt until our signing certificate propagates reputation. The installer is [size] MB; the speech model (~370 MB) downloads on first launch.

---

## FAQ

**Is it really offline?**
Yes. After the one-time model download, Scribe makes no network requests. Turn on airplane mode and dictate; it works identically. The source is on GitHub if you want to verify that claim rather than trust it.

**What data leaves my machine?**
None. No audio, no text, no screenshots, no analytics, no crash reports. There is no account system and no telemetry endpoint in the code.

**How well does it handle accents and Hinglish?**
Better than apps tuned only for American English, because you pick the model. Scribe has dedicated Hindi and Hinglish modes and multilingual models covering 40+ languages. If the default model misses your accent, switch models in the dashboard; they are free.

**I have RSI / I dictate out of necessity. Is Scribe usable hands-free?**
Yes. Tap the hotkey once to start, tap again to stop, no holding required. We will not match Dragon Professional's full command-and-control of Windows, and we say so plainly. For getting text into any app without typing, Scribe is built for exactly that, and it will not be discontinued out from under you: the code is MIT, so it outlives us either way.

**Why isn't everything free forever?**
The core is. Dictation, all speech models, all hotkeys: free, no limits, no trial clock. The one-time Pro license funds development so we never need the things we are against: subscriptions, accounts, or selling data. If you would rather not pay, the free tier is complete and the source builds on your machine.

**How much disk space do the models need?**
The default streaming model is about 370 MB. Optional models range from roughly 60 MB (Moonshine tiny) to about 1.5 GB for the largest multilingual options [verify final catalog]. You choose what to download; nothing is bundled.

**Do I need a GPU?**
No. Recognition runs on CPU in real time. The optional Pro cleanup model also runs on CPU; a recent processor makes it snappier, but nothing requires a graphics card.

**Which apps does it work in?**
Any app with a text field: Word, Outlook, browsers, Slack, VS Code, terminals, chat boxes for Claude or ChatGPT. Scribe inserts text via a paste that restores your clipboard afterward. Rare exceptions: apps running as Administrator won't accept input from a normal-privilege app (run Scribe as admin for those), and some secure fields block synthetic paste by design.

**How is this different from Handy?**
We like Handy; it proved free on-device dictation works. Handy is verbatim only. Scribe adds on-device AI cleanup (so "um so basically we should uh ship on Friday" becomes "We should ship on Friday"), Hindi/Hinglish modes, a wider model catalog, and a Mac and Android app with the same design. If verbatim is all you need and Handy fits, use Handy. Both are MIT.

**What about refunds?**
30 days, no questions, on the Pro license. Email us and we refund it.

**Which Windows versions?**
Windows 10 and 11, x64. [verify: arm64 status before publishing]

**Is my microphone always on?**
No. The microphone is only open while the hotkey is held (or between taps in hands-free mode). The pill on screen shows exactly when audio is being captured.

**Will you add a subscription later?**
No. If we ever add paid services with real recurring costs, they will be separate and optional. The Pro license you buy covers Scribe Pro permanently.

---

## Footnotes

[1] Screenshot capture and the banning of the user who reported it, followed by a public apology from Wispr's CTO: https://modelpiper.com/blog/wispr-flow-privacy-incident and https://embertype.com/blog/the-day-wispr-flow-banned-a-user/
[2] User reports of ~800 MB RAM usage and freezing in target apps for the Electron-based Windows client: https://spokenly.app/blog/wispr-flow-review
[3] Dragon consumer editions discontinued; remaining product is Dragon Professional from $699: https://en.wikipedia.org/wiki/Dragon_NaturallySpeaking and https://www.dictationdaddy.com/blog/dragon-speak-software
[4] Pricing as listed on vendor sites, July 2026: Wispr Flow $15/mo ($12/mo annual); Superwhisper $8.49/mo or $249.99 lifetime, macOS-first with a newer Windows build. https://www.getvoibe.com/resources/superwhisper-pricing/
[5] Microsoft documents that voice typing requires an internet connection; Voice Access works offline but is focused on voice control rather than long-form dictation.
