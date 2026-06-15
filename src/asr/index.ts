import { WhisperEngine } from './whisperEngine';
import { resolveModel } from './router';
import { downloadModel, isInstalled, localFile } from './modelManager';
import { ASREngine, EngineKind, LanguageCode, ModelSpec, TranscriptionResult } from './types';

const engines: Partial<Record<EngineKind, ASREngine>> = {
  whisper: new WhisperEngine(),
};

function engineFor(model: ModelSpec): ASREngine {
  const e = engines[model.engine];
  if (!e) throw new Error(`Engine '${model.engine}' not available yet`);
  return e;
}

export { resolveModel, isInstalled };
export type { ModelSpec, TranscriptionResult };

export async function prepare(
  language: LanguageCode,
  onDownload?: (ratio: number) => void
): Promise<ModelSpec> {
  const model = resolveModel(language);
  const file = await downloadModel(model, onDownload);
  await engineFor(model).load(model, file.uri);
  return model;
}

export async function transcribeFile(
  wavPath: string,
  language: LanguageCode,
  translateToEnglish: boolean
): Promise<TranscriptionResult> {
  const model = resolveModel(language);
  if (!isInstalled(model)) throw new Error('Model not installed — call prepare() first');
  const engine = engineFor(model);
  if (engine.loadedModelId() !== model.id) {
    await engine.load(model, localFile(model).uri);
  }
  return engine.transcribe({ wavPath, language, translateToEnglish });
}

export async function prepareModel(
  model: ModelSpec,
  onDownload?: (ratio: number) => void
): Promise<void> {
  const file = await downloadModel(model, onDownload);
  await engineFor(model).load(model, file.uri);
}

export async function transcribeWithModel(
  wavPath: string,
  model: ModelSpec,
  language: LanguageCode,
  translateToEnglish: boolean
): Promise<TranscriptionResult> {
  if (!isInstalled(model)) throw new Error('Model not installed — download it in Models first.');
  const engine = engineFor(model);
  if (engine.loadedModelId() !== model.id) {
    await engine.load(model, localFile(model).uri);
  }
  return engine.transcribe({ wavPath, language, translateToEnglish });
}
