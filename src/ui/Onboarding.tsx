import { ReactElement, useEffect, useRef, useState } from 'react';
import {
  Animated,
  Dimensions,
  NativeScrollEvent,
  NativeSyntheticEvent,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { requestRecordingPermissionsAsync } from 'expo-audio';
import { theme } from './theme';
import { BRAND } from './brand';
import { setOnboarded } from '../asr/settings';

const { width } = Dimensions.get('window');

type Slide = {
  title: string;
  body: string;
  render: () => ReactElement;
};

function WaveMark() {
  const bars = [26, 54, 80, 44, 30];
  const scales = useRef(bars.map(() => new Animated.Value(0.55))).current;

  useEffect(() => {
    const anims = scales.map((v, i) =>
      Animated.sequence([
        Animated.delay(i * 130),
        Animated.loop(
          Animated.sequence([
            Animated.timing(v, { toValue: 1, duration: 480, useNativeDriver: true }),
            Animated.timing(v, { toValue: 0.35, duration: 480, useNativeDriver: true }),
          ])
        ),
      ])
    );
    anims.forEach((a) => a.start());
    return () => anims.forEach((a) => a.stop());
  }, [scales]);

  return (
    <View style={styles.wave}>
      {bars.map((h, i) => (
        <Animated.View
          key={i}
          style={[styles.bar, { height: h, transform: [{ scaleY: scales[i] }] }]}
        />
      ))}
    </View>
  );
}

const SLIDES: Slide[] = [
  {
    title: BRAND,
    body: 'Speak. See it as text. Instantly. And entirely on your phone.',
    render: () => <WaveMark />,
  },
  {
    title: 'Private by design',
    body: 'Transcription runs on-device. Your voice never leaves your phone: no servers, no accounts, no cloud.',
    render: () => <Ionicons name="shield-checkmark" size={84} color={theme.text} />,
  },
  {
    title: 'Two ways to capture',
    body: 'Live for instant dictation as you talk. Offline runs a downloaded model. Works in airplane mode and translates too.',
    render: () => <Ionicons name="flash" size={84} color={theme.text} />,
  },
  {
    title: 'Type anywhere',
    body: 'Enable the Scribe keyboard in Settings to dictate into any app. We just need the mic to hear you.',
    render: () => <Ionicons name="mic" size={84} color={theme.text} />,
  },
];

export function Onboarding({ onDone }: { onDone: () => void }) {
  const [index, setIndex] = useState(0);
  const scroller = useRef<ScrollView>(null);
  const last = index === SLIDES.length - 1;

  function onScroll(e: NativeSyntheticEvent<NativeScrollEvent>) {
    const i = Math.round(e.nativeEvent.contentOffset.x / width);
    if (i !== index) setIndex(i);
  }

  async function next() {
    if (!last) {
      scroller.current?.scrollTo({ x: width * (index + 1), animated: true });
      return;
    }
    try {
      await requestRecordingPermissionsAsync();
    } catch {}
    setOnboarded(true);
    onDone();
  }

  function skip() {
    setOnboarded(true);
    onDone();
  }

  return (
    <View style={styles.root}>
      <Pressable style={styles.skip} onPress={skip} hitSlop={10}>
        <Text style={styles.skipText}>Skip</Text>
      </Pressable>

      <ScrollView
        ref={scroller}
        horizontal
        pagingEnabled
        showsHorizontalScrollIndicator={false}
        onScroll={onScroll}
        scrollEventThrottle={16}
        style={styles.pager}
      >
        {SLIDES.map((s, i) => (
          <View key={i} style={[styles.slide, { width }]}>
            <View style={styles.art}>{s.render()}</View>
            <Text style={styles.title}>{s.title}</Text>
            <Text style={styles.body}>{s.body}</Text>
          </View>
        ))}
      </ScrollView>

      <View style={styles.footer}>
        <View style={styles.dots}>
          {SLIDES.map((_, i) => (
            <View key={i} style={[styles.dot, i === index && styles.dotOn]} />
          ))}
        </View>
        <Pressable style={styles.cta} onPress={next}>
          <Text style={styles.ctaText}>{last ? 'Get started' : 'Next'}</Text>
          <Ionicons
            name={last ? 'arrow-forward' : 'chevron-forward'}
            size={20}
            color={theme.onPrimary}
          />
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: theme.bg },
  skip: { position: 'absolute', top: 64, right: 28, zIndex: 2 },
  skipText: { color: theme.textDim, fontSize: 15, fontWeight: '600' },
  pager: { flex: 1 },
  slide: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 44 },
  art: {
    width: 132,
    height: 132,
    borderRadius: 32,
    backgroundColor: theme.surface,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: 44,
  },
  wave: { flexDirection: 'row', alignItems: 'center', gap: 9, height: 88 },
  bar: { width: 9, borderRadius: 5, backgroundColor: theme.text },
  title: { color: theme.text, fontSize: 34, fontWeight: '800', letterSpacing: -0.5, marginBottom: 16, textAlign: 'center' },
  body: { color: theme.textDim, fontSize: 16, lineHeight: 24, textAlign: 'center' },
  footer: { paddingHorizontal: 28, paddingBottom: 54 },
  dots: { flexDirection: 'row', justifyContent: 'center', gap: 8, marginBottom: 26 },
  dot: { width: 7, height: 7, borderRadius: 4, backgroundColor: theme.border },
  dotOn: { backgroundColor: theme.text, width: 22 },
  cta: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    backgroundColor: theme.primary,
    paddingVertical: 17,
    borderRadius: 16,
  },
  ctaText: { color: theme.onPrimary, fontSize: 17, fontWeight: '700' },
});
