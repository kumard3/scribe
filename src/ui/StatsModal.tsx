import { useEffect, useState } from 'react';
import {
  Alert,
  Modal,
  Platform,
  Pressable,
  SafeAreaView,
  ScrollView,
  StatusBar as RNStatusBar,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { clearUsage, hoursMinutes, loadUsage, usageStats, type CloudCounts, type ProviderStats } from '../util/usage';
import { listMeetings } from '../meetings';
import { theme } from './theme';
import { BRAND } from './brand';

type Props = { visible: boolean; onClose: () => void };

const n = (v: number) => Math.round(v).toLocaleString();

function cloudLines(c: CloudCounts, row: ProviderStats): string[] {
  const lines = [`${n(c.calls)} ${c.calls === 1 ? 'call' : 'calls'}${c.failures > 0 ? ` · ${n(c.failures)} failed` : ''}`];
  if (row.all.audioSeconds > 0) lines.push(`${(c.audioSeconds / 60).toFixed(1)} min audio`);
  if (row.all.inputTokens + row.all.outputTokens > 0) {
    lines.push(`${n(c.inputTokens)} in / ${n(c.outputTokens)} out tokens`);
  }
  return lines;
}

export function StatsModal({ visible, onClose }: Props) {
  const [stats, setStats] = useState(() => usageStats({ days: {} }));
  const [meetings, setMeetings] = useState({ count: 0, seconds: 0 });

  function refresh() {
    setStats(usageStats(loadUsage()));
    const all = listMeetings();
    setMeetings({ count: all.length, seconds: all.reduce((s, m) => s + (m.durationSec || 0), 0) });
  }

  useEffect(() => {
    if (visible) refresh();
  }, [visible]);

  function reset() {
    Alert.alert('Reset stats', 'This clears your word, dictation and cloud usage counts. History and meetings stay.', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Reset',
        style: 'destructive',
        onPress: () => {
          clearUsage();
          refresh();
        },
      },
    ]);
  }

  const tile = (label: string, value: string, sub?: string) => (
    <View style={[styles.card, styles.tile]}>
      <Text style={styles.tileLabel}>{label}</Text>
      <Text style={styles.tileValue} numberOfLines={1} adjustsFontSizeToFit>
        {value}
      </Text>
      {sub ? <Text style={styles.meta}>{sub}</Text> : null}
    </View>
  );

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose} presentationStyle="fullScreen">
      <SafeAreaView
        style={[
          styles.page,
          Platform.OS === 'android' && { paddingTop: (RNStatusBar.currentHeight ?? 24) + 4 },
        ]}
      >
        <View style={styles.header}>
          <Text style={styles.title}>Your stats</Text>
          <Pressable style={styles.close} onPress={onClose} hitSlop={10}>
            <Ionicons name="close" size={24} color={theme.text} />
          </Pressable>
        </View>

        <ScrollView contentContainerStyle={styles.body}>
          <View style={[styles.card, { marginTop: 8 }]}>
            <Text style={styles.tileLabel}>Words</Text>
            <View style={styles.row}>
              {(
                [
                  ['Today', stats.wordsToday],
                  ['This week', stats.wordsWeek],
                  ['All time', stats.wordsAll],
                ] as const
              ).map(([label, value]) => (
                <View key={label} style={styles.col}>
                  <Text style={styles.tileValue} numberOfLines={1} adjustsFontSizeToFit>
                    {n(value)}
                  </Text>
                  <Text style={styles.meta}>{label}</Text>
                </View>
              ))}
            </View>
          </View>

          <View style={styles.grid}>
            {tile('Dictations', n(stats.dictations))}
            {tile('Speaking speed', stats.wpm == null ? '-' : `${n(stats.wpm)} wpm`)}
          </View>
          <View style={styles.grid}>
            {tile('Day streak', `${n(stats.streak)} ${stats.streak === 1 ? 'day' : 'days'}`)}
            {tile('Time dictated', hoursMinutes(stats.speechSeconds))}
          </View>
          <View style={styles.grid}>
            {tile('Meetings', n(meetings.count), `${hoursMinutes(meetings.seconds)} recorded`)}
          </View>

          <Text style={styles.section}>Cloud usage</Text>
          {stats.cloud.length === 0 ? (
            <View style={styles.card}>
              <Text style={styles.meta}>No cloud calls yet. Everything ran on this device.</Text>
            </View>
          ) : (
            stats.cloud.map((row) => (
              <View key={row.provider} style={[styles.card, { marginBottom: 8 }]}>
                <Text style={styles.label}>{row.label}</Text>
                <View style={styles.row}>
                  {(
                    [
                      ['This month', row.month],
                      ['All time', row.all],
                    ] as const
                  ).map(([label, c]) => (
                    <View key={label} style={styles.col}>
                      <Text style={styles.tileLabel}>{label}</Text>
                      {cloudLines(c, row).map((line) => (
                        <Text key={line} style={styles.cloudLine}>
                          {line}
                        </Text>
                      ))}
                    </View>
                  ))}
                </View>
              </View>
            ))
          )}
          <Text style={[styles.meta, { marginTop: 10 }]}>
            {`${BRAND} counts requests on this device. Your Azure or OpenAI dashboard has the bill.`}
          </Text>

          <Pressable style={[styles.dangerBtn, { marginTop: 24 }]} onPress={reset}>
            <Ionicons name="refresh-outline" size={18} color={theme.danger} />
            <Text style={styles.dangerText}>Reset stats</Text>
          </Pressable>
        </ScrollView>
      </SafeAreaView>
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
  grid: { flexDirection: 'row', gap: 8, marginTop: 8 },
  tile: { flex: 1 },
  tileLabel: { color: theme.textDim, fontSize: 13, fontWeight: '600' },
  tileValue: { color: theme.text, fontSize: 24, fontWeight: '800', marginTop: 6 },
  row: { flexDirection: 'row', gap: 12, marginTop: 4 },
  col: { flex: 1 },
  label: { color: theme.text, fontSize: 16, fontWeight: '600', marginBottom: 8 },
  cloudLine: { color: theme.text, fontSize: 14, marginTop: 4 },
  meta: { color: theme.textFaint, fontSize: 13, marginTop: 4, lineHeight: 18 },
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
