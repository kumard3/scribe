# Scribe for Windows: 30-Day Launch Plan

## Day 0 gate (nothing ships until all four are true)

Per PRODUCTION.md the Windows build is compile-verified only. Before any public post:

1. Full test pass on at least two real Windows machines (one older CPU): dictation, hotkey changes, hands-free, clipboard restore, model download on slow network, Pro cleanup, uninstall.
2. Code-signing certificate acquired and the installer signed (SmartScreen warnings kill conversion in every channel below).
3. Installer built (Inno Setup) and download hosted with a server-side download counter (our only funnel metric; no telemetry).
4. Landing page live with the copy in landing-copy.md, all [verify] items resolved, license purchase flow tested end to end including refund.

If the gate slips, everything slips. Do not soft-launch an unsigned exe to communities we only get one first impression with.

---

## Week 1 (days 1-7): developer channels, our home turf

### Day 1: Show HN

Post the text below. Be in the thread all day answering; the comments are the launch.

**Title:** Show HN: Scribe, native on-device dictation for Windows (no cloud, no subscription)

**Body:**

> I built Scribe because every dictation app I tried on Windows wanted my audio in their cloud, a monthly payment, or both.
>
> Scribe is a native .NET tray app. Hold Right Ctrl, speak, release, and the text is typed into whatever has focus (your clipboard is restored afterward). Recognition is streaming, on-CPU, via sherpa-onnx. Tap instead of hold for hands-free. A small on-screen pill shows levels and partial text so you always know when the mic is open.
>
> Things I care about that it does:
>
> - Fully offline after a one-time ~370 MB model download. Airplane mode works.
> - No account, no telemetry, no network calls. The code is MIT on GitHub, so you can check that instead of trusting me.
> - Model choice, including Hindi/Hinglish modes and multilingual models. If the default misses your accent, switch models.
> - Optional on-device LLM cleanup (Gemma via llama.cpp) that turns rambling speech into clean text. Also offline.
>
> Pricing: the dictation core is free forever, no trial clock. The cleanup and custom vocabulary are a one-time $39 license at launch ($49 after). No subscription, because charging monthly for compute that runs on your CPU never made sense to me. If you dictate because of RSI or disability and the price is a barrier, email me and I'll send you a license.
>
> Honest limitations: it's Windows 10/11 x64, it inserts text rather than doing Dragon-style voice control of the OS, apps running as Administrator need Scribe elevated too, and the Windows build is younger than the Mac and Android ones. If Handy (which I like, and which proved this category) already covers you, you may not need this; Scribe's additions are the cleanup, the Hinglish modes, and the model catalog.
>
> I'd appreciate accuracy reports from non-native English speakers most of all; that's where I think local models are least tested.

Prepared answers for predictable comments: how it differs from Handy (respectfully, they overlap on purpose), why MIT + paid license (auditability sells trust; the license sells convenience), latency numbers (measure real ones before posting), why .NET and not Rust/Tauri.

### Days 2-4: r/ClaudeAI, r/cursor (and r/LocalLLaMA if week 1 goes well)

Angle: dictating prompts is the highest-frequency new dictation habit, and prompt text is exactly what you don't want screenshotted to someone's cloud. Do not post identical text to each sub; adapt. Disclose being the author in the first line. Draft for r/ClaudeAI:

**Title:** I dictate most of my Claude prompts now, so I built an offline push-to-talk tool for Windows

**Body:**

> Author disclosure: I made this.
>
> Typing three paragraphs of context into Claude is the slowest part of my loop, and speaking it is roughly 3x faster. The dictation tools I tried either sent audio (and in one reported case, screenshots of the active window) to cloud servers, or wanted $15/mo. My prompts contain client code, so cloud was a non-starter.
>
> Scribe runs entirely on-CPU (sherpa-onnx), sits in the tray, and types wherever the cursor is: Claude's web UI, Claude Code in a terminal, Cursor's chat pane. Hold a key, talk, release. Offline, no account, MIT source. Free core; optional one-time paid cleanup that removes the ums and false starts before the text lands.
>
> Happy to answer anything, and genuinely interested in what breaks; the Windows build is the newest of the three platforms.

### Days 5-7
Respond everywhere, fix the top three reported bugs, ship an update. A fast visible fix in a launch week is worth more than another post.

---

## Week 2 (days 8-14): Windows communities

### r/windowsapps draft

**Title:** Scribe: native offline dictation for Windows (free, open source core, no Electron)

**Body:**

> Author here. Windows tends to get Electron ports of Mac dictation apps, so I built the opposite: a native .NET tray app that does on-device speech-to-text.
>
> Hold Right Ctrl (configurable: Right Alt, Caps Lock, F8, Scroll Lock, Pause), speak, release, and the text is inserted in whatever app has focus, with your clipboard restored after. Tap once instead for hands-free. Everything runs on your CPU; after the one-time model download it makes zero network requests, and there's no account or telemetry. MIT source on GitHub.
>
> Free for full dictation. A one-time $39 launch license adds on-device AI cleanup (fixes the ums and run-ons before insertion). No subscription.
>
> Known limits: x64 only right now, elevated apps need Scribe run as admin, and it inserts text rather than voice-controlling Windows. Feedback and bug reports welcome, especially from non-US-accent speakers.

### r/software draft

Shorter, same disclosure, lead with the comparison people in that sub actually make:

> Author disclosure. If you've looked at dictation for Windows you've likely seen: Wispr Flow ($15/mo, cloud processing), Superwhisper ($249.99 lifetime, Mac-first), Handy (free OSS, verbatim only), and Win+H (needs internet, accuracy complaints). Scribe is my attempt at the missing option: native Windows app, fully on-device, free core, one-time $39 for AI cleanup, MIT source. [3 sentences on how it works + link + honest limits, reuse the r/windowsapps body.]

Rules for both: no competitor claims beyond the sourced facts in landing-copy.md footnotes, answer every comment for 48 hours, never argue with a negative review, ask for the bug report instead.

---

## Week 3 (days 15-21): Dragon orphans and accessibility, approached with respect

These communities are not a growth channel to blast; they are people who lost a tool they depended on. The rules: disclose immediately, lead with what Scribe does NOT do compared to Dragon, make the accessibility license offer concrete, and stay subscribed to the thread permanently, not just launch week.

### KnowBrainer forum (and r/RSI, r/disability, r/accessibility where self-promo rules allow; read each sub's rules first, message mods where required)

**Draft:**

> Disclosure up front: I build Scribe, a dictation app, and this post mentions it. If that's unwelcome here, mods please remove.
>
> I've been reading threads from people stranded by the end of Dragon's consumer editions, with the $699 Professional as the only remaining option. I make a Windows dictation tool and I want to be precise about whether it can help, because it is not a Dragon replacement in the full sense.
>
> What Scribe does: hands-free dictation into any app (tap a key to start, tap to stop, no holding), on-device recognition so nothing you say leaves the machine, model choice for accents, optional cleanup that removes false starts. It's free for all of that; a one-time $39-49 license adds the cleanup features.
>
> What it does not do: voice commands to control Windows, "select word / correct that" style editing, or custom command grammars. If your workflow depends on those, Dragon Professional or Voice Access will serve you better today, and I'd rather say that than waste your time.
>
> Two commitments: the code is MIT-licensed, so the app cannot be discontinued out from under you the way Dragon Home was; even if I stop, the source remains buildable. And if you dictate due to RSI, injury, or disability and cost is a barrier, email me and I'll send a full license, no documentation asked.
>
> If any long-time Dragon users are willing to test it and tell me bluntly where it falls short, that feedback would shape what I build next.

Follow-through: every feature request from these threads gets a public GitHub issue link in reply. This audience has been burned by vendors going silent; visible tracking is the trust currency.

---

## Week 4 (days 22-30): SEO bet, consolidation, gate review

### The one comparison-SEO bet: "Dragon NaturallySpeaking replacement"

Chosen over "Wispr Flow Windows alternative" because the Wispr-alternative SERP is already saturated with AI-dictation blogspam farms fighting each other, while Dragon-replacement searchers are (a) higher intent, they lost a tool they paid for, (b) Windows users by definition, (c) durable: that search will run for years after the discontinuation. One excellent page, not a content farm:

- URL: /dragon-naturallyspeaking-replacement
- Structure: what happened to Dragon consumer editions (cited), what Dragon users actually need (dictation vs command-and-control, separated honestly), where Scribe fits and where it doesn't, the comparison table from landing-copy.md plus a Dragon column, the accessibility license offer, FAQ targeting long-tail queries ("is Dragon NaturallySpeaking still supported", "Dragon Home alternative Windows 11", "offline dictation software Windows").
- The honesty is the ranking strategy: every competing page pretends its tool fully replaces Dragon; the page that accurately says "here is what nothing replaces" earns the links from KnowBrainer and accessibility bloggers that decide this SERP.
- Publish by day 24 so indexing starts inside the window. Add it to the site nav footer.

### Days 27-30: consolidation
Ship a release rolling up launch-window fixes, post a short changelog reply in every thread that reported a bug ("you said X, it's fixed in 1.x"), and run the gate below.

---

## Validation gate (day 30)

No telemetry, so measure only what respects that: server-side download counts, license sales, refund rate, GitHub signals, community responses.

| Signal | Green (double down) | Yellow (adjust) | Red (rethink) |
|---|---|---|---|
| Installer downloads | 3,000+ | 1,000-3,000 | <1,000 |
| Pro licenses sold | 100+ (~2-3% of installs) | 30-100 | <30 |
| Refund rate | <5% | 5-15% | >15% |
| GitHub stars | 1,000+ | 300-1,000 | <300 |
| Accessibility-community response | Testers engaged, issues filed | Polite silence | "This doesn't work for us" with specifics |

Decisions wired to the gate:

- **Green:** invest in the Windows-specific roadmap (voice commands would be the Dragon-orphan unlock), expand the SEO page into a small honest comparison hub, raise Pro to the $49 resting price on schedule.
- **Yellow with strong downloads but weak sales:** the free tier is satisfying everyone; move custom vocabulary into Pro's headline position or add a second Pro feature before touching price. Do not add a subscription.
- **Yellow with weak downloads but good conversion:** distribution problem, not product problem. Re-run week 1-2 channels with what the comments taught us; try r/LocalLLaMA and a YouTube reviewer outreach round.
- **Red:** stop marketing spend of time, interview ten users who tried and left (offer nothing in return, just listen), and revisit whether Windows-first was the right platform bet before writing another post.

The one metric that overrides the table: if accessibility users say it works for them, this product has a moat nobody in the category can buy. Weight that signal above raw downloads.
