export type PauseChunkerOptions = {
  sampleRate?: number;
  pauseMs?: number;
  hardCapSeconds?: number;
  overlapSeconds?: number;
  speechRms?: number;
  minSpeechSeconds?: number;
  leadPadSeconds?: number;
};

export class PauseChunker {
  sampleRate: number;
  pauseMs: number;
  hardCapSeconds: number;
  overlapSeconds: number;
  speechRms: number;
  minSpeechSeconds: number;
  leadPadSeconds: number;

  private current: number[] = [];
  private lead: number[] = [];
  private silent = 0;
  private voiced = 0;
  private inSpeech = false;

  constructor(opts: PauseChunkerOptions = {}) {
    this.sampleRate = Math.max(opts.sampleRate ?? 16000, 1);
    this.pauseMs = opts.pauseMs ?? 550;
    this.hardCapSeconds = opts.hardCapSeconds ?? 3;
    this.overlapSeconds = opts.overlapSeconds ?? 0.3;
    this.speechRms = opts.speechRms ?? 0.01;
    this.minSpeechSeconds = opts.minSpeechSeconds ?? 0.15;
    this.leadPadSeconds = opts.leadPadSeconds ?? 0.1;
  }

  reset(sampleRate = this.sampleRate): void {
    this.sampleRate = Math.max(sampleRate, 1);
    this.current = [];
    this.lead = [];
    this.silent = 0;
    this.voiced = 0;
    this.inSpeech = false;
  }

  feed(samples: ArrayLike<number>): Float32Array[] {
    if (samples.length === 0) return [];
    const out: Float32Array[] = [];
    const win = Math.max(1, Math.floor(this.sampleRate / 100));
    let i = 0;
    while (i < samples.length) {
      const end = Math.min(i + win, samples.length);
      let sum = 0;
      const slice: number[] = [];
      for (let j = i; j < end; j++) {
        const x = samples[j];
        slice.push(x);
        sum += x * x;
      }
      const rms = Math.sqrt(sum / slice.length);
      if (rms >= this.speechRms) {
        if (!this.inSpeech) {
          this.current.push(...this.lead);
          this.lead = [];
          this.inSpeech = true;
        }
        this.current.push(...slice);
        this.voiced += slice.length;
        this.silent = 0;
      } else if (this.inSpeech) {
        this.current.push(...slice);
        this.silent += slice.length;
      } else {
        this.lead.push(...slice);
        const pad = Math.floor(this.sampleRate * this.leadPadSeconds);
        if (this.lead.length > pad) this.lead.splice(0, this.lead.length - pad);
      }
      if (
        this.inSpeech &&
        this.voiced >= this.minSpeechSamples &&
        (this.silent >= this.pauseSamples || this.voiced >= this.hardCapSamples)
      ) {
        const chunk = this.close();
        if (chunk) out.push(chunk);
      }
      i = end;
    }
    return out;
  }

  flush(): Float32Array | null {
    return this.close();
  }

  private get pauseSamples(): number {
    return Math.max(1, Math.floor((this.sampleRate * Math.max(this.pauseMs, 1)) / 1000));
  }
  private get hardCapSamples(): number {
    return Math.max(this.pauseSamples, Math.floor(this.sampleRate * this.hardCapSeconds));
  }
  private get minSpeechSamples(): number {
    return Math.max(1, Math.floor(this.sampleRate * this.minSpeechSeconds));
  }
  private get overlapSamples(): number {
    return Math.max(0, Math.floor(this.sampleRate * this.overlapSeconds));
  }

  private close(): Float32Array | null {
    const chunk = this.current;
    if (this.voiced < this.minSpeechSamples) {
      this.current = [];
      this.lead = [];
      this.silent = 0;
      this.voiced = 0;
      this.inSpeech = false;
      return null;
    }
    const keep = Math.min(this.overlapSamples, chunk.length);
    this.current = keep > 0 ? chunk.slice(chunk.length - keep) : [];
    this.lead = [];
    this.silent = 0;
    this.voiced = 0;
    this.inSpeech = false;
    return Float32Array.from(chunk);
  }
}
