import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Linking,
  PanResponder,
  Platform,
  Pressable,
  SafeAreaView,
  ScrollView,
  Share,
  StatusBar as RNStatusBar,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import * as Clipboard from 'expo-clipboard';
import * as DocumentPicker from 'expo-document-picker';
import { StatusBar } from 'expo-status-bar';
import { activateKeepAwakeAsync, deactivateKeepAwake } from 'expo-keep-awake';
import { Ionicons } from '@expo/vector-icons';
import {
  requestRecordingPermissionsAsync,
  setAudioModeAsync,
  useAudioStream,
} from 'expo-audio';
import { useSpeechRecognitionEvent } from 'expo-speech-recognition';
import { useQuickActionCallback } from 'expo-quick-actions/hooks';
import { writeWavFromFloat32, rms } from './src/audio/wav';
import {
  cancelNative,
  hasNativeRecorder,
  onNativeLevel,
  startNative,
  stopNative,
} from './src/audio/nativeRecorder';
import { SUPPORTED_LANGUAGES } from './src/asr/registry';
import { isInstalled, prepareModel, transcribeWithModel } from './src/asr';
import {
  abortLive,
  localeFor,
  requestSystemPermission,
  resolveOnDevice,
  startLive,
  stopLive,
  systemAvailable,
} from './src/asr/system';
import { sherpaInstalled, sherpaModelById, transcribeWithSherpa } from './src/asr/sherpa';
import { nemoInstalled, transcribeWithNemo, nemoModelDir } from './src/asr/nemo';
import { localFile } from './src/asr/modelManager';
import { startWhisperLive, stopWhisperLive, feedWhisperLive } from './src/asr/live/whisperLive';
import { startSherpaLive, stopSherpaLive, feedSherpaLive } from './src/asr/live/sherpaLive';
import { startLiveMic, stopLiveMic } from './src/audio/liveMic';
import { catalogModelById, CatalogModel, SYSTEM_MODEL_ID } from './src/asr/catalog';
import { transcribeCloud } from './src/asr/cloud';
import {
  getAutoPolish,
  getCloud,
  getOnboarded,
  getSelectedModelId,
  getTranslateTarget,
  getVocab,
} from './src/asr/settings';
import { translateText, translateTargetLabel } from './src/asr/translate';
import { polish } from './src/util/polish';
import { summarize } from './src/util/summarize';
import type { LanguageCode } from './src/asr/types';
import {
  addHistory,
  clearHistory,
  deleteHistory,
  HistoryItem,
  loadHistory,
  updateHistory,
} from './src/history';
import { deleteFileSafe } from './src/util/files';
import { theme } from './src/ui/theme';
import { Waveform, BAR_COUNT } from './src/ui/Waveform';
import { RecordButton } from './src/ui/RecordButton';
import { ProgressBar } from './src/ui/ProgressBar';
import { LanguagePicker } from './src/ui/LanguagePicker';
import { HistoryModal } from './src/ui/HistoryModal';
import { ModelsModal } from './src/ui/ModelsModal';
import { SettingsModal } from './src/ui/SettingsModal';
import { Onboarding } from './src/ui/Onboarding';
import { registerQuickActions, QA_DICTATE, QA_HISTORY } from './src/quickActions';

const IDLE_LEVELS = Array(BAR_COUNT).fill(0.06);

export default function App() {
  const [selectedModelId, setSelectedModelId] = useState<string>(getSelectedModelId());
  const [language, setLanguage] = useState<LanguageCode>('en');
  const [translateTarget, setTranslateTarget] = useState(getTranslateTarget());
  const [busy, setBusy] = useState(false);
  const [downloading, setDownloading] = useState(false);
  const [progress, setProgress] = useState(0);
  const [transcript, setTranscript] = useState('');
  const [liveXlate, setLiveXlate] = useState('');
  const [resultTarget, setResultTarget] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [levels, setLevels] = useState<number[]>(IDLE_LEVELS);
  const [recognizing, setRecognizing] = useState(false);
  const [pickerOpen, setPickerOpen] = useState(false);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [modelsOpen, setModelsOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [history, setHistory] = useState<HistoryItem[]>([]);
  const [liveOK, setLiveOK] = useState(true);
  const [onDeviceLive, setOnDeviceLive] = useState(true);
  const [nativeRec, setNativeRec] = useState(false);
  const [showOnboarding, setShowOnboarding] = useState(!getOnboarded());
  const [, forceTick] = useState(0);

  const [pcmRec, setPcmRec] = useState(false);
  const [modelLive, setModelLive] = useState(false);
  const pcmChunks = useRef<Float32Array[]>([]);
  const pcmRate = useRef(16000);
  const pcmActive = useRef(false);
  const { stream: pcmStream } = useAudioStream({
    sampleRate: 16000,
    channels: 1,
    encoding: 'float32',
    onBuffer: (buf) => {
      if (!pcmActive.current) return;
      const samples = new Float32Array(buf.data);
      pcmChunks.current.push(samples);
      pcmRate.current = buf.sampleRate || 16000;
      const norm = Math.max(0.06, Math.min(1, rms(samples) * 8));
      setLevels((prev) => [...prev.slice(1), norm]);
    },
  });
  const recording = pcmRec;
  const recLang = useRef<LanguageCode>(language);
  const recTarget = useRef(translateTarget);
  const recModel = useRef<CatalogModel | null>(null);

  const committed = useRef('');
  const partial = useRef('');
  const liveLang = useRef<LanguageCode>(language);
  const liveIntent = useRef(false);
  const liveLocale = useRef('en-US');
  const liveOnDevice = useRef(true);
  const lastHistoryId = useRef<string | null>(null);
  const keyboardHandoff = useRef(false);
  const liveScrollRef = useRef<ScrollView>(null);

  const selected = useMemo(
    () => catalogModelById(selectedModelId) ?? catalogModelById(SYSTEM_MODEL_ID)!,
    [selectedModelId]
  );
  const langLabel = SUPPORTED_LANGUAGES.find((l) => l.code === language)?.label ?? language;
  const active = recognizing || recording || nativeRec || modelLive;
  const liveDisplay = translateTarget && liveXlate ? liveXlate : transcript;
  // Pill shows the result's actual target when viewing one, else the live setting.
  const pillTarget = !active && transcript ? resultTarget : translateTarget;

  const idleRef = useRef(true);
  idleRef.current = !active && transcript.trim().length === 0;
  const historyPan = useRef(
    PanResponder.create({
      onMoveShouldSetPanResponder: (_e, g) =>
        idleRef.current && g.dy < -14 && Math.abs(g.dy) > Math.abs(g.dx) * 1.5,
      onPanResponderRelease: (_e, g) => {
        if (g.dy < -45) {
          setHistory(loadHistory());
          setHistoryOpen(true);
        }
      },
    })
  ).current;

  useEffect(() => {
    setHistory(loadHistory());
    setLiveOK(systemAvailable());
  }, []);

  useEffect(() => {
    if (!active) return;
    activateKeepAwakeAsync('localvoice');
    return () => {
      deactivateKeepAwake('localvoice');
    };
  }, [active]);

  useSpeechRecognitionEvent('start', () => {
    setRecognizing(true);
    setError(null);
  });

  // Finish a live (system) session: polish, translate to the target if one is
  // set, then show + save the result. Async so the ML Kit translate can run.
  const finalizeLive = useCallback(async (raw: string) => {
    let text = getAutoPolish() ? polish(raw) : raw;
    const target = recTarget.current;
    if (target) {
      setBusy(true);
      try {
        text = await translateText(text, target, liveLang.current);
      } catch {}
      setBusy(false);
    }
    setTranscript(text);
    setLiveXlate('');
    setResultTarget(target || '');
    if (keyboardHandoff.current) {
      Clipboard.setStringAsync(text);
      keyboardHandoff.current = false;
    }
    const items = addHistory({
      text,
      language: liveLang.current,
      translated: !!target,
      translatedTo: target || undefined,
    });
    lastHistoryId.current = items[0]?.id ?? null;
    setHistory(items);
  }, []);

  useSpeechRecognitionEvent('end', () => {
    setRecognizing(false);
    if (liveIntent.current) {
      // iOS ended recognition on a pause, but the user is still holding the session open.
      // Keep listening so a long dictation doesn't silently die.
      setTimeout(() => {
        if (liveIntent.current) {
          startLive({ locale: liveLocale.current, onDevice: liveOnDevice.current });
        }
      }, 250);
      return;
    }
    setLevels(IDLE_LEVELS);
    const raw = (committed.current + ' ' + partial.current).trim();
    if (!raw) return;
    void finalizeLive(raw);
  });

  useSpeechRecognitionEvent('result', (e) => {
    const text = e.results[0]?.transcript ?? '';
    if (e.isFinal) {
      committed.current = (committed.current + ' ' + text).trim();
      partial.current = '';
    } else {
      partial.current = text;
    }
    setTranscript((committed.current + ' ' + partial.current).trim());
  });

  useSpeechRecognitionEvent('volumechange', (e) => {
    const norm = Math.max(0.06, Math.min(1, (e.value + 2) / 12));
    setLevels((prev) => [...prev.slice(1), norm]);
  });

  useSpeechRecognitionEvent('error', (e) => {
    // no-speech / aborted are normal pauses — let the 'end' handler decide whether to restart.
    if (e.error === 'no-speech' || e.error === 'aborted') return;
    liveIntent.current = false;
    if (e.error === 'language-not-supported' || e.error === 'service-not-allowed') {
      setError(`On-device ${langLabel} isn't installed. Pick a downloaded model in Models.`);
    } else {
      setError(e.message || e.error);
    }
    setRecognizing(false);
  });

  useEffect(() => {
    if (!pcmRec && !modelLive) setLevels(IDLE_LEVELS);
  }, [pcmRec, modelLive]);

  // Live translation: while recording with a target set, translate the running
  // transcript (debounced) so the on-screen text follows in the target language.
  useEffect(() => {
    if (!active || !translateTarget || !transcript.trim()) return;
    const src = transcript;
    let cancelled = false;
    const h = setTimeout(async () => {
      try {
        const t = await translateText(src, translateTarget, recLang.current);
        if (!cancelled) setLiveXlate(t);
      } catch {}
    }, 500);
    return () => {
      cancelled = true;
      clearTimeout(h);
    };
  }, [transcript, active, translateTarget]);

  useEffect(() => {
    if (!nativeRec) return;
    const unsub = onNativeLevel((rms) => {
      const norm = Math.max(0.06, Math.min(1, rms * 3.4));
      setLevels((prev) => [...prev.slice(1), norm]);
    });
    return unsub;
  }, [nativeRec]);

  const onLivePress = useCallback(async () => {
    if (recognizing) {
      liveIntent.current = false; // user-initiated stop — don't auto-restart
      stopLive();
      return;
    }
    try {
      setError(null);
      if (!(await requestSystemPermission())) {
        setError('Speech recognition permission denied');
        return;
      }
      const mic = await requestRecordingPermissionsAsync();
      if (!mic.granted) {
        setError('Microphone permission denied — enable it in Settings.');
        return;
      }
      committed.current = '';
      partial.current = '';
      liveLang.current = language;
      recTarget.current = translateTarget;
      lastHistoryId.current = null;
      setTranscript('');
      setLiveXlate('');
      setResultTarget('');
      const locale = localeFor(language);
      const onDevice = await resolveOnDevice(locale);
      setOnDeviceLive(onDevice);
      liveLocale.current = locale;
      liveOnDevice.current = onDevice;
      liveIntent.current = true;
      startLive({ locale, onDevice, contextualStrings: getVocab() });
    } catch (e: any) {
      liveIntent.current = false;
      setError(e?.message ?? String(e));
    }
  }, [recognizing, language, translateTarget]);

  const onOfflinePress = useCallback(async () => {
    if (recording || nativeRec) {
      const m = recModel.current;
      const lang = recLang.current;
      const target = recTarget.current;
      let uri: string | null = null;
      try {
        if (nativeRec) {
          uri = await stopNative();
          setNativeRec(false);
        } else {
          pcmActive.current = false;
          pcmStream.stop();
          setPcmRec(false);
          uri = await writeWavFromFloat32(pcmChunks.current, pcmRate.current);
          pcmChunks.current = [];
        }
        if (!uri) throw new Error('No audio captured');
        setBusy(true);
        let text = '';
        if (m?.kind === 'nemo' && m.nemo) {
          text = await transcribeWithNemo(m.nemo, uri);
        } else if (m?.kind === 'sherpa' && m.sherpaId) {
          const spec = sherpaModelById(m.sherpaId);
          text = spec ? await transcribeWithSherpa(spec, uri) : '';
        } else if (m?.kind === 'cloud') {
          text = await transcribeCloud(uri, getCloud(), lang, false);
        } else if (m?.kind === 'whisper' && m.whisper) {
          const res = await transcribeWithModel(uri, m.whisper, lang, false);
          text = res.text || '';
        }
        if (getAutoPolish()) text = polish(text);
        if (target && text.trim()) text = await translateText(text, target, lang);
        setTranscript(text);
        setResultTarget(target || '');
        if (text.trim()) {
          const items = addHistory({
            text,
            language: lang,
            translated: !!target,
            translatedTo: target || undefined,
          });
          lastHistoryId.current = items[0]?.id ?? null;
          setHistory(items);
        }
      } catch (e: any) {
        setError(e?.message ?? String(e));
      } finally {
        setBusy(false);
        deleteFileSafe(uri);
      }
      return;
    }

    try {
      setError(null);
      const perm = await requestRecordingPermissionsAsync();
      if (!perm.granted) {
        setError('Microphone permission denied');
        return;
      }

      // Validate / prepare the selected model before we start recording.
      if (selected.kind === 'nemo' && selected.nemo) {
        if (!(await nemoInstalled(selected.nemo))) {
          setError(`Download ${selected.label} in Models first.`);
          return;
        }
      } else if (selected.kind === 'sherpa' && selected.sherpaId) {
        const spec = sherpaModelById(selected.sherpaId);
        if (!spec || !(await sherpaInstalled(spec))) {
          setError(`Download ${selected.label} in Models first.`);
          return;
        }
      } else if (selected.kind === 'cloud') {
        if (!getCloud().apiKey) {
          setError('Add your API key in Settings → Models → Your API key.');
          return;
        }
      } else if (selected.kind === 'whisper' && selected.whisper) {
        if (!isInstalled(selected.whisper)) {
          setDownloading(true);
          setProgress(0);
          await prepareModel(selected.whisper, setProgress);
          setDownloading(false);
        } else {
          await prepareModel(selected.whisper);
        }
      }

      recLang.current = language;
      recTarget.current = translateTarget;
      recModel.current = selected;
      setTranscript('');
      if (hasNativeRecorder) {
        await startNative();
        setNativeRec(true);
      } else {
        await setAudioModeAsync({ allowsRecording: true, playsInSilentMode: true });
        pcmChunks.current = [];
        pcmRate.current = 16000;
        pcmActive.current = true;
        await pcmStream.start();
        setPcmRec(true);
      }
    } catch (e: any) {
      setError(e?.message ?? String(e));
      setDownloading(false);
      setNativeRec(false);
    }
  }, [recording, nativeRec, pcmStream, language, translateTarget, selected]);

  const onModelLivePress = useCallback(async () => {
    if (modelLive) {
      await stopLiveMic();
      setModelLive(false);
      const m = recModel.current;
      const lang = recLang.current;
      const target = recTarget.current;
      setBusy(true);
      try {
        let text =
          m?.kind === 'whisper' ? await stopWhisperLive() : await stopSherpaLive();
        if (getAutoPolish()) text = polish(text);
        if (target && text.trim()) text = await translateText(text, target, lang);
        setTranscript(text);
        setLiveXlate('');
        setResultTarget(target || '');
        if (text.trim()) {
          const items = addHistory({
            text,
            language: lang,
            translated: !!target,
            translatedTo: target || undefined,
          });
          lastHistoryId.current = items[0]?.id ?? null;
          setHistory(items);
        }
      } catch (e: any) {
        setError(e?.message ?? String(e));
      } finally {
        setBusy(false);
      }
      return;
    }

    try {
      setError(null);
      const mic = await requestRecordingPermissionsAsync();
      if (!mic.granted) {
        setError('Microphone permission denied');
        return;
      }
      recLang.current = language;
      recTarget.current = translateTarget;
      recModel.current = selected;
      setTranscript('');
      setLiveXlate('');
      setResultTarget('');
      const onText = (t: string) => setTranscript(t);

      if (selected.kind === 'whisper' && selected.whisper) {
        if (!isInstalled(selected.whisper)) {
          setDownloading(true);
          setProgress(0);
          await prepareModel(selected.whisper, setProgress);
          setDownloading(false);
        }
        await startWhisperLive(localFile(selected.whisper).uri, language, false, onText);
      } else if (selected.kind === 'nemo' && selected.nemo) {
        const dir = await nemoModelDir(selected.nemo);
        if (!dir) {
          setError(`Download ${selected.label} in Models first.`);
          return;
        }
        await startSherpaLive(dir, onText);
      } else {
        setError('This model does not support live transcription.');
        return;
      }

      const useWhisper = selected.kind === 'whisper';
      await startLiveMic(
        (samples, sr) => {
          const norm = Math.max(0.06, Math.min(1, rms(samples) * 8));
          setLevels((prev) => [...prev.slice(1), norm]);
          if (useWhisper) feedWhisperLive(samples, sr);
          else feedSherpaLive(samples, sr);
        },
        (msg) => setError(msg)
      );
      setModelLive(true);
    } catch (e: any) {
      setError(e?.message ?? String(e));
      setDownloading(false);
      await stopLiveMic();
      setModelLive(false);
    }
  }, [modelLive, selected, language, translateTarget]);

  const onMicPress =
    selected.kind === 'system'
      ? onLivePress
      : selected.live
        ? onModelLivePress
        : onOfflinePress;

  const onCancel = useCallback(async () => {
    if (recognizing) {
      liveIntent.current = false;
      abortLive();
      setRecognizing(false);
    }
    if (nativeRec) {
      await cancelNative();
      setNativeRec(false);
    }
    if (pcmRec) {
      pcmActive.current = false;
      try {
        pcmStream.stop();
      } catch {}
      pcmChunks.current = [];
      setPcmRec(false);
    }
    if (modelLive) {
      await stopLiveMic();
      setModelLive(false);
      const m = recModel.current;
      try {
        if (m?.kind === 'whisper') await stopWhisperLive();
        else await stopSherpaLive();
      } catch {}
    }
    committed.current = '';
    partial.current = '';
    setTranscript('');
    setLiveXlate('');
    setResultTarget('');
    setLevels(IDLE_LEVELS);
    setError(null);
  }, [recognizing, pcmRec, nativeRec, modelLive, pcmStream]);

  const syncSettings = useCallback(() => {
    setSelectedModelId(getSelectedModelId());
    setTranslateTarget(getTranslateTarget());
    forceTick((t) => t + 1);
  }, []);

  // Home-screen quick actions (long-press the app icon). Set once on launch;
  // they persist as dynamic shortcuts, so no prebuild is needed.
  const onLivePressRef = useRef(onLivePress);
  useEffect(() => {
    onLivePressRef.current = onLivePress;
  }, [onLivePress]);

  useEffect(() => {
    registerQuickActions();
  }, []);

  const handleQuickAction = useCallback((action: { id: string }) => {
    if (action.id === QA_HISTORY) {
      setHistoryOpen(true);
      return;
    }
    if (action.id === QA_DICTATE) {
      setSelectedModelId(SYSTEM_MODEL_ID);
      setTimeout(() => onLivePressRef.current(), 450);
    }
  }, []);
  useQuickActionCallback(handleQuickAction);

  // Deep link from the Vox keyboard (iOS): vox://dictate-session -> start Live,
  // and copy the result to the clipboard so the keyboard can paste it back.
  useEffect(() => {
    const onUrl = (url: string | null) => {
      if (!url || !url.startsWith('vox://dictate-session')) return;
      keyboardHandoff.current = true;
      setSelectedModelId(SYSTEM_MODEL_ID);
      setTimeout(() => onLivePressRef.current(), 450);
    };
    Linking.getInitialURL().then(onUrl);
    const sub = Linking.addEventListener('url', (e) => onUrl(e.url));
    return () => sub.remove();
  }, []);

  const onPolish = useCallback(() => {
    const cleaned = polish(transcript);
    setTranscript(cleaned);
    if (lastHistoryId.current) setHistory(updateHistory(lastHistoryId.current, cleaned));
  }, [transcript]);

  const onSummarize = useCallback(() => {
    const s = summarize(transcript);
    setTranscript(s);
    // Keep the full transcript in history — don't overwrite it with the gist.
    lastHistoryId.current = null;
  }, [transcript]);

  // Import an existing audio file and transcribe it with the selected model.
  // The built-in live engine can't read files, so this needs a downloaded or
  // cloud model. Offline (sherpa/whisper) models expect WAV; cloud takes anything.
  const onImportFile = useCallback(async () => {
    if (busy || active) return;
    try {
      setError(null);
      const picked = await DocumentPicker.getDocumentAsync({
        type: 'audio/*',
        copyToCacheDirectory: true,
      });
      if (picked.canceled || !picked.assets?.[0]) return;
      const uri = picked.assets[0].uri;
      const m = selected;

      if (m.kind === 'system') {
        setError('Pick a downloaded or cloud model in Models to transcribe a file.');
        return;
      }
      if (m.kind === 'nemo' && m.nemo && !(await nemoInstalled(m.nemo))) {
        setError(`Download ${m.label} in Models first.`);
        return;
      }
      if (m.kind === 'sherpa' && m.sherpaId) {
        const spec = sherpaModelById(m.sherpaId);
        if (!spec || !(await sherpaInstalled(spec))) {
          setError(`Download ${m.label} in Models first.`);
          return;
        }
      }
      if (m.kind === 'cloud' && !getCloud().apiKey) {
        setError('Add your API key in Settings → Models → Your API key.');
        return;
      }

      setTranscript('');
      setBusy(true);
      if (m.kind === 'whisper' && m.whisper) {
        if (!isInstalled(m.whisper)) {
          setDownloading(true);
          setProgress(0);
          await prepareModel(m.whisper, setProgress);
          setDownloading(false);
        } else {
          await prepareModel(m.whisper);
        }
      }

      let text = '';
      if (m.kind === 'nemo' && m.nemo) {
        text = await transcribeWithNemo(m.nemo, uri);
      } else if (m.kind === 'sherpa' && m.sherpaId) {
        const spec = sherpaModelById(m.sherpaId);
        text = spec ? await transcribeWithSherpa(spec, uri) : '';
      } else if (m.kind === 'cloud') {
        text = await transcribeCloud(uri, getCloud(), language, false);
      } else if (m.kind === 'whisper' && m.whisper) {
        const res = await transcribeWithModel(uri, m.whisper, language, false);
        text = res.text || '';
      }
      if (getAutoPolish()) text = polish(text);
      if (translateTarget && text.trim()) text = await translateText(text, translateTarget, language);
      setTranscript(text);
      setResultTarget(translateTarget || '');
      if (text.trim()) {
        const items = addHistory({
          text,
          language,
          translated: !!translateTarget,
          translatedTo: translateTarget || undefined,
        });
        lastHistoryId.current = items[0]?.id ?? null;
        setHistory(items);
      } else {
        setError('No speech found — for offline models the file must be a 16 kHz WAV; cloud models accept any format.');
      }
    } catch (e: any) {
      setError(e?.message ?? String(e));
      setDownloading(false);
    } finally {
      setBusy(false);
    }
  }, [busy, active, selected, language, translateTarget]);

  const statusLine = (() => {
    if (busy) return 'Transcribing…';
    if (downloading) return `Downloading model · ${Math.round(progress * 100)}%`;
    if (active) return '';
    if (selected.kind === 'whisper' && selected.whisper && !isInstalled(selected.whisper)) {
      return `${selected.label} · ${selected.sizeLabel} downloads on first use`;
    }
    return '';
  })();

  if (showOnboarding) {
    return (
      <View style={styles.root}>
        <StatusBar style="light" />
        <Onboarding onDone={() => setShowOnboarding(false)} />
      </View>
    );
  }

  return (
    <View style={styles.root}>
      <StatusBar style="light" />
      <SafeAreaView
        style={[
          styles.safe,
          Platform.OS === 'android' && { paddingTop: (RNStatusBar.currentHeight ?? 24) + 4 },
        ]}
      >
        <View style={styles.topbar}>
          <Pressable
            style={styles.topIcon}
            onPress={() => {
              setHistory(loadHistory());
              setHistoryOpen(true);
            }}
            hitSlop={8}
          >
            <Ionicons name="time-outline" size={22} color={theme.textDim} />
          </Pressable>

          <Pressable
            style={[styles.modePill, active && styles.disabled]}
            onPress={() => setPickerOpen(true)}
            disabled={active}
            hitSlop={6}
          >
            <Ionicons name="language" size={15} color={theme.text} />
            <Text style={styles.modeLabel}>
              {pillTarget
                ? `${langLabel} → ${translateTargetLabel(pillTarget)}`
                : langLabel}
            </Text>
            <Ionicons name="chevron-down" size={14} color={theme.textDim} />
          </Pressable>

          <Pressable style={styles.topIcon} onPress={() => setSettingsOpen(true)} hitSlop={8}>
            <Ionicons name="settings-outline" size={22} color={theme.textDim} />
          </Pressable>
        </View>

        <View style={styles.dottedDivider} />

        <View style={styles.canvas} {...historyPan.panHandlers}>
          {active ? (
            <View style={styles.liveWrap}>
              <Waveform levels={levels} active={active} />
              {liveDisplay.trim().length > 0 ? (
                <ScrollView
                  ref={liveScrollRef}
                  style={styles.liveScroll}
                  contentContainerStyle={styles.liveScrollContent}
                  showsVerticalScrollIndicator={false}
                  onContentSizeChange={() =>
                    liveScrollRef.current?.scrollToEnd({ animated: true })
                  }
                >
                  <Text style={styles.livePartial}>{liveDisplay}</Text>
                </ScrollView>
              ) : (
                <View style={styles.center}>
                  <Text style={styles.listening}>Listening…</Text>
                </View>
              )}
            </View>
          ) : transcript.trim().length > 0 ? (
            <View style={styles.resultWrap}>
              <TextInput
                style={styles.transcript}
                value={transcript}
                onChangeText={setTranscript}
                onEndEditing={(e) => {
                  if (lastHistoryId.current) {
                    setHistory(updateHistory(lastHistoryId.current, e.nativeEvent.text));
                  }
                }}
                multiline
                scrollEnabled
              />
              <View style={styles.resultActions}>
                <Pressable style={styles.resAction} onPress={onPolish} hitSlop={8}>
                  <Ionicons name="sparkles-outline" size={20} color={theme.text} />
                </Pressable>
                {transcript.trim().length > 160 && (
                  <Pressable style={styles.resAction} onPress={onSummarize} hitSlop={8}>
                    <Ionicons name="list-outline" size={20} color={theme.text} />
                  </Pressable>
                )}
                <Pressable
                  style={styles.resAction}
                  onPress={() => Clipboard.setStringAsync(transcript)}
                  hitSlop={8}
                >
                  <Ionicons name="copy-outline" size={20} color={theme.text} />
                </Pressable>
                <Pressable
                  style={styles.resAction}
                  onPress={() => Share.share({ message: transcript })}
                  hitSlop={8}
                >
                  <Ionicons name="share-outline" size={20} color={theme.text} />
                </Pressable>
                <Pressable style={styles.resAction} onPress={onCancel} hitSlop={8}>
                  <Ionicons name="close" size={22} color={theme.textDim} />
                </Pressable>
              </View>
            </View>
          ) : (
            <View style={styles.center}>
              <Text style={styles.bigHint}>Tap to speak</Text>
            </View>
          )}
        </View>

        <View style={styles.dock}>
          {!active && transcript.trim().length === 0 && (
            <Pressable
              onPress={() => {
                setHistory(loadHistory());
                setHistoryOpen(true);
              }}
              hitSlop={10}
              style={styles.swipeHintRow}
            >
              <Ionicons name="chevron-up" size={15} color={theme.textFaint} />
              <Text style={styles.swipeHint}>Swipe up to see your history</Text>
              <Ionicons name="chevron-up" size={15} color={theme.textFaint} />
            </Pressable>
          )}

          {downloading && <ProgressBar ratio={progress} />}

          {active ? (
            <View style={styles.recRow}>
              <Pressable style={styles.cancelBtn} onPress={onCancel} hitSlop={10}>
                <Text style={styles.cancelText}>Cancel</Text>
              </Pressable>
              <RecordButton recording={active} busy={busy || downloading} onPress={onMicPress} />
              {transcript.trim().length > 0 ? (
                <Pressable
                  style={styles.copyBtn}
                  onPress={() => Clipboard.setStringAsync(transcript)}
                  hitSlop={10}
                >
                  <Ionicons name="copy-outline" size={24} color={theme.textDim} />
                </Pressable>
              ) : (
                <View style={styles.copyBtn} />
              )}
            </View>
          ) : (
            <View style={styles.idleDock}>
              <RecordButton recording={active} busy={busy || downloading} onPress={onMicPress} />
              {transcript.trim().length === 0 && (
                <Pressable onPress={onImportFile} hitSlop={8} style={styles.importRow}>
                  <Ionicons name="document-attach-outline" size={16} color={theme.textFaint} />
                  <Text style={styles.importText}>Import audio file</Text>
                </Pressable>
              )}
            </View>
          )}

          {statusLine.length > 0 && <Text style={styles.status}>{statusLine}</Text>}
          {error && <Text style={styles.error}>{error}</Text>}
        </View>
      </SafeAreaView>

      <LanguagePicker
        visible={pickerOpen}
        current={language}
        onSelect={setLanguage}
        onClose={() => setPickerOpen(false)}
      />
      <HistoryModal
        visible={historyOpen}
        items={history}
        onClose={() => setHistoryOpen(false)}
        onSelect={(item) => {
          setTranscript(item.text);
          setResultTarget(item.translatedTo ?? (item.translated ? 'en' : ''));
          setLanguage(item.language);
          setHistoryOpen(false);
        }}
        onDelete={(id) => setHistory(deleteHistory(id))}
        onClear={() => setHistory(clearHistory())}
      />
      <ModelsModal
        visible={modelsOpen}
        onClose={() => setModelsOpen(false)}
        onChanged={syncSettings}
        onWipeData={() => {
          setHistory(clearHistory());
          setTranscript('');
        }}
      />
      <SettingsModal
        visible={settingsOpen}
        onClose={() => setSettingsOpen(false)}
        onChanged={syncSettings}
        onOpenModels={() => {
          setSettingsOpen(false);
          setModelsOpen(true);
        }}
        onWipeData={() => {
          setHistory(clearHistory());
          setTranscript('');
          syncSettings();
        }}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: theme.bg },
  safe: { flex: 1, paddingHorizontal: Platform.OS === 'ios' ? 32 : 22, paddingTop: 6 },
  disabled: { opacity: 0.45 },
  topbar: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingTop: 8,
    paddingBottom: 14,
  },
  topIcon: {
    width: 44,
    height: 36,
    alignItems: 'center',
    justifyContent: 'center',
  },
  modePill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 7,
    backgroundColor: theme.surface,
    paddingLeft: 14,
    paddingRight: 12,
    paddingVertical: 8,
    borderRadius: 999,
  },
  modeLabel: { color: theme.text, fontSize: 15, fontWeight: '600' },
  dottedDivider: {
    borderBottomWidth: 1.5,
    borderColor: theme.border,
    borderStyle: 'dotted',
    marginBottom: 4,
  },
  canvas: { flex: 1, overflow: 'hidden' },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 20 },
  liveWrap: { flex: 1, gap: 16, paddingTop: 8 },
  liveScroll: { flex: 1 },
  liveScrollContent: { paddingBottom: 20 },
  listening: { color: theme.textDim, fontSize: 15, fontWeight: '500' },
  livePartial: {
    color: theme.text,
    fontSize: 22,
    fontWeight: '500',
    lineHeight: 31,
    textAlign: 'center',
    paddingHorizontal: 12,
  },
  bigHint: { color: theme.textFaint, fontSize: 18, fontWeight: '500' },
  resultWrap: { flex: 1, paddingTop: 18 },
  transcript: {
    flex: 1,
    color: theme.text,
    fontSize: 27,
    fontWeight: '500',
    lineHeight: 37,
    textAlignVertical: 'top',
    padding: 0,
  },
  resultActions: {
    flexDirection: 'row',
    justifyContent: 'center',
    gap: 14,
    paddingTop: 14,
  },
  resAction: {
    width: 48,
    height: 48,
    borderRadius: 24,
    backgroundColor: theme.surface,
    alignItems: 'center',
    justifyContent: 'center',
  },
  dock: { paddingBottom: 16, alignItems: 'center' },
  swipeHintRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 22 },
  swipeHint: { color: theme.textFaint, fontSize: 14, fontWeight: '500' },
  recRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    width: '100%',
  },
  cancelBtn: { width: 72, alignItems: 'flex-start', justifyContent: 'center' },
  cancelText: { color: theme.textDim, fontSize: 16, fontWeight: '500' },
  copyBtn: { width: 72, alignItems: 'flex-end', justifyContent: 'center' },
  idleDock: { alignItems: 'center', gap: 16 },
  importRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  importText: { color: theme.textFaint, fontSize: 14, fontWeight: '500' },
  status: { color: theme.textDim, textAlign: 'center', marginTop: 14, fontSize: 13 },
  error: { color: theme.danger, textAlign: 'center', marginTop: 8, fontSize: 13 },
});
