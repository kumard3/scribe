# Use Apple Intelligence with Bolkit for Mac

Bolkit can use Apple's built-in AI model to name speakers and write meeting summaries. It runs on your Mac, costs nothing and has no usage limit. If it isn't available, Bolkit uses the AI model you picked under **AI Cleanup** instead, so everything still works.

## What you need

- A Mac with Apple silicon (M1 or later)
- macOS 27
- Up to 8 GB of free space (up to 14 GB on M3 and later Macs with 12 GB or more memory)
- Your Mac and Siri set to the **same** language, and it must be one Apple Intelligence supports: English, Danish, Dutch, French, German, Italian, Norwegian, Portuguese, Spanish, Swedish, Turkish, Vietnamese, Chinese (simplified or traditional), Japanese or Korean

Hindi is not supported by Apple's model yet. Meetings in Hindi or Hinglish still get names and summaries from your AI Cleanup model.

Apple Intelligence does not work on Macs bought in mainland China.

## Turn it on

1. Open **System Settings > General > Language & Region** and note your **Preferred Language** (for example English (US)).
2. Open **System Settings > Siri** and click **Language**. Pick exactly the same language. For example, if your Mac is English (US), Siri must be English (United States), not English (India).
3. That's the only switch. macOS 27 has no separate Apple Intelligence page: once the languages match, it downloads the models on its own.
4. Keep your Mac online and plugged in while it downloads. This can take a while. Until it's done, **System Settings > Siri** says "Adding support for Siri is in progress" and "Apple Intelligence assets need to finish downloading".

## Check it in Bolkit

Open Bolkit's dashboard and go to **AI Cleanup**. The **Apple Intelligence** row tells you exactly where you are:

| Bolkit says | What it means | What to do |
| --- | --- | --- |
| On | Ready. Meetings use Apple's model. | Nothing. |
| Not ready yet | Your Mac supports it, but the model isn't downloaded. Either the Mac and Siri languages differ, or macOS is still downloading. | Follow steps 1 and 2, then wait. |
| Turn on Apple Intelligence | It's switched off (macOS 26). | Turn it on under **Apple Intelligence & Siri**. |
| This Mac doesn't support Apple Intelligence | The Mac is Intel, or otherwise not eligible. | Nothing, Bolkit uses your AI Cleanup model. |
| Needs macOS 26 or later | macOS is too old. | Update macOS, or keep using your AI Cleanup model. |

You don't need to restart Bolkit. It checks again every time it processes a meeting.

## Privacy

Bolkit only uses Apple's on-device model. Your meeting text is processed on your Mac. Bolkit does not use Apple's Private Cloud Compute server model.
