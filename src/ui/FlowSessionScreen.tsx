import { useEffect, useState } from 'react';
import { AppState, Linking, Modal, NativeModules, Platform, Pressable, StyleSheet, Text, View } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { theme } from './theme';
import { BRAND } from './brand';

type Status = { phase: 'off' | 'idle' | 'listening' | 'transcribing'; error: string | null };
type Native = { end(): void; status(): Promise<Status> };

const native = Platform.OS === 'ios' ? (NativeModules.BolkitFlow as Native | undefined) : undefined;

/** Shown when the keyboard opens Bolkit (scribe://flow) to start a background Flow session. */
export function FlowSessionScreen() {
  const [open, setOpen] = useState(false);
  const [status, setStatus] = useState<Status>({ phase: 'off', error: null });

  useEffect(() => {
    if (!native) return;
    const onUrl = (url: string | null) => {
      if (url?.startsWith('scribe://flow')) setOpen(true);
    };
    Linking.getInitialURL().then(onUrl);
    const link = Linking.addEventListener('url', (e) => onUrl(e.url));
    const app = AppState.addEventListener('change', (s) => {
      if (s === 'background') setOpen(false);
    });
    return () => {
      link.remove();
      app.remove();
    };
  }, []);

  useEffect(() => {
    if (!open || !native) return;
    const tick = () => native.status().then(setStatus).catch(() => {});
    tick();
    const t = setInterval(tick, 500);
    return () => clearInterval(t);
  }, [open]);

  const live = status.phase === 'listening';
  const title =
    status.error ?? (live ? 'Listening' : status.phase === 'transcribing' ? 'Transcribing' : `${BRAND} is ready`);

  return (
    <Modal visible={open} animationType="fade" onRequestClose={() => setOpen(false)}>
      <View style={styles.wrap}>
        <View style={[styles.mic, live && styles.micLive]}>
          <Ionicons name="mic" size={34} color={live ? theme.onPrimary : theme.text} />
        </View>
        <Text style={styles.title}>{title}</Text>
        <Text style={styles.body}>
          {`Swipe right along the bottom edge to go back to your app and keep talking. Tap the check on the ${BRAND} keyboard when you are done.`}
        </Text>
        <Pressable
          style={styles.end}
          onPress={() => {
            native?.end();
            setOpen(false);
          }}
        >
          <Text style={styles.endText}>End session</Text>
        </Pressable>
        <Pressable onPress={() => setOpen(false)} hitSlop={12}>
          <Text style={styles.hide}>Hide</Text>
        </Pressable>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  wrap: {
    flex: 1,
    backgroundColor: theme.bg,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 32,
    gap: 18,
  },
  mic: {
    width: 88,
    height: 88,
    borderRadius: 44,
    backgroundColor: theme.surfaceAlt,
    alignItems: 'center',
    justifyContent: 'center',
  },
  micLive: { backgroundColor: theme.primary },
  title: { color: theme.text, fontSize: 24, fontWeight: '700', textAlign: 'center' },
  body: { color: theme.textDim, fontSize: 15, lineHeight: 22, textAlign: 'center' },
  end: {
    marginTop: 12,
    backgroundColor: theme.surface,
    borderColor: theme.border,
    borderWidth: 1,
    borderRadius: 999,
    paddingHorizontal: 24,
    paddingVertical: 12,
  },
  endText: { color: theme.text, fontSize: 15, fontWeight: '600' },
  hide: { color: theme.textFaint, fontSize: 14 },
});
