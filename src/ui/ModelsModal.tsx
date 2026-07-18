import { useEffect, useRef, useState } from 'react';
import {
  Alert,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { buildCatalog, CatalogModel } from '../asr/catalog';
import { formatMB } from '../asr/registry';
import {
  deleteAllModels,
  deleteModel,
  downloadModel,
  installedStorageBytes,
  isInstalled,
} from '../asr/modelManager';
import { deleteNemo, downloadNemo, nemoInstalled, deleteAllNemo } from '../asr/nemo';
import {
  deleteLLM,
  downloadLLM,
  llmInstalled,
  deleteAllLLM,
  installedLLMStorageBytes,
} from '../asr/llm';
import { clearHistory } from '../history';
import { getCloud, getSelectedModelId, setCloud, setSelectedModelId } from '../asr/settings';
import { theme } from './theme';

type Props = {
  visible: boolean;
  onClose: () => void;
  onChanged: () => void;
  onWipeData: () => void;
};

export function ModelsModal({ visible, onClose, onChanged, onWipeData }: Props) {
  const catalog = buildCatalog();
  const [selectedId, setSelectedId] = useState(getSelectedModelId());
  const [installed, setInstalled] = useState<Record<string, boolean>>({});
  const [busyId, setBusyId] = useState<string | null>(null);
  const [progress, setProgress] = useState<Record<string, number>>({});
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [showMore, setShowMore] = useState(false);
  const [showCloud, setShowCloud] = useState(false);

  const [apiKey, setApiKey] = useState('');
  const [baseUrl, setBaseUrl] = useState('');
  const [cloudModel, setCloudModel] = useState('');
  const controllers = useRef<Record<string, AbortController>>({});

  useEffect(() => {
    if (!visible) return;
    setSelectedId(getSelectedModelId());
    const c = getCloud();
    setApiKey(c.apiKey);
    setBaseUrl(c.baseUrl);
    setCloudModel(c.model);
    const map: Record<string, boolean> = {};
    for (const m of catalog) {
      if (m.kind === 'whisper' && m.whisper) map[m.id] = isInstalled(m.whisper);
      else if (m.kind === 'llm' && m.llm) map[m.id] = llmInstalled(m.llm);
      else if (m.kind === 'nemo') map[m.id] = false;
      else map[m.id] = true;
    }
    setInstalled(map);
    (async () => {
      for (const m of catalog) {
        if (m.kind === 'nemo' && m.nemo) {
          const ok = await nemoInstalled(m.nemo);
          setInstalled((s) => ({ ...s, [m.id]: ok }));
        }
      }
    })();
  }, [visible]);

  function choose(m: CatalogModel) {
    setSelectedModelId(m.id);
    setSelectedId(m.id);
    onChanged();
  }

  async function getModel(m: CatalogModel) {
    if (m.kind !== 'whisper' && m.kind !== 'nemo' && m.kind !== 'llm') return;
    setError(null);
    setBusyId(m.id);
    setProgress((p) => ({ ...p, [m.id]: 0 }));
    const ctrl = new AbortController();
    controllers.current[m.id] = ctrl;
    const onR = (r: number) => setProgress((p) => ({ ...p, [m.id]: r }));
    try {
      if (m.kind === 'whisper' && m.whisper) await downloadModel(m.whisper, onR, ctrl.signal);
      else if (m.kind === 'nemo' && m.nemo) await downloadNemo(m.nemo, onR, ctrl.signal);
      else if (m.kind === 'llm' && m.llm) await downloadLLM(m.llm, onR, ctrl.signal);
      setInstalled((s) => ({ ...s, [m.id]: true }));
      // The LLM is a post-processor, not a transcription engine — installing it
      // must not change the selected voice model.
      if (m.kind !== 'llm') choose(m);
    } catch (e: any) {
      if (e?.name !== 'AbortError' && !/abort/i.test(e?.message ?? '')) {
        setError(e?.message ?? String(e));
      }
    } finally {
      delete controllers.current[m.id];
      setBusyId(null);
    }
  }

  function cancelDownload(m: CatalogModel) {
    controllers.current[m.id]?.abort();
  }

  function removeModel(m: CatalogModel) {
    if (m.kind !== 'whisper' && m.kind !== 'nemo' && m.kind !== 'llm') return;
    Alert.alert('Remove model', `Delete this download (${m.sizeLabel})?`, [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Delete',
        style: 'destructive',
        onPress: () => {
          if (m.kind === 'whisper' && m.whisper) deleteModel(m.whisper);
          else if (m.kind === 'nemo' && m.nemo) deleteNemo(m.nemo);
          else if (m.kind === 'llm' && m.llm) deleteLLM(m.llm);
          setInstalled((s) => ({ ...s, [m.id]: false }));
          if (selectedId === m.id) choose(catalog[0]);
          setTick((t) => t + 1);
        },
      },
    ]);
  }

  function persistCloud(next: { apiKey?: string; baseUrl?: string; model?: string }) {
    setCloud(next);
    onChanged();
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
            deleteAllNemo();
            deleteAllLLM();
            clearHistory();
            setSelectedModelId('system');
            setSelectedId('system');
            onWipeData();
            setTick((t) => t + 1);
          },
        },
      ]
    );
  }

  const storage = formatMB(installedStorageBytes() + installedLLMStorageBytes());
  const featured = catalog.filter((m) => m.featured);
  const more = catalog.filter((m) => !m.featured && m.kind !== 'cloud' && m.kind !== 'llm');
  const llmModels = catalog.filter((m) => m.kind === 'llm');
  const cloud = catalog.find((m) => m.kind === 'cloud');

  function Row({ m, card }: { m: CatalogModel; card?: boolean }) {
    const isLLM = m.kind === 'llm';
    const isSel = !isLLM && selectedId === m.id;
    const isDl = busyId === m.id;
    const pct = Math.round((progress[m.id] ?? 0) * 100);
    const have = installed[m.id];
    const downloadable = m.kind === 'whisper' || m.kind === 'nemo' || isLLM;
    const name = m.title ?? m.label;
    const desc = m.tagline ?? m.note;
    const chip = m.chip ?? (m.live ? 'Real-time' : 'After recording');
    const isReco = chip === 'Recommended';
    const sizeNote = downloadable ? m.sizeLabel : '';
    return (
      <Pressable
        style={[card ? styles.card : styles.row, card && isSel && styles.cardSel]}
        onPress={isLLM ? undefined : () => choose(m)}
        key={m.id}
      >
        {isLLM ? (
          <Ionicons name="sparkles" size={20} color={theme.primary} />
        ) : (
          <Ionicons
            name={isSel ? 'radio-button-on' : 'radio-button-off'}
            size={22}
            color={isSel ? theme.primary : theme.textFaint}
          />
        )}
        <View style={styles.rowText}>
          <View style={styles.labelRow}>
            <Text style={styles.label}>{name}</Text>
            <Text style={[styles.chip, isReco ? styles.chipReco : styles.chipSubtle]}>{chip}</Text>
          </View>
          {isDl ? (
            <View style={styles.dlBarRow}>
              <View style={styles.dlTrack}>
                <View style={[styles.dlFill, { width: `${Math.max(3, pct)}%` }]} />
              </View>
              <Text style={styles.dlPctText}>{pct}%</Text>
            </View>
          ) : (
            <Text style={styles.meta}>
              {desc}
              {sizeNote ? `  ·  ${have ? 'Saved' : sizeNote}` : ''}
            </Text>
          )}
        </View>
        {isDl ? (
          <Pressable style={styles.trash} onPress={() => cancelDownload(m)} hitSlop={8}>
            <Ionicons name="close-circle" size={22} color={theme.textFaint} />
          </Pressable>
        ) : downloadable && !have ? (
          <Pressable
            style={styles.getBtn}
            onPress={() => getModel(m)}
            disabled={!!busyId}
            hitSlop={6}
          >
            <Ionicons name="arrow-down-circle" size={17} color={theme.onPrimary} />
            <Text style={styles.getText}>Get</Text>
          </Pressable>
        ) : downloadable && have ? (
          <Pressable style={styles.trash} onPress={() => removeModel(m)} hitSlop={8}>
            <Ionicons name="trash-outline" size={19} color={theme.textFaint} />
          </Pressable>
        ) : null}
      </Pressable>
    );
  }

  function Expander({
    title,
    open,
    onToggle,
    children,
  }: {
    title: string;
    open: boolean;
    onToggle: () => void;
    children: React.ReactNode;
  }) {
    return (
      <>
        <Pressable style={styles.expander} onPress={onToggle}>
          <Text style={styles.expanderText}>{title}</Text>
          <Ionicons
            name={open ? 'chevron-up' : 'chevron-down'}
            size={18}
            color={theme.textDim}
          />
        </Pressable>
        {open && <View>{children}</View>}
      </>
    );
  }

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
      <Pressable style={styles.backdrop} onPress={onClose}>
        <Pressable style={styles.sheet} onPress={() => {}}>
          <View style={styles.handle} />
          <View style={styles.header}>
            <Text style={styles.title}>Voice</Text>
            <Text style={styles.storage}>{storage} used</Text>
          </View>
          <Text style={styles.subtitle}>
            Everything runs privately on your phone. Pick what fits how you’ll use it — you can
            change this anytime.
          </Text>

          <ScrollView style={{ maxHeight: 460 }} key={tick} keyboardShouldPersistTaps="handled">
            {featured.map((m) => (
              <Row m={m} card key={m.id} />
            ))}

            {llmModels.map((m) => (
              <Row m={m} card key={m.id} />
            ))}

            <Expander
              title={showMore ? 'Fewer options' : 'More models'}
              open={showMore}
              onToggle={() => setShowMore((v) => !v)}
            >
              {more.map((m) => (
                <Row m={m} key={m.id} />
              ))}
            </Expander>

            {cloud && (
              <Expander
                title="Advanced · use your own cloud key"
                open={showCloud}
                onToggle={() => setShowCloud((v) => !v)}
              >
                <Row m={cloud} />
                <Text style={styles.byokHint}>
                  Audio is sent to your provider. Works with OpenAI, Groq, or any
                  OpenAI-compatible endpoint.
                </Text>
                <TextInput
                  style={styles.input}
                  placeholder="API key (sk-…)"
                  placeholderTextColor={theme.textFaint}
                  value={apiKey}
                  onChangeText={setApiKey}
                  onEndEditing={() => persistCloud({ apiKey })}
                  autoCapitalize="none"
                  autoCorrect={false}
                  secureTextEntry
                />
                <TextInput
                  style={styles.input}
                  placeholder="Base URL"
                  placeholderTextColor={theme.textFaint}
                  value={baseUrl}
                  onChangeText={setBaseUrl}
                  onEndEditing={() => persistCloud({ baseUrl })}
                  autoCapitalize="none"
                  autoCorrect={false}
                />
                <TextInput
                  style={styles.input}
                  placeholder="Model (e.g. whisper-1)"
                  placeholderTextColor={theme.textFaint}
                  value={cloudModel}
                  onChangeText={setCloudModel}
                  onEndEditing={() => persistCloud({ model: cloudModel })}
                  autoCapitalize="none"
                  autoCorrect={false}
                />
              </Expander>
            )}
          </ScrollView>

          {error && <Text style={styles.error}>{error}</Text>}

          <Pressable style={styles.wipe} onPress={wipeAll}>
            <Ionicons name="trash" size={18} color={theme.danger} />
            <Text style={styles.wipeText}>Delete all data</Text>
          </Pressable>
        </Pressable>
      </Pressable>
    </Modal>
  );
}

const styles = StyleSheet.create({
  backdrop: { flex: 1, backgroundColor: 'rgba(0,0,0,0.55)', justifyContent: 'flex-end' },
  sheet: {
    backgroundColor: theme.surface,
    borderTopLeftRadius: 24,
    borderTopRightRadius: 24,
    paddingHorizontal: 22,
    paddingBottom: 40,
    paddingTop: 12,
    maxHeight: '88%',
  },
  handle: {
    alignSelf: 'center',
    width: 40,
    height: 5,
    borderRadius: 999,
    backgroundColor: theme.border,
    marginBottom: 14,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'baseline',
    justifyContent: 'space-between',
    marginBottom: 4,
  },
  title: { color: theme.text, fontSize: 22, fontWeight: '800' },
  storage: { color: theme.textFaint, fontSize: 13 },
  subtitle: { color: theme.textDim, fontSize: 13, lineHeight: 19, marginBottom: 6 },
  card: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingVertical: 14,
    paddingHorizontal: 14,
    borderRadius: 16,
    borderWidth: 1,
    borderColor: theme.border,
    backgroundColor: theme.surfaceAlt,
    marginTop: 10,
  },
  cardSel: { borderColor: theme.primary },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingVertical: 13,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.border,
  },
  rowText: { flex: 1 },
  labelRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  label: { color: theme.text, fontSize: 16, fontWeight: '600' },
  chip: {
    fontSize: 10,
    fontWeight: '800',
    letterSpacing: 0.3,
    paddingHorizontal: 7,
    paddingVertical: 2,
    borderRadius: 6,
    overflow: 'hidden',
  },
  chipReco: { color: theme.onPrimary, backgroundColor: theme.primary },
  chipSubtle: { color: theme.textDim, backgroundColor: theme.surfaceAlt },
  meta: { color: theme.textFaint, fontSize: 12.5, marginTop: 4, lineHeight: 17 },
  trash: { padding: 6 },
  dlBarRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 7 },
  dlTrack: {
    flex: 1,
    height: 5,
    borderRadius: 999,
    backgroundColor: theme.surfaceAlt,
    overflow: 'hidden',
  },
  dlFill: { height: 5, borderRadius: 999, backgroundColor: theme.primary },
  dlPctText: { color: theme.textDim, fontSize: 12, fontWeight: '600', width: 38, textAlign: 'right' },
  getBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 5,
    backgroundColor: theme.primary,
    paddingHorizontal: 13,
    paddingVertical: 8,
    borderRadius: 999,
  },
  getText: { color: theme.onPrimary, fontWeight: '700', fontSize: 14 },
  expander: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 16,
    marginTop: 6,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.border,
  },
  expanderText: { color: theme.textDim, fontSize: 14, fontWeight: '700' },
  byokHint: { color: theme.textFaint, fontSize: 12, marginTop: 10, lineHeight: 17 },
  input: {
    backgroundColor: theme.surfaceAlt,
    borderRadius: 12,
    paddingHorizontal: 14,
    paddingVertical: 12,
    color: theme.text,
    fontSize: 15,
    marginTop: 8,
  },
  error: { color: theme.danger, fontSize: 13, marginTop: 12 },
  wipe: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    marginTop: 18,
    paddingVertical: 14,
    borderRadius: 14,
    backgroundColor: theme.surfaceAlt,
  },
  wipeText: { color: theme.danger, fontSize: 16, fontWeight: '700' },
});
