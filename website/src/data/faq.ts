export interface FaqItem {
  q: string;
  a: string;
}

export const FAQ: FaqItem[] = [
  {
    q: 'Is Scribe really free?',
    a: 'Yes. Scribe is free and open source. There is no subscription, no trial that expires, and no paywalled features. There is nothing to sell you because there is no server to run.',
  },
  {
    q: 'Does my voice or audio ever leave my device?',
    a: 'No. Transcription runs entirely on your device using a model you download once. Audio is processed in memory and is never uploaded. Switch on airplane mode and Scribe still works, which is the proof.',
  },
  {
    q: 'Does Scribe work offline?',
    a: 'Completely. After the one-time model download, every feature (live dictation, long-form recording, speaker labels, and translation) runs with no internet connection at all.',
  },
  {
    q: 'What languages does it support?',
    a: 'Transcription covers dozens of languages depending on the engine you choose, and on-device translation works across 59 languages. The translation models also run locally on your device.',
  },
  {
    q: 'Which platforms can I use it on?',
    a: 'Android is available in beta today, alongside a macOS menu-bar app and a Windows tray app. An iOS version is coming soon.',
  },
  {
    q: 'How is Scribe different from Wispr Flow or Superwhisper?',
    a: 'Scribe does the same job, fast dictation in any app, but keeps everything on your device, costs nothing, needs no account, and is open source. Most cloud dictation tools send your audio to their own servers to transcribe it.',
  },
  {
    q: 'Do I need an account or an API key?',
    a: 'No account, ever, and no key required. Scribe works the moment you install it. You can optionally add your own API key for a cloud model, but that is off by default and everything stays offline until you turn it on.',
  },
  {
    q: 'Can it tell who said what?',
    a: 'Yes. On-device speaker diarization labels each speaker and lays the transcript out turn by turn, so recordings of meetings and interviews read clearly.',
  },
  {
    q: 'Is Scribe open source?',
    a: 'Yes. The full source is on GitHub, so anyone can audit exactly what the app does with your audio, which is to keep it on your device.',
  },
];
