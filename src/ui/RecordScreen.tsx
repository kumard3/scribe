import { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  Share,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
} from 'react-native';
import * as Clipboard from 'expo-clipboard';
import { requestRecordingPermissionsAsync } from 'expo-audio';
import { Ionicons } from '@expo/vector-icons';
import { theme } from './theme';
import { Waveform, BAR_COUNT } from './Waveform';
import { RecordButton } from './RecordButton';
import { ProgressBar } from './ProgressBar';
import { LanguagePicker } from './LanguagePicker';
import {
  cancelRecorder,
  onRecorderLevel,
  pauseRecorder,
  recorderAvailable,
  recorderBackgroundCapable,
  recorderSupportsPause,
  resumeRecorder,
  startRecorder,
  stopRecorder,
} from '../audio/fileRecorder';
import { CatalogModel } from '../asr/catalog';
import { canRecordWith, recordTranscribe } from '../asr/recordTranscribe';
import { prepareModel, isInstalled } from '../asr';
import { downloadNemo, nemoInstalled } from '../asr/nemo';
import { downloadSherpa, sherpaInstalled, sherpaModelById } from '../asr/sherpa';
import {
  buildSpeakerTurns,
  diarizationInstalled,
  diarizationSupported,
  diarizeFile,
  downloadDiarizationModels,
  speakerCount,
  speakerLabel,
  SpeakerTurn,
  turnsToText,
  DIARIZATION_SIZE_LABEL,
} from '../asr/diarize';
import { translateText, translateTargetLabel, TRANSLATE_TARGETS } from '../asr/translate';
import { getCloud, getAutoPolish, getDiarizationEnabled, setDiarizationEnabled } from '../asr/settings';
import { polish } from '../util/polish';
import { addHistory } from '../history';
import { deleteFileSafe } from '../util/files';
import type { LanguageCode } from '../asr/types';

const IDLE = Array(BAR_COUNT).fill(0.06);

type Phase = 'idle' | 'recording' | 'processing' | 'done';

type Props = {
  language: LanguageCode;
  recordModel: CatalogModel | null;
  onPickModel: () => void;
  onSaved?: () => void;
  onBusyChange?: (busy: boolean) => void;
};

function fmtTime(sec: number): string {
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return `${m}:${s.toString().padStart(2, '0')}`;
}

export function RecordScreen({ language, recordModel, onPickModel, onSaved, onBusyChange }: Props) {
  const [phase, setPhase] = useState<Phase>('idle');
  const [elapsed, setElapsed] = useState(0);
  const [paused, setPaused] = useState(false);
  const [levels, setLevels] = useState<number[]>(IDLE);
  const [status, setStatus] = useState('');
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<string | null>(null);

  const [turns, setTurns] = useState<SpeakerTurn[]>([]);
  const [edited, setEdited] = useState('');
  const [speakers, setSpeakers] = useState(0);

  const [target, setTarget] = useState('');
  const [translated, setTranslated] = useState<SpeakerTurn[] | null>(null);
  const [showOriginal, setShowOriginal] = useState(false);
  const [pickTarget, setPickTarget] = useState(false);

  const [diarize, setDiarize] = useState(getDiarizationEnabled());

  const startedAt = useRef(0);
  const pausedAccum = useRef(0);
  const pausedAt = useRef(0);

  useEffect(() => {
    if (phase !== 'recording' || paused) return;
    const h = setInterval(() => {
      setElapsed(Math.floor((Date.now() - startedAt.current - pausedAccum.current) / 1000));
    }, 500);
    return () => clearInterval(h);
  }, [phase, paused]);

  useEffect(() => {
    if (phase !== 'recording') {
      setLevels(IDLE);
      return;
    }
    const unsub = onRecorderLevel((rms) => {
      const norm = Math.max(0.06, Math.min(1, rms * 3.4));
      setLevels((prev) => [...prev.slice(1), norm]);
    });
    return unsub;
  }, [phase]);

  useEffect(() => {
    onBusyChange?.(phase === 'recording' || phase === 'processing');
  }, [phase, onBusyChange]);

  const reset = useCallback(() => {
    setPhase('idle');
    setElapsed(0);
    setPaused(false);
    setStatus('');
    setProgress(0);
    setError(null);
    setTurns([]);
    setEdited('');
    setSpeakers(0);
    setTarget('');
    setTranslated(null);
    setShowOriginal(false);
  }, []);

  const ensureModelReady = useCallback(async (m: CatalogModel) => {
    if (m.kind === 'whisper' && m.whisper) {
      if (!isInstalled(m.whisper)) {
        setStatus('Downloading model');
        await prepareModel(m.whisper, setProgress);
        setProgress(0);
      } else {
        await prepareModel(m.whisper);
      }
    } else if (m.kind === 'nemo' && m.nemo) {
      if (!(await nemoInstalled(m.nemo))) {
        setStatus('Downloading model');
        await downloadNemo(m.nemo, setProgress);
        setProgress(0);
      }
    } else if (m.kind === 'sherpa' && m.sherpaId) {
      const spec = sherpaModelById(m.sherpaId);
      if (spec && !(await sherpaInstalled(spec))) {
        setStatus('Downloading model');
        await downloadSherpa(spec, setProgress);
        setProgress(0);
      }
    }
  }, []);

  const onStart = useCallback(async () => {
    setError(null);
    if (!recorderAvailable) {
      setError('Recording is not available on this device.');
      return;
    }
    if (!recordModel || !canRecordWith(recordModel)) {
      setError('Pick an offline or cloud model to record.');
      return;
    }
    if (recordModel.kind === 'cloud' && !getCloud().apiKey) {
      setError('Add your API key in Settings → Models → Your API key.');
      return;
    }
    const perm = await requestRecordingPermissionsAsync();
    if (!perm.granted) {
      setError('Microphone permission denied — enable it in Settings.');
      return;
    }
    try {
      await startRecorder();
      startedAt.current = Date.now();
      pausedAccum.current = 0;
      setElapsed(0);
      setPaused(false);
      setLevels(IDLE);
      setPhase('recording');
    } catch (e: any) {
      setError(e?.message ?? String(e));
    }
  }, [recordModel]);

  const onTogglePause = useCallback(async () => {
    if (!recorderSupportsPause) return;
    if (paused) {
      pausedAccum.current += Date.now() - pausedAt.current;
      await resumeRecorder();
      setPaused(false);
    } else {
      pausedAt.current = Date.now();
      await pauseRecorder();
      setPaused(true);
    }
  }, [paused]);

  const onStop = useCallback(async () => {
    const m = recordModel;
    if (!m) return;
    let uri: string | null = null;
    try {
      uri = await stopRecorder();
      setPhase('processing');
      setStatus('Preparing');
      await ensureModelReady(m);

      setStatus('Transcribing');
      const detailed = await recordTranscribe(m, uri, language);
      let baseText = detailed.text;
      if (!baseText.trim()) {
        setError('No speech found in the recording.');
        reset();
        return;
      }

      let result: SpeakerTurn[];
      let nSpeakers = 1;
      if (diarize && diarizationSupported) {
        if (!diarizationInstalled()) {
          setStatus('Downloading speaker model');
          await downloadDiarizationModels(setProgress);
          setProgress(0);
        }
        setStatus('Identifying speakers');
        const segs = await diarizeFile(uri, { numSpeakers: 0 });
        nSpeakers = Math.max(1, speakerCount(segs));
        result = buildSpeakerTurns(baseText, detailed.units, segs);
      } else {
        result = [{ speaker: 0, text: baseText }];
      }

      if (getAutoPolish()) result = result.map((t) => ({ ...t, text: polish(t.text) }));

      const full = turnsToText(result);
      setTurns(result);
      setEdited(full);
      setSpeakers(nSpeakers);
      setPhase('done');

      addHistory({ text: full, language, translated: false });
      onSaved?.();
    } catch (e: any) {
      setError(e?.message ?? String(e));
      setPhase(uri ? 'done' : 'idle');
    } finally {
      if (uri) deleteFileSafe(uri);
      setStatus('');
      setProgress(0);
    }
  }, [recordModel, language, diarize, ensureModelReady, reset, onSaved]);

  const onCancel = useCallback(async () => {
    await cancelRecorder();
    reset();
  }, [reset]);

  const applyTranslation = useCallback(
    async (code: string) => {
      setTarget(code);
      setShowOriginal(false);
      if (!code) {
        setTranslated(null);
        return;
      }
      setStatus('Translating');
      try {
        const out: SpeakerTurn[] = [];
        for (const t of turns) {
          out.push({ speaker: t.speaker, text: await translateText(t.text, code, language) });
        }
        setTranslated(out);
      } catch {
        setTranslated(null);
      } finally {
        setStatus('');
      }
    },
    [turns, language]
  );

  const onToggleDiarize = useCallback((v: boolean) => {
    setDiarize(v);
    setDiarizationEnabled(v);
  }, []);

  const view = showOriginal || !translated ? turns : translated;
  const fullText = view.length ? turnsToText(view) : edited;
  const multi = speakers > 1;

  // ---- render ----

  if (phase === 'recording') {
    return (
      <View style={styles.fill}>
        <View style={styles.recTop}>
          <Text style={styles.timer}>{fmtTime(elapsed)}</Text>
          <Text style={styles.recHint}>
            {paused ? 'Paused' : recorderBackgroundCapable ? 'Recording — you can leave the app' : 'Recording'}
          </Text>
        </View>
        <View style={styles.center}>
          <Waveform levels={levels} active={!paused} />
        </View>
        <View style={styles.recDock}>
          <Pressable style={styles.sideBtn} onPress={onCancel} hitSlop={10}>
            <Text style={styles.cancelText}>Cancel</Text>
          </Pressable>
          <RecordButton recording busy={false} onPress={onStop} />
          {recorderSupportsPause ? (
            <Pressable style={styles.sideBtn} onPress={onTogglePause} hitSlop={10}>
              <Ionicons name={paused ? 'play' : 'pause'} size={26} color={theme.textDim} />
            </Pressable>
          ) : (
            <View style={styles.sideBtn} />
          )}
        </View>
      </View>
    );
  }

  if (phase === 'processing') {
    return (
      <View style={styles.fill}>
        <View style={styles.center}>
          <ActivityIndicator color={theme.primary} size="large" />
          <Text style={styles.procText}>{status}…</Text>
          {progress > 0 && (
            <View style={styles.progressWrap}>
              <ProgressBar ratio={progress} />
              <Text style={styles.procSub}>{Math.round(progress * 100)}%</Text>
            </View>
          )}
        </View>
      </View>
    );
  }

  if (phase === 'done') {
    return (
      <View style={styles.fill}>
        <View style={styles.resultHead}>
          <Text style={styles.resultTitle}>
            {multi ? `${speakers} speakers` : 'Transcript'}
          </Text>
          <View style={styles.headActions}>
            <Pressable
              style={[styles.pill, target ? styles.pillOn : null]}
              onPress={() => setPickTarget(true)}
              hitSlop={6}
            >
              <Ionicons name="language" size={15} color={target ? theme.onPrimary : theme.text} />
              <Text style={[styles.pillText, target ? styles.pillTextOn : null]}>
                {target ? translateTargetLabel(target) : 'Translate'}
              </Text>
            </Pressable>
            {translated && (
              <Pressable style={styles.smallBtn} onPress={() => setShowOriginal((s) => !s)} hitSlop={6}>
                <Text style={styles.smallBtnText}>{showOriginal ? 'Show translation' : 'Show original'}</Text>
              </Pressable>
            )}
          </View>
        </View>

        <ScrollView style={styles.resultScroll} contentContainerStyle={styles.resultContent}>
          {multi ? (
            view.map((t, i) => (
              <View key={i} style={styles.turn}>
                <Text style={[styles.speakerTag, { color: speakerColor(t.speaker) }]}>
                  {speakerLabel(t.speaker)}
                </Text>
                <Text style={styles.turnText}>{t.text}</Text>
              </View>
            ))
          ) : (
            <TextInput
              style={styles.editor}
              value={translated ? fullText : edited}
              onChangeText={translated ? undefined : setEdited}
              editable={!translated}
              multiline
              scrollEnabled={false}
            />
          )}
        </ScrollView>

        <View style={styles.doneDock}>
          <Pressable style={styles.action} onPress={() => Clipboard.setStringAsync(fullText)} hitSlop={8}>
            <Ionicons name="copy-outline" size={22} color={theme.text} />
          </Pressable>
          <Pressable style={styles.action} onPress={() => Share.share({ message: fullText })} hitSlop={8}>
            <Ionicons name="share-outline" size={22} color={theme.text} />
          </Pressable>
          <Pressable style={[styles.action, styles.newBtn]} onPress={reset} hitSlop={8}>
            <Ionicons name="mic" size={20} color={theme.onPrimary} />
            <Text style={styles.newText}>New recording</Text>
          </Pressable>
        </View>

        {error && <Text style={styles.error}>{error}</Text>}

        <LanguagePicker
          visible={pickTarget}
          current={target}
          title="Translate to"
          options={TRANSLATE_TARGETS}
          onSelect={applyTranslation}
          onClose={() => setPickTarget(false)}
        />
      </View>
    );
  }

  // idle
  const modelLabel = recordModel?.title ?? recordModel?.label ?? 'No model';
  const canRecord = !!recordModel && canRecordWith(recordModel);
  const needsDownload =
    recordModel?.kind === 'whisper' && recordModel.whisper && !isInstalled(recordModel.whisper);

  return (
    <View style={styles.fill}>
      <View style={styles.center}>
        <Text style={styles.bigTitle}>Record</Text>
        <Text style={styles.sub}>
          Capture a meeting or long note, then transcribe and translate it.
        </Text>
        {recorderBackgroundCapable && (
          <Text style={styles.subFaint}>Keeps recording in the background.</Text>
        )}
      </View>

      <View style={styles.idleDock}>
        {canRecord ? (
          <RecordButton recording={false} busy={false} onPress={onStart} />
        ) : (
          <Pressable style={styles.cta} onPress={onPickModel}>
            <Text style={styles.ctaText}>Choose a model to record</Text>
          </Pressable>
        )}

        <Pressable style={styles.modelRow} onPress={onPickModel} hitSlop={6}>
          <Ionicons name="cube-outline" size={15} color={theme.textFaint} />
          <Text style={styles.modelText}>
            {modelLabel}
            {needsDownload && recordModel ? ` · ${recordModel.sizeLabel} on first use` : ''}
          </Text>
          <Ionicons name="chevron-forward" size={14} color={theme.textFaint} />
        </Pressable>

        {diarizationSupported && (
          <View style={styles.diarRow}>
            <View style={styles.diarLabel}>
              <Ionicons name="people-outline" size={18} color={theme.textDim} />
              <View>
                <Text style={styles.diarTitle}>Identify speakers</Text>
                <Text style={styles.diarSub}>
                  {diarizationInstalled() ? 'Labels who said what' : `Adds a ${DIARIZATION_SIZE_LABEL} model`}
                </Text>
              </View>
            </View>
            <Switch
              value={diarize}
              onValueChange={onToggleDiarize}
              trackColor={{ false: theme.border, true: theme.primary }}
              thumbColor={theme.onPrimary}
            />
          </View>
        )}

        {error && <Text style={styles.error}>{error}</Text>}
      </View>
    </View>
  );
}

const SPEAKER_COLORS = ['#FFFFFF', '#7FB2FF', '#8FE3A6', '#FFC36B', '#FF9FB2', '#C9A2FF'];
function speakerColor(speaker: number): string {
  return SPEAKER_COLORS[speaker % SPEAKER_COLORS.length];
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 12 },
  bigTitle: { color: theme.text, fontSize: 30, fontWeight: '700' },
  sub: { color: theme.textDim, fontSize: 15, textAlign: 'center', paddingHorizontal: 30, lineHeight: 21 },
  subFaint: { color: theme.textFaint, fontSize: 13, textAlign: 'center', marginTop: 2 },

  recTop: { alignItems: 'center', paddingTop: 24, gap: 6 },
  timer: { color: theme.text, fontSize: 52, fontWeight: '300', fontVariant: ['tabular-nums'] },
  recHint: { color: theme.textDim, fontSize: 14, fontWeight: '500' },
  recDock: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingBottom: 20 },
  sideBtn: { width: 80, height: 48, alignItems: 'center', justifyContent: 'center' },
  cancelText: { color: theme.textDim, fontSize: 16, fontWeight: '500' },

  procText: { color: theme.text, fontSize: 17, fontWeight: '500' },
  progressWrap: { width: 220, alignItems: 'center', gap: 6 },
  procSub: { color: theme.textDim, fontSize: 13 },

  resultHead: { paddingTop: 8, paddingBottom: 10, gap: 10 },
  resultTitle: { color: theme.text, fontSize: 22, fontWeight: '700' },
  headActions: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  pill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    backgroundColor: theme.surface,
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 999,
  },
  pillOn: { backgroundColor: theme.primary },
  pillText: { color: theme.text, fontSize: 14, fontWeight: '600' },
  pillTextOn: { color: theme.onPrimary },
  smallBtn: { paddingVertical: 8, paddingHorizontal: 6 },
  smallBtnText: { color: theme.textDim, fontSize: 14, fontWeight: '500' },

  resultScroll: { flex: 1 },
  resultContent: { paddingBottom: 20 },
  turn: { marginBottom: 16 },
  speakerTag: { fontSize: 13, fontWeight: '700', marginBottom: 4, letterSpacing: 0.3 },
  turnText: { color: theme.text, fontSize: 18, lineHeight: 26 },
  editor: {
    color: theme.text,
    fontSize: 20,
    lineHeight: 29,
    fontWeight: '500',
    textAlignVertical: 'top',
    padding: 0,
  },

  doneDock: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 14 },
  action: {
    width: 50,
    height: 50,
    borderRadius: 25,
    backgroundColor: theme.surface,
    alignItems: 'center',
    justifyContent: 'center',
  },
  newBtn: {
    flex: 1,
    flexDirection: 'row',
    gap: 8,
    backgroundColor: theme.primary,
    borderRadius: 25,
    width: undefined,
  },
  newText: { color: theme.onPrimary, fontSize: 16, fontWeight: '700' },

  idleDock: { alignItems: 'center', gap: 18, paddingBottom: 24 },
  cta: { backgroundColor: theme.surface, paddingVertical: 18, paddingHorizontal: 28, borderRadius: 18 },
  ctaText: { color: theme.text, fontSize: 16, fontWeight: '600' },
  modelRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  modelText: { color: theme.textFaint, fontSize: 14, fontWeight: '500' },
  diarRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    backgroundColor: theme.surface,
    borderRadius: 16,
    paddingVertical: 12,
    paddingHorizontal: 16,
    width: '100%',
  },
  diarLabel: { flexDirection: 'row', alignItems: 'center', gap: 12, flexShrink: 1 },
  diarTitle: { color: theme.text, fontSize: 15, fontWeight: '600' },
  diarSub: { color: theme.textFaint, fontSize: 12, marginTop: 1 },

  error: { color: theme.danger, textAlign: 'center', marginTop: 10, fontSize: 13 },
});
