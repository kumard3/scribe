import { useEffect, useRef } from 'react';
import { Animated, StyleSheet, View } from 'react-native';
import { theme } from './theme';

export const BAR_COUNT = 32;

type Props = { levels: number[]; active: boolean };

export function Waveform({ levels, active }: Props) {
  const anims = useRef(levels.map((l) => new Animated.Value(l))).current;
  const breathe = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    Animated.parallel(
      levels.map((l, i) =>
        Animated.timing(anims[i], {
          toValue: l,
          duration: 90,
          useNativeDriver: false,
        })
      )
    ).start();
  }, [levels, anims]);

  useEffect(() => {
    if (active) {
      breathe.setValue(1);
      return;
    }
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(breathe, { toValue: 1, duration: 1100, useNativeDriver: true }),
        Animated.timing(breathe, { toValue: 0.45, duration: 1100, useNativeDriver: true }),
      ])
    );
    loop.start();
    return () => loop.stop();
  }, [active, breathe]);

  return (
    <Animated.View style={[styles.row, { opacity: breathe }]}>
      {anims.map((v, i) => (
        <Animated.View
          key={i}
          style={[
            styles.bar,
            {
              backgroundColor: active ? theme.primary : theme.primaryDim,
              height: v.interpolate({
                inputRange: [0, 1],
                outputRange: [4, 64],
              }),
            },
          ]}
        />
      ))}
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  row: {
    height: 72,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 4,
  },
  bar: {
    flex: 1,
    marginHorizontal: 1.5,
    borderRadius: 999,
  },
});
