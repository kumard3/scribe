import { useEffect, useState } from 'react';
import {
  Alert,
  AppState,
  Linking,
  Modal,
  Platform,
  Pressable,
  SafeAreaView,
  ScrollView,
  StatusBar as RNStatusBar,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import {
  getAutoPolish,
  getChunkPauseMs,
  getDictationStyle,
  getTranslateTarget,
  getVocab,
  setAutoPolish,
  setChunkPauseMs,
  setDictationStyle,
  setTranslateTarget,
  setVocab,
} from '../asr/settings';
import { deleteAllModels } from '../asr/modelManager';
import { clearHistory } from '../history';
import { FlowBubble, flowBubbleSupported } from '../flowBubble';
import { TRANSLATE_TARGETS, translateTargetLabel, translationSupported } from '../asr/translate';
import { LanguagePicker } from './LanguagePicker';
import { theme } from './theme';
import { BRAND } from './brand';

type Props = {
  visible: boolean;
  onClose: () => void;
  onChanged: () => void;
  onOpenModels: () => void;
  onWipeData: () => void;
};

const APP_VERSION = '1.0.0';

export function SettingsModal({ visible, onClose, onChanged, onOpenModels, onWipeData }: Props) {
  const [vocab, setVocabState] = useState<string[]>([]);
  const [autoPolish, setAutoPolishState] = useState(false);
  const [style, setStyleState] = useState<'auto' | 'english' | 'hinglish'>('auto');
  const [pauseMs, setPauseState] = useState(550);
  const [target, setTargetState] = useState('');
  const [targetPickerOpen, setTargetPickerOpen] = useState(false);
  const [input, setInput] = useState('');
  const [bubbleOverlay, setBubbleOverlay] = useState(false);
  const [bubbleAccess, setBubbleAccess] = useState(false);
  const [bubbleRunning, setBubbleRunning] = useState(false);

  async function refreshBubble() {
    if (!flowBubbleSupported) return;
    setBubbleOverlay(await FlowBubble.isOverlayGranted());
    setBubbleAccess(await FlowBubble.isAccessibilityEnabled());
    setBubbleRunning(await FlowBubble.isRunning());
  }

  useEffect(() => {
    if (!visible) return;
    setVocabState(getVocab());
    setAutoPolishState(getAutoPolish());
    setStyleState(getDictationStyle());
    setPauseState(getChunkPauseMs());
    setTargetState(getTranslateTarget());
    refreshBubble();
  }, [visible]);

  // Permissions are granted in system settings; refresh when we come back.
  useEffect(() => {
    if (!visible || !flowBubbleSupported) return;
    const sub = AppState.addEventListener('change', (s) => {
      if (s === 'active') refreshBubble();
    });
    return () => sub.remove();
  }, [visible]);

  async function toggleBubble(v: boolean) {
    if (!v) {
      await FlowBubble.stop();
      setBubbleRunning(false);
      return;
    }
    if (!(await FlowBubble.isOverlayGranted())) {
      await FlowBubble.requestOverlayPermission();
      return; // user returns from settings; AppState listener re-checks
    }
    await FlowBubble.start();
    setBubbleRunning(true);
  }

  function selectTarget(code: string) {
    setTranslateTarget(code);
    setTargetState(code);
    setTargetPickerOpen(false);
    onChanged();
  }

  function add() {
    const phrase = input.trim();
    if (!phrase) return;
    const next = Array.from(new Set([...vocab, phrase]));
    setVocab(next);
    setVocabState(next);
    setInput('');
    onChanged();
  }

  function remove(phrase: string) {
    const next = vocab.filter((v) => v !== phrase);
    setVocab(next);
    setVocabState(next);
    onChanged();
  }

  function toggleAuto(v: boolean) {
    setAutoPolish(v);
    setAutoPolishState(v);
    onChanged();
  }

  function openKeyboardSettings() {
    Linking.sendIntent('android.settings.INPUT_METHOD_SETTINGS').catch(() => {});
  }

  function wipeAll() {
    Alert.alert(
      'Delete all data',
      'This removes every downloaded model and your entire transcription history. This cannot be undone.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Delete everything',
          style: 'destructive',
          onPress: () => {
            deleteAllModels();
            clearHistory();
            onWipeData();
          },
        },
      ],
    );
  }

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose} presentationStyle="fullScreen">
      <SafeAreaView
        style={[
          styles.page,
          Platform.OS === 'android' && { paddingTop: (RNStatusBar.currentHeight ?? 24) + 4 },
        ]}
      >
        <View style={styles.header}>
          <Text style={styles.title}>Settings</Text>
          <Pressable style={styles.close} onPress={onClose} hitSlop={10}>
            <Ionicons name="close" size={24} color={theme.text} />
          </Pressable>
        </View>

        <ScrollView contentContainerStyle={styles.body} keyboardShouldPersistTaps="handled">
          <Text style={styles.section}>Transcription</Text>
          <Pressable style={styles.actionBtn} onPress={onOpenModels}>
            <Ionicons name="cube-outline" size={18} color={theme.text} />
            <Text style={styles.actionText}>Models</Text>
            <View style={{ flex: 1 }} />
            <Ionicons name="chevron-forward" size={18} color={theme.textFaint} />
          </Pressable>
          <View style={[styles.card, { marginTop: 10 }]}>
            <View style={styles.row}>
              <View style={{ flex: 1 }}>
                <Text style={styles.label}>Auto-polish</Text>
                <Text style={styles.meta}>
                  Gemma 4 E2B cleans punctuation and fillers after ASR. Audio never goes to Gemma.
                </Text>
              </View>
              <Switch
                value={autoPolish}
                onValueChange={toggleAuto}
                trackColor={{ true: theme.primary, false: theme.border }}
                thumbColor="#fff"
              />
            </View>
            <View style={styles.rowDivider}>
              <Text style={styles.label}>Style</Text>
              <Text style={styles.meta}>WhatsApp Hinglish, English, or keep the mix.</Text>
              <View style={styles.segment}>
                {(['auto', 'english', 'hinglish'] as const).map((s) => (
                  <Pressable
                    key={s}
                    style={[styles.segBtn, style === s && styles.segBtnOn]}
                    onPress={() => {
                      setDictationStyle(s);
                      setStyleState(s);
                      onChanged();
                    }}
                  >
                    <Text style={[styles.segText, style === s && styles.segTextOn]}>
                      {s === 'auto' ? 'Auto' : s === 'english' ? 'English' : 'Hinglish'}
                    </Text>
                  </Pressable>
                ))}
              </View>
            </View>
            <View style={styles.rowDivider}>
              <Text style={styles.label}>Chunk pause</Text>
              <Text style={styles.meta}>How long a pause closes a live chunk.</Text>
              <View style={styles.segment}>
                {[400, 550, 700].map((ms) => (
                  <Pressable
                    key={ms}
                    style={[styles.segBtn, pauseMs === ms && styles.segBtnOn]}
                    onPress={() => {
                      setChunkPauseMs(ms);
                      setPauseState(ms);
                      onChanged();
                    }}
                  >
                    <Text style={[styles.segText, pauseMs === ms && styles.segTextOn]}>{ms} ms</Text>
                  </Pressable>
                ))}
              </View>
            </View>
            <Pressable
              style={[styles.row, styles.rowDivider]}
              onPress={() => translationSupported && setTargetPickerOpen(true)}
              disabled={!translationSupported}
            >
              <View style={{ flex: 1 }}>
                <Text style={styles.label}>Translate to</Text>
                <Text style={styles.meta}>
                  {translationSupported
                    ? 'Speak any language, get text in your chosen language. Runs on-device; each language downloads once.'
                    : 'Translation isn’t available in this build.'}
                </Text>
              </View>
              <Text style={styles.pickValue}>
                {target ? translateTargetLabel(target) : 'Off'}
              </Text>
              <Ionicons name="chevron-forward" size={18} color={theme.textFaint} />
            </Pressable>
          </View>

          <Text style={styles.section}>Custom vocabulary</Text>
          <Text style={styles.meta}>
            Names, brands, or jargon to recognize more accurately (e.g. “Assistable”).
          </Text>
          <View style={styles.addRow}>
            <TextInput
              style={styles.input}
              placeholder="Add a word or phrase"
              placeholderTextColor={theme.textFaint}
              value={input}
              onChangeText={setInput}
              onSubmitEditing={add}
              returnKeyType="done"
              autoCorrect={false}
            />
            <Pressable style={styles.addBtn} onPress={add}>
              <Ionicons name="add" size={22} color={theme.onPrimary} />
            </Pressable>
          </View>
          {vocab.length === 0 ? (
            <Text style={styles.empty}>No custom words yet.</Text>
          ) : (
            vocab.map((v) => (
              <View key={v} style={styles.chip}>
                <Text style={styles.chipText}>{v}</Text>
                <Pressable onPress={() => remove(v)} hitSlop={8}>
                  <Ionicons name="close-circle" size={18} color={theme.textFaint} />
                </Pressable>
              </View>
            ))
          )}

          {Platform.OS === 'android' && (
            <>
              <Text style={styles.section}>Voice keyboard</Text>
              <Text style={styles.meta}>
                {`Enable the ${BRAND} keyboard, then tap 🌐 in any app to dictate inline.`}
              </Text>
              <Pressable style={styles.actionBtn} onPress={openKeyboardSettings}>
                <Ionicons name="keypad-outline" size={18} color={theme.text} />
                <Text style={styles.actionText}>Open keyboard settings</Text>
              </Pressable>
            </>
          )}

          {flowBubbleSupported && (
            <>
              <Text style={styles.section}>Flow Bubble</Text>
              <Text style={styles.meta}>
                A floating mic that appears when you tap into a text box in any app. Tap it,
                speak, and the text drops right in. (Needs Accessibility, below, to show only
                while typing.)
              </Text>
              <View style={[styles.card, { marginTop: 10 }]}>
                <View style={styles.row}>
                  <View style={{ flex: 1 }}>
                    <Text style={styles.label}>Show Flow Bubble</Text>
                    <Text style={styles.meta}>
                      {bubbleOverlay
                        ? 'Floating dictation is ready.'
                        : 'Needs “display over other apps”.'}
                    </Text>
                  </View>
                  <Switch
                    value={bubbleRunning}
                    onValueChange={toggleBubble}
                    trackColor={{ true: theme.primary, false: theme.border }}
                    thumbColor="#fff"
                  />
                </View>
                {!bubbleOverlay && (
                  <Pressable
                    style={[styles.actionBtn, { marginTop: 12 }]}
                    onPress={() => FlowBubble.requestOverlayPermission()}
                  >
                    <Ionicons name="layers-outline" size={18} color={theme.text} />
                    <Text style={styles.actionText}>Allow display over other apps</Text>
                  </Pressable>
                )}
                <Pressable
                  style={[styles.actionBtn, { marginTop: 10 }]}
                  onPress={() => FlowBubble.openAccessibilitySettings()}
                >
                  <Ionicons
                    name={bubbleAccess ? 'checkmark-circle-outline' : 'accessibility-outline'}
                    size={18}
                    color={bubbleAccess ? theme.primary : theme.text}
                  />
                  <Text style={styles.actionText}>
                    {bubbleAccess ? 'Auto-paste enabled' : 'Enable auto-paste (Accessibility)'}
                  </Text>
                </Pressable>
                <Text style={styles.meta}>
                  Without Accessibility, dictated text is copied to the clipboard to paste
                  yourself.
                </Text>
              </View>
            </>
          )}

          <Text style={styles.section}>Data</Text>
          <Pressable style={styles.dangerBtn} onPress={wipeAll}>
            <Ionicons name="trash-outline" size={18} color={theme.danger} />
            <Text style={styles.dangerText}>Delete all data</Text>
          </Pressable>

          <Text style={styles.section}>About</Text>
          <View style={styles.card}>
            <Text style={styles.label}>
              {BRAND} {APP_VERSION}
            </Text>
            <Text style={styles.meta}>
              Transcribed on your phone. No account, no tracking, and your voice is never sent to
              us. Download a model to stay fully offline.
            </Text>
          </View>
        </ScrollView>
      </SafeAreaView>
      <LanguagePicker
        visible={targetPickerOpen}
        current={target}
        title="Translate to"
        options={TRANSLATE_TARGETS}
        onSelect={selectTarget}
        onClose={() => setTargetPickerOpen(false)}
      />
    </Modal>
  );
}

const styles = StyleSheet.create({
  page: { flex: 1, backgroundColor: theme.bg },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 24,
    paddingTop: 8,
    paddingBottom: 8,
  },
  title: { color: theme.text, fontSize: 26, fontWeight: '800' },
  close: {
    width: 38,
    height: 38,
    borderRadius: 19,
    backgroundColor: theme.surface,
    alignItems: 'center',
    justifyContent: 'center',
  },
  body: { paddingHorizontal: 24, paddingBottom: 48 },
  section: {
    color: theme.textDim,
    fontSize: 12,
    fontWeight: '700',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginTop: 24,
    marginBottom: 8,
  },
  card: { backgroundColor: theme.surface, borderRadius: 14, padding: 16 },
  segment: {
    flexDirection: 'row',
    backgroundColor: theme.surfaceAlt,
    borderRadius: 12,
    padding: 4,
    gap: 4,
    marginTop: 12,
  },
  segBtn: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 7,
    paddingVertical: 10,
    borderRadius: 9,
  },
  segBtnOn: { backgroundColor: theme.primary },
  segText: { color: theme.textDim, fontSize: 14, fontWeight: '700' },
  segTextOn: { color: theme.onPrimary },
  rowDivider: {
    marginTop: 16,
    paddingTop: 16,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: theme.border,
  },
  row: { flexDirection: 'row', alignItems: 'center' },
  pickValue: { color: theme.textDim, fontSize: 15, fontWeight: '600', marginRight: 4 },
  label: { color: theme.text, fontSize: 16, fontWeight: '600' },
  meta: { color: theme.textFaint, fontSize: 13, marginTop: 4, lineHeight: 18 },
  addRow: { flexDirection: 'row', gap: 10, marginTop: 12, marginBottom: 8 },
  input: {
    flex: 1,
    backgroundColor: theme.surfaceAlt,
    borderRadius: 12,
    paddingHorizontal: 14,
    paddingVertical: 12,
    color: theme.text,
    fontSize: 15,
  },
  addBtn: {
    width: 46,
    borderRadius: 12,
    backgroundColor: theme.primary,
    alignItems: 'center',
    justifyContent: 'center',
  },
  empty: { color: theme.textFaint, fontSize: 14, paddingVertical: 14 },
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    backgroundColor: theme.surfaceAlt,
    borderRadius: 12,
    paddingHorizontal: 14,
    paddingVertical: 12,
    marginTop: 8,
  },
  chipText: { color: theme.text, fontSize: 15, fontWeight: '500' },
  actionBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    backgroundColor: theme.surface,
    borderRadius: 14,
    paddingHorizontal: 16,
    paddingVertical: 15,
    marginTop: 8,
  },
  actionText: { color: theme.text, fontSize: 16, fontWeight: '600' },
  dangerBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    backgroundColor: theme.surface,
    borderRadius: 14,
    paddingHorizontal: 16,
    paddingVertical: 15,
  },
  dangerText: { color: theme.danger, fontSize: 16, fontWeight: '700' },
});
