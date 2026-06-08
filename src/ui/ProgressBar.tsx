import { useEffect, useRef } from 'react';
import { Animated, StyleSheet, View } from 'react-native';
import { theme } from './theme';

export function ProgressBar({ ratio }: { ratio: number }) {
  const w = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    Animated.timing(w, {
      toValue: Math.max(0, Math.min(1, ratio)),
      duration: 200,
      useNativeDriver: false,
    }).start();
  }, [ratio, w]);

  return (
    <View style={styles.track}>
      <Animated.View
        style={[
          styles.fill,
          { width: w.interpolate({ inputRange: [0, 1], outputRange: ['0%', '100%'] }) },
        ]}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  track: {
    height: 6,
    borderRadius: 999,
    backgroundColor: theme.border,
    overflow: 'hidden',
    marginTop: 10,
  },
  fill: { height: 6, borderRadius: 999, backgroundColor: theme.primary },
});
