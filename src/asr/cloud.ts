import { biasTerms, type CloudSettings } from './settings';
import { wavSeconds } from '../audio/wav';
import { recordCloud, type CloudProvider } from '../util/usage';

function isoLang(language: string): string | undefined {
  if (!language || language === 'auto') return undefined;
  if (language === 'hi-en') return 'en';
  return language;
}

function trimUrl(url: string): string {
  return url.trim().replace(/\/+$/, '');
}

function speechBase(cfg: CloudSettings): string {
  if (cfg.azureSpeechEndpoint) return trimUrl(cfg.azureSpeechEndpoint);
  return cfg.azureSpeechRegion ? `https://${cfg.azureSpeechRegion.trim()}.api.cognitive.microsoft.com` : '';
}

const WHERE = 'Add it in Models, Cloud accounts.';

export function cloudMissing(cfg: CloudSettings): string | null {
  if (cfg.provider === 'azure-speech') {
    if (!cfg.azureSpeechKey) return `Azure Speech needs a key. ${WHERE}`;
    if (!speechBase(cfg)) return `Azure Speech needs an endpoint or region. ${WHERE}`;
    return null;
  }
  if (cfg.provider === 'azure-openai') {
    if (!cfg.azureOpenAIKey || !cfg.azureOpenAIEndpoint) return `Azure OpenAI needs a key and endpoint. ${WHERE}`;
    if (!cfg.azureOpenAITranscribe) return `Azure OpenAI needs a transcription deployment name. ${WHERE}`;
    return null;
  }
  return cfg.apiKey ? null : `Your cloud account needs an API key. ${WHERE}`;
}

async function post(
  provider: CloudProvider,
  audioSeconds: number,
  url: string,
  headers: Record<string, string>,
  body: FormData | string
): Promise<any> {
  let json: any;
  try {
    const res = await fetch(url, { method: 'POST', headers, body });
    if (!res.ok) {
      const detail = await res.text().catch(() => '');
      const hint = res.status === 401 || res.status === 403 ? ' Check the key.' : '';
      const what = provider.endsWith('-chat') ? 'Cloud AI' : 'Cloud transcription';
      throw new Error(`${what} failed (${res.status}).${hint} ${detail.slice(0, 160)}`);
    }
    json = await res.json();
  } catch (e) {
    recordCloud(provider, url, false, audioSeconds);
    throw e;
  }
  recordCloud(provider, url, true, audioSeconds, json);
  return json;
}

function wavPart(uri: string): Blob {
  // React Native FormData accepts a { uri, name, type } file descriptor.
  return { uri, name: 'audio.wav', type: 'audio/wav' } as unknown as Blob;
}

export async function transcribeCloud(
  wavUri: string,
  cfg: CloudSettings,
  language: string,
  translateToEnglish: boolean
): Promise<string> {
  const missing = cloudMissing(cfg);
  if (missing) throw new Error(missing);
  const lang = isoLang(language);
  const terms = biasTerms();
  const form = new FormData();
  const seconds = wavSeconds(wavUri);

  if (cfg.provider === 'azure-speech') {
    form.append('audio', wavPart(wavUri));
    const definition: Record<string, unknown> = { enhancedMode: { enabled: true, model: 'MAI-Transcribe-2' } };
    if (terms.length) definition.phraseList = { phrases: terms };
    form.append('definition', JSON.stringify(definition));
    const json = (await post(
      'azure-speech',
      seconds,
      `${speechBase(cfg)}/speechtotext/transcriptions:transcribe?api-version=2025-10-15`,
      { 'Ocp-Apim-Subscription-Key': cfg.azureSpeechKey },
      form
    )) as { phrases?: { text: string }[] };
    return (json.phrases ?? [])
      .map((p) => p.text.replace(/\s*\n\s*/g, ' ').trim())
      .filter(Boolean)
      .join(' ');
  }

  form.append('file', wavPart(wavUri));
  if (lang && !translateToEnglish) form.append('language', lang);

  if (cfg.provider === 'azure-openai') {
    form.append('response_format', 'json');
    if (terms.length) form.append('prompt', `Names that may appear: ${terms.join(', ')}.`);
    const task = translateToEnglish ? 'translations' : 'transcriptions';
    const url = `${trimUrl(cfg.azureOpenAIEndpoint)}/openai/deployments/${encodeURIComponent(
      cfg.azureOpenAITranscribe
    )}/audio/${task}?api-version=${encodeURIComponent(cfg.azureOpenAIApiVersion)}`;
    // ponytail: one request per file; gpt-4o(-mini)-transcribe stops at 2048 output tokens, so
    // recordings over ~2.5 min can come back cut. Port the Mac's 150 s split if meetings need it.
    const json = (await post('azure-openai-transcribe', seconds, url, { 'api-key': cfg.azureOpenAIKey }, form)) as {
      text?: string;
    };
    return (json.text ?? '').trim();
  }

  form.append('model', cfg.model || 'whisper-1');
  const endpoint = `${trimUrl(cfg.baseUrl)}/audio/${translateToEnglish ? 'translations' : 'transcriptions'}`;
  const json = (await post('openai-transcribe', seconds, endpoint, { Authorization: `Bearer ${cfg.apiKey}` }, form)) as {
    text?: string;
  };
  return (json.text ?? '').trim();
}

export function cloudChatReady(cfg: CloudSettings): boolean {
  return (
    !!(cfg.azureOpenAIKey && cfg.azureOpenAIEndpoint && cfg.azureOpenAIChat) ||
    !!(cfg.apiKey && cfg.baseUrl && cfg.chatModel)
  );
}

export function cloudChatLabel(cfg: CloudSettings): string {
  if (cfg.azureOpenAIKey && cfg.azureOpenAIEndpoint && cfg.azureOpenAIChat) return `Azure OpenAI · ${cfg.azureOpenAIChat}`;
  if (cfg.apiKey && cfg.chatModel) return cfg.chatModel;
  return '';
}

export async function chatCloud(cfg: CloudSettings, instruction: string, text: string): Promise<string> {
  const messages = [
    { role: 'system', content: instruction },
    { role: 'user', content: text.trim() },
  ];
  const azure = !!(cfg.azureOpenAIKey && cfg.azureOpenAIEndpoint && cfg.azureOpenAIChat);
  const url = azure
    ? `${trimUrl(cfg.azureOpenAIEndpoint)}/openai/deployments/${encodeURIComponent(
        cfg.azureOpenAIChat
      )}/chat/completions?api-version=${encodeURIComponent(cfg.azureOpenAIApiVersion)}`
    : `${trimUrl(cfg.baseUrl)}/chat/completions`;
  const json = (await post(
    azure ? 'azure-openai-chat' : 'openai-chat',
    0,
    url,
    {
      'Content-Type': 'application/json',
      ...(azure ? { 'api-key': cfg.azureOpenAIKey } : { Authorization: `Bearer ${cfg.apiKey}` }),
    },
    JSON.stringify(azure ? { messages } : { model: cfg.chatModel, messages })
  )) as { choices?: { message?: { content?: string } }[] };
  return (json.choices?.[0]?.message?.content ?? '').trim();
}
