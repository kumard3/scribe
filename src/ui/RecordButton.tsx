import { useEffect, useRef } from 'react';
import { ActivityIndicator, Animated, Pressable, StyleSheet, View } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { theme } from './theme';

type Props = {
  recording: boolean;
  busy: boolean;
  onPress: () => void;
};

export function RecordButton({ recording, busy, onPress }: Props) {
  const scale = useRef(new Animated.Value(1)).current;
  const ring = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    if (recording) {
      const loop = Animated.loop(
        Animated.sequence([
          Animated.timing(ring, { toValue: 1, duration: 1200, useNativeDriver: true }),
          Animated.timing(ring, { toValue: 0, duration: 0, useNativeDriver: true }),
        ])
      );
      loop.start();
      return () => loop.stop();
    }
    ring.setValue(0);
  }, [recording, ring]);

  const pressIn = () =>
    Animated.spring(scale, { toValue: 0.9, useNativeDriver: true, friction: 7 }).start();
  const pressOut = () =>
    Animated.spring(scale, { toValue: 1, useNativeDriver: true, friction: 7 }).start();

  return (
    <View style={styles.wrap}>
      {recording && (
        <Animated.View
          pointerEvents="none"
          style={[
            styles.ring,
            {
              opacity: ring.interpolate({ inputRange: [0, 1], outputRange: [0.5, 0] }),
              transform: [
                { scale: ring.interpolate({ inputRange: [0, 1], outputRange: [1, 1.8] }) },
              ],
            },
          ]}
        />
      )}
      <Animated.View style={{ transform: [{ scale }] }}>
        <Pressable
          onPress={onPress}
          onPressIn={pressIn}
          onPressOut={pressOut}
          disabled={busy}
          style={[styles.fab, { backgroundColor: recording ? theme.danger : theme.primary }]}
        >
          {busy ? (
            <ActivityIndicator color="#fff" />
          ) : recording ? (
            <View style={styles.stopSquare} />
          ) : (
            <Ionicons name="mic" size={40} color="#fff" />
          )}
        </Pressable>
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { alignItems: 'center', justifyContent: 'center', height: 110 },
  ring: {
    position: 'absolute',
    width: 88,
    height: 88,
    borderRadius: 44,
    borderWidth: 2,
    borderColor: theme.danger,
  },
  fab: {
    width: 88,
    height: 88,
    borderRadius: 44,
    alignItems: 'center',
    justifyContent: 'center',
  },
  stopSquare: { width: 30, height: 30, borderRadius: 8, backgroundColor: '#fff' },
});
