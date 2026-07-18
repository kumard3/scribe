# Scribe Windows Monetization Recommendation

## Recommendation

**Free core + one-time Pro license at $49 (launch price $39). No subscription, ever.**

- **Free tier (forever, not a trial):** full dictation. Streaming on-device recognition, every ASR model, all hotkeys, hands-free mode, Hindi/Hinglish, transcript history. No limits, no watermark, no account.
- **Pro, $49 once:** on-device AI cleanup (Gemma), custom vocabulary, priority support, all future updates. License key unlocks it in the official builds.
- **Source stays MIT.** Anyone can build everything from source. The $49 buys the signed installer, the maintained builds, and the convenience, in the open-source tradition of paying for the packaged product, not the code.
- **Accessibility program:** free Pro license on request for anyone dictating due to RSI, injury, or disability. Honor system, no documentation demanded.

## Why this model

### The three options, weighed

**1. Pure one-time purchase ($39-79 for everything).**
Undercuts Superwhisper's $249.99 lifetime and respects subscription fatigue. But it puts a paywall in front of the exact users we need first: privacy people and developers who will otherwise pick Handy, which is free and has 20k+ stars. A paid-only Scribe loses the adoption race to Handy on the channels we launch in (HN, Reddit), where "free and open" is the price of entry to the conversation.

**2. Cheap subscription ($3-5/mo).**
Best revenue on paper, and indefensible in practice. Our positioning attacks subscription fatigue by name; charging one would poison every post we write and hand Handy the whole wedge. Also operationally wrong: our marginal cost per user is zero (their CPU does the work), and subscriptions are priced to cover cloud inference we do not have. Rejected outright.

**3. Freemium with a one-time Pro unlock. (Chosen.)**
The free tier matches Handy feature for feature, so we never lose a user to "but Handy is free." The paid tier sells the thing Handy explicitly does not do and the thing Wispr charges $180/yr for: turning rambling speech into clean text, on-device. The purchase is once, which keeps every promise the positioning makes. This is the only model consistent with all three of: the owner's free/no-telemetry ethos, Handy's existence, and actually making money.

### Why $49

- Anchors: Superwhisper lifetime $249.99 (we are 5x cheaper for the comparable outcome), Wispr $15/mo (we cost less than four months of it, once), Dragon consumer editions were $150-699 (we are an easy yes for orphans who already spent that).
- Below $30 signals hobby project and caps revenue for no adoption gain; the free tier already handles adoption. Above $79 recreates Superwhisper's sticker-shock problem in miniature.
- $39 launch price creates urgency for the launch window without devaluing the product; $49 is the resting price. Never discount below the launch price later; early buyers must stay the winners.

### The Dragon-orphan angle strengthens the wedge

Dragon consumer users paid $150-699 and were abandoned with only a $699 enterprise product left. Two moves:

1. **"Dragon amnesty" framing in copy:** anyone coming from Dragon gets Pro at the launch price permanently, no deadline. Costs almost nothing, converts the most motivated segment, and every KnowBrainer or r/RSI mention of it is earned trust.
2. **Free Pro for accessibility users on request.** Some of the most influential voices in dictation communities are people who dictate out of necessity. Charging them $49 earns trivial revenue; giving them Pro earns the only endorsement in this market that cannot be bought. This is also simply the right thing, and doing it quietly but stating it plainly on the pricing page is on-brand.

### Risks and answers

- **"MIT source means Pro is compilable for free."** Yes, deliberately. The set of people who will maintain their own Windows build overlaps almost entirely with people who would never pay; meanwhile MIT is what makes the privacy claim auditable, which is the core of the brand. Handy proves the audience; the license key sells convenience, not secrecy.
- **"No telemetry means no conversion analytics."** Correct and accepted. Measure with what does not spy: download counts, license sales, refund rate, GitHub stars/issues. See launch-plan.md validation gate.
- **"Will free users ever convert?"** Some will not, and they still matter: they are the distribution. Every free user is a referral engine for the segments that do pay (professionals expensing $49 without thinking).

## Decision summary

| Question | Answer |
|---|---|
| Model | Freemium, one-time Pro unlock |
| Price | $49 (launch $39) |
| Subscription | Never |
| Free tier | Full verbatim dictation, permanent |
| Pro contents | On-device AI cleanup, custom vocabulary, priority support |
| Accessibility | Free Pro on request, honor system |
| Dragon orphans | Launch price permanently |
| Refunds | 30 days, unconditional |
