import { useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { MODELS, formatMB } from '../asr/registry';
import {
  deleteAllModels,
  deleteModel,
  downloadModel,
  installedStorageBytes,
  isInstalled,
} from '../asr/modelManager';
import { ModelSpec } from '../asr/types';
import { theme } from './theme';

type Props = {
  visible: boolean;
  onClose: () => void;
  onChanged: () => void;
  onWipeData: () => void;
};

export function ModelsModal({ visible, onClose, onChanged, onWipeData }: Props) {
  const [tick, setTick] = useState(0);
  const [progress, setProgress] = useState<Record<string, number>>({});
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const refresh = () => {
    setTick((t) => t + 1);
    onChanged();
  };

  async function download(model: ModelSpec) {
    setError(null);
    setBusyId(model.id);
    setProgress((p) => ({ ...p, [model.id]: 0 }));
    try {
      await downloadModel(model, (r) => setProgress((p) => ({ ...p, [model.id]: r })));
      refresh();
    } catch (e: any) {
      setError(e?.message ?? String(e));
    } finally {
      setBusyId(null);
    }
  }

  function remove(model: ModelSpec) {
    Alert.alert('Delete model', `Remove "${model.label}" (${formatMB(model.sizeBytes)})?`, [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Delete',
        style: 'destructive',
        onPress: () => {
          deleteModel(model);
          refresh();
        },
      },
    ]);
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
            onWipeData();
            refresh();
          },
        },
      ]
    );
  }

  const storage = formatMB(installedStorageBytes());

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
      <Pressable style={styles.backdrop} onPress={onClose}>
        <Pressable style={styles.sheet} onPress={() => {}}>
          <View style={styles.handle} />
          <View style={styles.header}>
            <Text style={styles.title}>Models</Text>
            <Text style={styles.storage}>{storage} used</Text>
          </View>

          <ScrollView style={{ maxHeight: 460 }} key={tick}>
            {MODELS.map((m) => {
              const installed = isInstalled(m);
              const downloading = busyId === m.id;
              const pct = Math.round((progress[m.id] ?? 0) * 100);
              return (
                <View key={m.id} style={styles.row}>
                  <View style={{ flex: 1 }}>
                    <Text style={styles.label}>{m.label}</Text>
                    <Text style={styles.meta}>
                      {m.note} · {formatMB(m.sizeBytes)}
                    </Text>
                  </View>
                  {installed ? (
                    <Pressable style={styles.trash} onPress={() => remove(m)} hitSlop={8}>
                      <Ionicons name="trash-outline" size={20} color={theme.textFaint} />
                    </Pressable>
                  ) : downloading ? (
                    <View style={styles.dlState}>
                      <ActivityIndicator color={theme.primary} />
                      <Text style={styles.pct}>{pct}%</Text>
                    </View>
                  ) : (
                    <Pressable
                      style={styles.dlBtn}
                      onPress={() => download(m)}
                      disabled={!!busyId}
                    >
                      <Ionicons name="arrow-down-circle" size={18} color="#fff" />
                      <Text style={styles.dlText}>Get</Text>
                    </Pressable>
                  )}
                </View>
              );
            })}
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
    paddingHorizontal: 20,
    paddingBottom: 40,
    paddingTop: 12,
    maxHeight: '82%',
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
    marginBottom: 10,
  },
  title: { color: theme.text, fontSize: 22, fontWeight: '800' },
  storage: { color: theme.textFaint, fontSize: 13 },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 14,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.border,
  },
  label: { color: theme.text, fontSize: 16, fontWeight: '600' },
  meta: { color: theme.textFaint, fontSize: 12, marginTop: 4 },
  trash: { padding: 8 },
  dlState: { alignItems: 'center', width: 64 },
  pct: { color: theme.textDim, fontSize: 11, marginTop: 2 },
  dlBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 5,
    backgroundColor: theme.primary,
    paddingHorizontal: 14,
    paddingVertical: 9,
    borderRadius: 999,
  },
  dlText: { color: '#fff', fontWeight: '700', fontSize: 14 },
  error: { color: theme.danger, fontSize: 13, marginTop: 12 },
  wipe: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    marginTop: 20,
    paddingVertical: 14,
    borderRadius: 14,
    backgroundColor: theme.surfaceAlt,
  },
  wipeText: { color: theme.danger, fontSize: 16, fontWeight: '700' },
});
