import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Animated,
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  View,
} from 'react-native';
import { StatusBar } from 'expo-status-bar';
import { Ionicons } from '@expo/vector-icons';
import {
  requestRecordingPermissionsAsync,
  setAudioModeAsync,
  useAudioRecorder,
  useAudioRecorderState,
} from 'expo-audio';
import { WAV_16K_MONO } from './src/audio/recording';
import { SUPPORTED_LANGUAGES } from './src/asr/registry';
import { isInstalled, prepare, resolveModel, transcribeFile } from './src/asr';
import type { LanguageCode } from './src/asr/types';
import { addHistory, clearHistory, deleteHistory, HistoryItem, loadHistory } from './src/history';
import { theme } from './src/ui/theme';
import { Waveform, BAR_COUNT } from './src/ui/Waveform';
import { RecordButton } from './src/ui/RecordButton';
import { ProgressBar } from './src/ui/ProgressBar';
import { LanguagePicker } from './src/ui/LanguagePicker';
import { HistoryModal } from './src/ui/HistoryModal';

const IDLE_LEVELS = Array(BAR_COUNT).fill(0.06);

export default function App() {
  const [language, setLanguage] = useState<LanguageCode>('en');
  const [translate, setTranslate] = useState(false);
  const [busy, setBusy] = useState(false);
  const [downloading, setDownloading] = useState(false);
  const [progress, setProgress] = useState(0);
  const [transcript, setTranscript] = useState('');
  const [resultTranslated, setResultTranslated] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [levels, setLevels] = useState<number[]>(IDLE_LEVELS);
  const [pickerOpen, setPickerOpen] = useState(false);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [history, setHistory] = useState<HistoryItem[]>([]);

  const recorder = useAudioRecorder(WAV_16K_MONO);
  const recorderState = useAudioRecorderState(recorder, 80);
  const recording = recorderState.isRecording;

  const model = useMemo(() => resolveModel(language), [language]);
  const langLabel = SUPPORTED_LANGUAGES.find((l) => l.code === language)?.label ?? language;
  const fade = useRef(new Animated.Value(1)).current;

  useEffect(() => {
    (async () => {
      const perm = await requestRecordingPermissionsAsync();
      if (!perm.granted) setError('Microphone permission denied');
      await setAudioModeAsync({ allowsRecording: true, playsInSilentMode: true });
      setHistory(loadHistory());
    })();
  }, []);

  useEffect(() => {
    if (!recording) {
      setLevels(IDLE_LEVELS);
      return;
    }
    const m = recorderState.metering ?? -55;
    const norm = Math.max(0.06, Math.min(1, (m + 55) / 55));
    setLevels((prev) => [...prev.slice(1), norm]);
  }, [recorderState.metering, recording]);

  useEffect(() => {
    fade.setValue(0);
    Animated.timing(fade, { toValue: 1, duration: 280, useNativeDriver: true }).start();
  }, [transcript, fade]);

  const onMicPress = useCallback(async () => {
    try {
      setError(null);
      if (recording) {
        await recorder.stop();
        const uri = recorder.uri;
        if (!uri) throw new Error('No audio captured');
        setBusy(true);
        const res = await transcribeFile(uri, language, translate);
        const text = res.text || '';
        setTranscript(text);
        setResultTranslated(translate);
        setBusy(false);
        if (text.trim()) {
          setHistory(addHistory({ text, language, translated: translate }));
        }
      } else {
        if (!isInstalled(model)) {
          setDownloading(true);
          setProgress(0);
          await prepare(language, setProgress);
          setDownloading(false);
        } else {
          await prepare(language);
        }
        setTranscript('');
        await recorder.prepareToRecordAsync(WAV_16K_MONO);
        recorder.record();
      }
    } catch (e: any) {
      setError(e?.message ?? String(e));
      setBusy(false);
      setDownloading(false);
    }
  }, [recording, recorder, language, translate, model]);

  const installed = isInstalled(model);
  const statusLine = recording
    ? 'Listening…'
    : busy
      ? 'Transcribing…'
      : downloading
        ? `Downloading model · ${Math.round(progress * 100)}%`
        : installed
          ? 'Tap the mic and speak'
          : `${model.label} · ${model.sizeMB} MB downloads on first use`;

  return (
    <View style={styles.root}>
      <StatusBar style="light" />
      <SafeAreaView style={styles.safe}>
        <View style={styles.header}>
          <Text style={styles.brand}>LocalVoice</Text>
          <Pressable
            style={styles.iconBtn}
            onPress={() => {
              setHistory(loadHistory());
              setHistoryOpen(true);
            }}
            hitSlop={8}
          >
            <Ionicons name="time-outline" size={22} color={theme.text} />
          </Pressable>
        </View>

        <View style={styles.card}>
          <Pressable style={styles.langRow} onPress={() => setPickerOpen(true)} hitSlop={6}>
            <Text style={styles.langText}>
              {resultTranslated && transcript ? 'English' : langLabel}
            </Text>
            <Ionicons name="chevron-expand" size={16} color={theme.textDim} />
          </Pressable>

          <ScrollView style={styles.transcriptScroll} contentContainerStyle={{ flexGrow: 1 }}>
            {transcript ? (
              <Animated.Text style={[styles.transcript, { opacity: fade }]}>
                {transcript}
              </Animated.Text>
            ) : (
              <Text style={styles.placeholder}>
                {recording ? 'Listening…' : 'Speak to see text here'}
              </Text>
            )}
          </ScrollView>
        </View>

        <View style={styles.bottom}>
          <Waveform levels={levels} active={recording} />

          <View style={styles.controls}>
            <Pressable style={styles.pill} onPress={() => setPickerOpen(true)}>
              <Ionicons name="language" size={16} color={theme.text} />
              <Text style={styles.pillText}>{langLabel}</Text>
            </Pressable>

            <View style={styles.pill}>
              <Text style={styles.pillText}>Translate → EN</Text>
              <Switch
                value={translate}
                onValueChange={setTranslate}
                trackColor={{ true: theme.primary, false: theme.border }}
                thumbColor="#fff"
                style={styles.switch}
              />
            </View>
          </View>

          <RecordButton recording={recording} busy={busy || downloading} onPress={onMicPress} />
          {downloading && <ProgressBar ratio={progress} />}
          <Text style={styles.status}>{statusLine}</Text>
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
          setResultTranslated(item.translated);
          setLanguage(item.language);
          setHistoryOpen(false);
        }}
        onDelete={(id) => setHistory(deleteHistory(id))}
        onClear={() => setHistory(clearHistory())}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: theme.bg },
  safe: { flex: 1, paddingHorizontal: 20 },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingTop: 8,
    paddingBottom: 16,
  },
  brand: { color: theme.text, fontSize: 30, fontWeight: '800', letterSpacing: -0.5 },
  iconBtn: {
    width: 42,
    height: 42,
    borderRadius: 21,
    backgroundColor: theme.surface,
    alignItems: 'center',
    justifyContent: 'center',
  },
  card: {
    flex: 1,
    backgroundColor: theme.surface,
    borderRadius: 24,
    padding: 20,
    marginBottom: 18,
  },
  langRow: { flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 14 },
  langText: { color: theme.text, fontSize: 16, fontWeight: '700' },
  transcriptScroll: { flex: 1 },
  transcript: { color: theme.text, fontSize: 30, fontWeight: '600', lineHeight: 40 },
  placeholder: { color: theme.textFaint, fontSize: 30, fontWeight: '600', lineHeight: 40 },
  bottom: { paddingBottom: 10 },
  controls: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginTop: 10,
    marginBottom: 16,
    gap: 10,
  },
  pill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    backgroundColor: theme.surface,
    paddingHorizontal: 14,
    paddingVertical: 10,
    borderRadius: 999,
  },
  pillText: { color: theme.text, fontSize: 14, fontWeight: '600' },
  switch: { transform: [{ scale: 0.8 }], marginVertical: -8, marginRight: -4 },
  status: { color: theme.textDim, textAlign: 'center', marginTop: 14, fontSize: 14 },
  error: { color: theme.danger, textAlign: 'center', marginTop: 8, fontSize: 13 },
});
