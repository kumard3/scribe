export type CloudConfig = {
  apiKey: string;
  baseUrl: string;
  model: string;
};

function isoLang(language: string): string | undefined {
  if (!language || language === 'auto') return undefined;
  if (language === 'hi-en') return 'en';
  return language;
}

export async function transcribeCloud(
  wavUri: string,
  cfg: CloudConfig,
  language: string,
  translateToEnglish: boolean
): Promise<string> {
  if (!cfg.apiKey) {
    throw new Error('Add your API key in Settings → Models → Your API key.');
  }
  const base = cfg.baseUrl.replace(/\/+$/, '');
  const endpoint = `${base}/audio/${translateToEnglish ? 'translations' : 'transcriptions'}`;

  const form = new FormData();
  // React Native FormData accepts a { uri, name, type } file descriptor.
  form.append('file', { uri: wavUri, name: 'audio.wav', type: 'audio/wav' } as unknown as Blob);
  form.append('model', cfg.model || 'whisper-1');
  const lang = isoLang(language);
  if (lang && !translateToEnglish) form.append('language', lang);

  const res = await fetch(endpoint, {
    method: 'POST',
    headers: { Authorization: `Bearer ${cfg.apiKey}` },
    body: form,
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    throw new Error(`Cloud transcription failed (${res.status}). ${detail.slice(0, 160)}`);
  }
  const json = (await res.json()) as { text?: string };
  return (json.text ?? '').trim();
}
