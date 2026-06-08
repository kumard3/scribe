import { Modal, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { HistoryItem } from '../history';
import { SUPPORTED_LANGUAGES } from '../asr/registry';
import { theme } from './theme';

type Props = {
  visible: boolean;
  items: HistoryItem[];
  onClose: () => void;
  onSelect: (item: HistoryItem) => void;
  onDelete: (id: string) => void;
  onClear: () => void;
};

function langLabel(code: string): string {
  return SUPPORTED_LANGUAGES.find((l) => l.code === code)?.label ?? code;
}

function timeAgo(ts: number): string {
  const s = Math.floor((Date.now() - ts) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

export function HistoryModal({ visible, items, onClose, onSelect, onDelete, onClear }: Props) {
  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
      <Pressable style={styles.backdrop} onPress={onClose}>
        <Pressable style={styles.sheet} onPress={() => {}}>
          <View style={styles.handle} />
          <View style={styles.header}>
            <Text style={styles.title}>History</Text>
            {items.length > 0 && (
              <Pressable onPress={onClear} hitSlop={8}>
                <Text style={styles.clear}>Clear all</Text>
              </Pressable>
            )}
          </View>

          {items.length === 0 ? (
            <Text style={styles.empty}>No transcriptions yet.</Text>
          ) : (
            <ScrollView style={{ maxHeight: 460 }}>
              {items.map((item) => (
                <Pressable key={item.id} style={styles.row} onPress={() => onSelect(item)}>
                  <View style={{ flex: 1 }}>
                    <Text style={styles.text} numberOfLines={3}>
                      {item.text}
                    </Text>
                    <Text style={styles.meta}>
                      {langLabel(item.language)}
                      {item.translated ? ' → English' : ''} · {timeAgo(item.createdAt)}
                    </Text>
                  </View>
                  <Pressable onPress={() => onDelete(item.id)} hitSlop={10} style={styles.trash}>
                    <Ionicons name="trash-outline" size={20} color={theme.textFaint} />
                  </Pressable>
                </Pressable>
              ))}
            </ScrollView>
          )}
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
    maxHeight: '78%',
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
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 8,
  },
  title: { color: theme.text, fontSize: 22, fontWeight: '800' },
  clear: { color: theme.danger, fontSize: 15, fontWeight: '600' },
  empty: { color: theme.textFaint, fontSize: 15, paddingVertical: 30, textAlign: 'center' },
  row: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    paddingVertical: 14,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.border,
  },
  text: { color: theme.text, fontSize: 16, lineHeight: 22 },
  meta: { color: theme.textFaint, fontSize: 12, marginTop: 6 },
  trash: { padding: 6, marginLeft: 8 },
});
