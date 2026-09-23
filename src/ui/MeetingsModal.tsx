import { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Modal,
  Pressable,
  ScrollView,
  Share,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { createAudioPlayer, type AudioPlayer } from 'expo-audio';
import { theme } from './theme';
import {
  audioFile,
  deleteMeeting,
  durationLabel,
  getMeeting,
  listMeetings,
  meetingText,
  renameSpeaker,
  speakerLabel,
  updateMeeting,
  type Meeting,
} from '../meetings';
import { LLM_MODELS, llmInstalled, summarizeWithLLM } from '../asr/llm';
import { summarize } from '../util/summarize';

type Props = { visible: boolean; onClose: () => void };
type Tab = 'summary' | 'transcript' | 'speakers';

function dayLabel(ts: number): string {
  return new Date(ts).toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' });
}

export function MeetingsModal({ visible, onClose }: Props) {
  const [items, setItems] = useState<Meeting[]>([]);
  const [open, setOpen] = useState<Meeting | null>(null);
  const [tab, setTab] = useState<Tab>('transcript');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [player, setPlayer] = useState<AudioPlayer | null>(null);
  const [playing, setPlaying] = useState(false);

  useEffect(() => {
    if (visible) setItems(listMeetings());
  }, [visible]);

  const stopAudio = useCallback(() => {
    setPlayer((p) => {
      p?.remove();
      return null;
    });
    setPlaying(false);
  }, []);

  useEffect(() => stopAudio, [stopAudio]);

  const close = useCallback(() => {
    stopAudio();
    setOpen(null);
    onClose();
  }, [onClose, stopAudio]);

  const onPlay = useCallback(() => {
    if (!open?.hasAudio) return;
    if (playing) {
      player?.pause();
      setPlaying(false);
      return;
    }
    try {
      const p = player ?? createAudioPlayer(audioFile(open.id).uri);
      p.play();
      setPlayer(p);
      setPlaying(true);
    } catch (e: any) {
      setError(e?.message ?? String(e));
    }
  }, [open, player, playing]);

  const onSummarize = useCallback(async () => {
    if (!open || busy) return;
    setBusy(true);
    setError(null);
    try {
      const body = meetingText(open);
      const spec = LLM_MODELS[0];
      const text =
        spec && llmInstalled(spec) ? await summarizeWithLLM(spec, body) : summarize(body);
      const next = updateMeeting(open.id, { summary: text });
      if (next) {
        setOpen(next);
        setItems(listMeetings());
        setTab('summary');
      }
    } catch (e: any) {
      setError(e?.message ?? String(e));
    } finally {
      setBusy(false);
    }
  }, [open, busy]);

  const onRename = useCallback(
    (speaker: number, name: string) => {
      if (!open) return;
      const next = renameSpeaker(open.id, speaker, name);
      if (next) setOpen(next);
    },
    [open]
  );

  const onDelete = useCallback(
    (id: string) => {
      deleteMeeting(id);
      setItems(listMeetings());
      if (open?.id === id) {
        stopAudio();
        setOpen(null);
      }
    },
    [open, stopAudio]
  );

  const speakers = open?.turns?.length
    ? [...new Set(open.turns.map((t) => t.speaker))].sort((a, b) => a - b)
    : [];

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={close}>
      <Pressable style={styles.backdrop} onPress={close}>
        <Pressable style={styles.sheet} onPress={() => {}}>
          <View style={styles.handle} />

          {!open ? (
            <>
              <Text style={styles.title}>Meetings</Text>
              {items.length === 0 ? (
                <Text style={styles.empty}>
                  No meetings yet. Record one in Record Mode and it is saved here with its audio,
                  speakers and transcript, all on this device.
                </Text>
              ) : (
                <ScrollView style={{ maxHeight: 460 }}>
                  {items.map((m) => (
                    <Pressable
                      key={m.id}
                      style={styles.row}
                      onPress={() => {
                        setOpen(getMeeting(m.id) ?? m);
                        setTab(m.summary ? 'summary' : 'transcript');
                      }}
                    >
                      <View style={{ flex: 1 }}>
                        <Text style={styles.rowTitle} numberOfLines={1}>
                          {m.title}
                        </Text>
                        <Text style={styles.meta}>
                          {dayLabel(m.createdAt)} · {durationLabel(m.durationSec)}
                          {m.turns?.length
                            ? ` · ${new Set(m.turns.map((t) => t.speaker)).size} speakers`
                            : ''}
                        </Text>
                      </View>
                      <Pressable onPress={() => onDelete(m.id)} hitSlop={10} style={styles.action}>
                        <Ionicons name="trash-outline" size={19} color={theme.textFaint} />
                      </Pressable>
                    </Pressable>
                  ))}
                </ScrollView>
              )}
            </>
          ) : (
            <>
              <View style={styles.header}>
                <Pressable onPress={() => setOpen(null)} hitSlop={10}>
                  <Ionicons name="chevron-back" size={22} color={theme.text} />
                </Pressable>
                <Text style={styles.title} numberOfLines={1}>
                  {open.title}
                </Text>
                <Pressable
                  onPress={() => Share.share({ message: meetingText(open) })}
                  hitSlop={10}
                >
                  <Ionicons name="share-outline" size={20} color={theme.textDim} />
                </Pressable>
              </View>

              <View style={styles.tabs}>
                {(['summary', 'transcript', 'speakers'] as Tab[]).map((t) => (
                  <Pressable
                    key={t}
                    onPress={() => setTab(t)}
                    style={[styles.tab, tab === t && styles.tabOn]}
                  >
                    <Text style={[styles.tabText, tab === t && styles.tabTextOn]}>
                      {t[0].toUpperCase() + t.slice(1)}
                    </Text>
                  </Pressable>
                ))}
              </View>

              {open.hasAudio && (
                <Pressable style={styles.play} onPress={onPlay}>
                  <Ionicons name={playing ? 'pause' : 'play'} size={16} color={theme.text} />
                  <Text style={styles.playText}>
                    {playing ? 'Pause' : 'Play'} · {durationLabel(open.durationSec)}
                  </Text>
                </Pressable>
              )}

              {error && <Text style={styles.error}>{error}</Text>}

              <ScrollView style={{ maxHeight: 360 }}>
                {tab === 'summary' &&
                  (open.summary ? (
                    <Text style={styles.body}>{open.summary}</Text>
                  ) : (
                    <Pressable style={styles.cta} onPress={onSummarize} disabled={busy}>
                      {busy ? (
                        <ActivityIndicator color={theme.text} />
                      ) : (
                        <Text style={styles.ctaText}>Summarize on device</Text>
                      )}
                    </Pressable>
                  ))}

                {tab === 'transcript' && <Text style={styles.body}>{meetingText(open)}</Text>}

                {tab === 'speakers' &&
                  (speakers.length ? (
                    speakers.map((s) => (
                      <View key={s} style={styles.speakerRow}>
                        <Text style={styles.speakerNum}>{s + 1}</Text>
                        <TextInput
                          style={styles.speakerInput}
                          defaultValue={open.speakerNames?.[s] ?? ''}
                          placeholder={speakerLabel(open, s)}
                          placeholderTextColor={theme.textFaint}
                          onEndEditing={(e) => onRename(s, e.nativeEvent.text)}
                          returnKeyType="done"
                        />
                      </View>
                    ))
                  ) : (
                    <Text style={styles.empty}>
                      This meeting was transcribed without speaker separation. Turn on Speakers
                      before recording to label who said what.
                    </Text>
                  ))}
              </ScrollView>
            </>
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
    paddingHorizontal: 24,
    paddingBottom: 40,
    paddingTop: 12,
    maxHeight: '86%',
  },
  handle: {
    alignSelf: 'center',
    width: 40,
    height: 5,
    borderRadius: 999,
    backgroundColor: theme.border,
    marginBottom: 14,
  },
  header: { flexDirection: 'row', alignItems: 'center', gap: 12, marginBottom: 12 },
  title: { color: theme.text, fontSize: 22, fontWeight: '800', flex: 1 },
  empty: { color: theme.textFaint, fontSize: 15, paddingVertical: 30, lineHeight: 22 },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 14,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.border,
  },
  rowTitle: { color: theme.text, fontSize: 16, fontWeight: '600' },
  meta: { color: theme.textFaint, fontSize: 12, marginTop: 6 },
  action: { padding: 6, marginLeft: 6 },
  tabs: { flexDirection: 'row', gap: 8, marginBottom: 12 },
  tab: {
    paddingVertical: 7,
    paddingHorizontal: 14,
    borderRadius: 999,
    backgroundColor: theme.surfaceAlt,
  },
  tabOn: { backgroundColor: theme.text },
  tabText: { color: theme.textDim, fontSize: 13, fontWeight: '600' },
  tabTextOn: { color: theme.surface },
  play: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    alignSelf: 'flex-start',
    paddingVertical: 8,
    paddingHorizontal: 14,
    borderRadius: 999,
    backgroundColor: theme.surfaceAlt,
    marginBottom: 12,
  },
  playText: { color: theme.text, fontSize: 13, fontWeight: '600' },
  body: { color: theme.text, fontSize: 16, lineHeight: 24, paddingBottom: 20 },
  error: { color: theme.danger, fontSize: 13, marginBottom: 8 },
  cta: {
    marginTop: 12,
    paddingVertical: 14,
    borderRadius: 14,
    alignItems: 'center',
    backgroundColor: theme.surfaceAlt,
  },
  ctaText: { color: theme.text, fontSize: 15, fontWeight: '600' },
  speakerRow: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 12 },
  speakerNum: {
    color: theme.textDim,
    fontSize: 13,
    width: 26,
    height: 26,
    borderRadius: 13,
    textAlign: 'center',
    lineHeight: 26,
    backgroundColor: theme.surfaceAlt,
  },
  speakerInput: {
    flex: 1,
    color: theme.text,
    fontSize: 16,
    paddingVertical: 6,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.border,
  },
});
