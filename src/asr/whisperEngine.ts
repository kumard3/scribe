import { initWhisper, WhisperContext } from 'whisper.rn';
import { ASREngine, ModelSpec, TranscribeRequest, TranscriptionResult } from './types';

function stripScheme(uri: string): string {
  return uri.replace(/^file:\/\//, '');
}

export class WhisperEngine implements ASREngine {
  readonly kind = 'whisper' as const;
  private ctx: WhisperContext | null = null;
  private modelId: string | null = null;

  loadedModelId(): string | null {
    return this.modelId;
  }

  async load(model: ModelSpec, localUri: string): Promise<void> {
    if (this.modelId === model.id && this.ctx) return;
    await this.unload();

    const filePath = stripScheme(localUri);
    const attempts = [
      { useGpu: true, useFlashAttn: true },
      { useGpu: true, useFlashAttn: false },
      { useGpu: false, useFlashAttn: false },
    ];
    let lastErr: unknown;
    for (const opts of attempts) {
      try {
        this.ctx = await initWhisper({ filePath, ...opts });
        this.modelId = model.id;
        return;
      } catch (e) {
        lastErr = e;
      }
    }
    throw lastErr ?? new Error('Failed to initialize Whisper');
  }

  async transcribe(req: TranscribeRequest): Promise<TranscriptionResult> {
    if (!this.ctx) throw new Error('Whisper model not loaded');
    const started = Date.now();
    const { promise } = this.ctx.transcribe(stripScheme(req.wavPath), {
      language: req.language === 'auto' ? 'auto' : req.language,
      translate: req.translateToEnglish ?? false,
    });
    const res = await promise;
    return {
      text: res.result.trim(),
      durationMs: Date.now() - started,
    };
  }

  async unload(): Promise<void> {
    if (this.ctx) {
      await this.ctx.release();
      this.ctx = null;
      this.modelId = null;
    }
  }
}
