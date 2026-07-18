import { CatalogModel } from './catalog';
import { isInstalled, transcribeWithModel } from './index';
import { sherpaModelById, transcribeDetailedWithSherpa } from './sherpa';
import { transcribeDetailedWithNemo } from './nemo';
import { transcribeCloud } from './cloud';
import { getCloud } from './settings';
import type { TimedUnit } from './types';

export type DetailedTranscript = { text: string; units: TimedUnit[] };

/** Whether a catalog model can transcribe a recorded file (everything but the
 *  live-only system engine). */
export function canRecordWith(model: CatalogModel): boolean {
  return model.kind !== 'system' && model.kind !== 'llm';
}

/**
 * Transcribes a finished recording with a file-capable model, returning timings
 * when the engine provides them (for speaker attribution). The caller must have
 * downloaded the model first.
 */
export async function recordTranscribe(
  model: CatalogModel,
  wavUri: string,
  language: string
): Promise<DetailedTranscript> {
  if (model.kind === 'whisper' && model.whisper) {
    if (!isInstalled(model.whisper)) throw new Error(`Download ${model.label} in Models first.`);
    const res = await transcribeWithModel(wavUri, model.whisper, language, false);
    return { text: res.text || '', units: res.units ?? [] };
  }
  if (model.kind === 'nemo' && model.nemo) {
    return transcribeDetailedWithNemo(model.nemo, wavUri);
  }
  if (model.kind === 'sherpa' && model.sherpaId) {
    const spec = sherpaModelById(model.sherpaId);
    if (!spec) return { text: '', units: [] };
    return transcribeDetailedWithSherpa(spec, wavUri);
  }
  if (model.kind === 'cloud') {
    const text = await transcribeCloud(wavUri, getCloud(), language, false);
    return { text, units: [] };
  }
  return { text: '', units: [] };
}
