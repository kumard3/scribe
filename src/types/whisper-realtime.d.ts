// whisper.rn ships its realtime classes under a subpath that the TS exports
// wildcard resolves to a directory (no /index file), which TS can't follow.
// Metro resolves the real module fine at runtime via package exports; this
// ambient declaration only satisfies the type checker.
declare module 'whisper.rn/realtime-transcription' {
  export interface AudioStreamData {
    data: Uint8Array;
    sampleRate: number;
    channels: number;
    timestamp: number;
  }
  export interface AudioStreamConfig {
    sampleRate?: number;
    channels?: number;
    bitsPerSample?: number;
    bufferSize?: number;
    audioSource?: number;
  }
  export interface AudioStreamInterface {
    initialize(config: AudioStreamConfig): Promise<void>;
    start(): Promise<void>;
    stop(): Promise<void>;
    isRecording(): boolean;
    onData(cb: (d: AudioStreamData) => void): void;
    onError(cb: (e: string) => void): void;
    onStatusChange(cb: (r: boolean) => void): void;
    onEnd?(cb: () => void): void;
    release(): Promise<void>;
  }
  export class RealtimeTranscriber {
    constructor(deps: any, options?: any, callbacks?: any);
    start(): Promise<void>;
    stop(): Promise<void>;
    release(): Promise<void>;
    getTranscriptionResults(): any[];
  }
}
