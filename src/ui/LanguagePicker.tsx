import { Modal, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { SUPPORTED_LANGUAGES } from '../asr/registry';
import { LanguageCode } from '../asr/types';
import { theme } from './theme';

type Props = {
  visible: boolean;
  current: LanguageCode;
  onSelect: (code: LanguageCode) => void;
  onClose: () => void;
};

export function LanguagePicker({ visible, current, onSelect, onClose }: Props) {
  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
      <Pressable style={styles.backdrop} onPress={onClose}>
        <Pressable style={styles.sheet} onPress={() => {}}>
          <View style={styles.handle} />
          <Text style={styles.title}>Speech language</Text>
          <ScrollView>
            {SUPPORTED_LANGUAGES.map((l) => {
              const active = current === l.code;
              return (
                <Pressable
                  key={l.code}
                  style={styles.row}
                  onPress={() => {
                    onSelect(l.code);
                    onClose();
                  }}
                >
                  <Text style={[styles.label, active && styles.labelActive]}>{l.label}</Text>
                  {active && <Ionicons name="checkmark" size={22} color={theme.primary} />}
                </Pressable>
              );
            })}
          </ScrollView>
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
    maxHeight: '70%',
  },
  handle: {
    alignSelf: 'center',
    width: 40,
    height: 5,
    borderRadius: 999,
    backgroundColor: theme.border,
    marginBottom: 14,
  },
  title: { color: theme.text, fontSize: 20, fontWeight: '700', marginBottom: 10 },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.border,
  },
  label: { color: theme.textDim, fontSize: 17 },
  labelActive: { color: theme.text, fontWeight: '700' },
});
