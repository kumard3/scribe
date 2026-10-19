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
  llmModelById,
  deleteAllLLM,
  installedLLMStorageBytes,
} from '../asr/llm';
import { cloudChatLabel, cloudChatReady } from '../asr/cloud';
import { clearHistory } from '../history';
import { clearUsage } from '../util/usage';
import {
  getCloud,
  getLLMModelId,
  getSelectedModelId,
  setCloud,
  setLLMModelId,
  setSelectedModelId,
  type CloudProvider,
  type CloudSettings,
} from '../asr/settings';
import { theme } from './theme';

const CLOUD_AI = 'cloud';

const PROVIDERS: { id: CloudProvider; label: string }[] = [
  { id: 'azure-speech', label: 'Azure Speech' },
  { id: 'azure-openai', label: 'Azure OpenAI' },
  { id: 'openai', label: 'OpenAI' },
];

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
  const [aiId, setAiId] = useState(getLLMModelId());
  const [cfg, setCfg] = useState<CloudSettings>(getCloud);
  const controllers = useRef<Record<string, AbortController>>({});

  useEffect(() => {
    if (!visible) return;
    setSelectedId(getSelectedModelId());
    setAiId(getLLMModelId());
    setCfg(getCloud());
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

  function chooseAI(id: string) {
    setLLMModelId(id);
    setAiId(id);
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
      // The LLM is a post-processor, not a transcription engine, installing it
      // must not change the selected voice model.
      if (m.kind !== 'llm') choose(m);
      else if (m.llm) {
        const current = llmModelById(getLLMModelId());
        if (!current || !llmInstalled(current)) chooseAI(m.llm.id);
      }
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

  function saveCloud(patch: Partial<CloudSettings>) {
    const next = { ...cfg, ...patch };
    setCfg(next);
    if (!setCloud(next)) setError('Could not save the key to the secure store on this phone.');
    onChanged();
  }

  function field(k: keyof CloudSettings, placeholder: string, secret = false) {
    return (
      <TextInput
        key={k}
        style={styles.input}
        placeholder={placeholder}
        placeholderTextColor={theme.textFaint}
        value={cfg[k]}
        onChangeText={(v) => setCfg((c) => ({ ...c, [k]: v }))}
        onEndEditing={() => saveCloud({})}
        autoCapitalize="none"
        autoCorrect={false}
        secureTextEntry={secret}
      />
    );
  }

  function wipeAll() {
    Alert.alert(
      'Delete all data',
      'This removes every downloaded model, your entire transcription history and your stats. This cannot be undone.',
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
            clearUsage();
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
  const chatReady = cloudChatReady(cfg);
  const aiLocal = llmModelById(aiId);
  const aiActive = aiLocal && installed[`llm:${aiLocal.id}`] ? aiLocal.label : chatReady ? cloudChatLabel(cfg) : '';

  function Row({ m, card }: { m: CatalogModel; card?: boolean }) {
    const isLLM = m.kind === 'llm';
    const isSel = isLLM ? aiId === m.llm?.id : selectedId === m.id;
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
        onPress={() => (isLLM && m.llm ? chooseAI(m.llm.id) : choose(m))}
        key={m.id}
      >
        <Ionicons
          name={isSel ? 'radio-button-on' : 'radio-button-off'}
          size={22}
          color={isSel ? theme.primary : theme.textFaint}
        />
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
            <Text style={styles.title}>Models</Text>
            <Text style={styles.storage}>{storage} used</Text>
          </View>

          <ScrollView style={styles.scroll} key={tick} keyboardShouldPersistTaps="handled">
            <Text style={styles.section}>On-device AI</Text>
            <Text style={styles.subtitle}>
              Cleans up, summarizes and applies spoken corrections like “no wait” or “delete
              everything I said”. Text only, runs offline.{' '}
              {aiActive ? `Using ${aiActive}.` : 'Get one below to turn it on.'}
            </Text>
            {llmModels.map((m) => (
              <Row m={m} card key={m.id} />
            ))}
            <Pressable
              style={[styles.card, aiId === CLOUD_AI && styles.cardSel, !chatReady && styles.dim]}
              onPress={() => chatReady && chooseAI(CLOUD_AI)}
            >
              <Ionicons
                name={aiId === CLOUD_AI ? 'radio-button-on' : 'radio-button-off'}
                size={22}
                color={aiId === CLOUD_AI ? theme.primary : theme.textFaint}
              />
              <View style={styles.rowText}>
                <View style={styles.labelRow}>
                  <Text style={styles.label}>Your cloud AI</Text>
                  <Text style={[styles.chip, styles.chipSubtle]}>Text leaves your phone</Text>
                </View>
                <Text style={styles.meta}>
                  {chatReady
                    ? cloudChatLabel(cfg)
                    : 'Add a chat model or Azure OpenAI chat deployment under Cloud accounts.'}
                </Text>
              </View>
            </Pressable>

            <Text style={styles.section}>Voice</Text>
            <Text style={styles.subtitle}>
              Turns your speech into text. Everything runs privately on your phone unless you pick
              your cloud account.
            </Text>
            {featured.map((m) => (
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
              <>
                <Text style={styles.section}>Cloud accounts (your own keys)</Text>
                <Text style={styles.subtitle}>
                  Keys stay in this phone’s secure storage. Audio leaves your phone and goes to
                  your provider when you transcribe with your cloud account.
                </Text>
                <Row m={cloud} card />
                <View style={styles.segment}>
                  {PROVIDERS.map((p) => (
                    <Pressable
                      key={p.id}
                      style={[styles.segBtn, cfg.provider === p.id && styles.segBtnOn]}
                      onPress={() => saveCloud({ provider: p.id })}
                    >
                      <Text style={[styles.segText, cfg.provider === p.id && styles.segTextOn]}>
                        {p.label}
                      </Text>
                    </Pressable>
                  ))}
                </View>
                {cfg.provider === 'azure-speech' && (
                  <>
                    <Text style={styles.byokHint}>
                      MAI-Transcribe-2, best for Hinglish. From your Azure Speech resource, Keys
                      and Endpoint.
                    </Text>
                    {field('azureSpeechKey', 'Speech key', true)}
                    {field('azureSpeechEndpoint', 'Endpoint, https://<name>.cognitiveservices.azure.com')}
                    {field('azureSpeechRegion', 'Region if no endpoint, e.g. eastus')}
                  </>
                )}
                {cfg.provider === 'azure-openai' && (
                  <>
                    <Text style={styles.byokHint}>
                      From your Azure OpenAI resource. Use deployment names, not model names.
                    </Text>
                    {field('azureOpenAIKey', 'API key', true)}
                    {field('azureOpenAIEndpoint', 'Endpoint, https://<name>.openai.azure.com')}
                    {field('azureOpenAITranscribe', 'Transcription deployment, e.g. gpt-4o-transcribe')}
                    {field('azureOpenAIChat', 'Chat deployment for AI (optional)')}
                    {field('azureOpenAIApiVersion', 'API version')}
                  </>
                )}
                {cfg.provider === 'openai' && (
                  <>
                    <Text style={styles.byokHint}>
                      OpenAI, Groq, or any OpenAI-compatible endpoint.
                    </Text>
                    {field('apiKey', 'API key (sk-…)', true)}
                    {field('baseUrl', 'Base URL')}
                    {field('model', 'Transcription model (e.g. whisper-1)')}
                    {field('chatModel', 'Chat model for AI (optional, e.g. gpt-4o-mini)')}
                  </>
                )}
              </>
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
  scroll: { flexShrink: 1 },
  section: {
    color: theme.textDim,
    fontSize: 12,
    fontWeight: '700',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginTop: 22,
    marginBottom: 6,
  },
  dim: { opacity: 0.55 },
  segment: {
    flexDirection: 'row',
    backgroundColor: theme.surfaceAlt,
    borderRadius: 12,
    padding: 4,
    gap: 4,
    marginTop: 12,
  },
  segBtn: { flex: 1, alignItems: 'center', paddingVertical: 9, borderRadius: 9 },
  segBtnOn: { backgroundColor: theme.primary },
  segText: { color: theme.textDim, fontSize: 13, fontWeight: '700' },
  segTextOn: { color: theme.onPrimary },
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
