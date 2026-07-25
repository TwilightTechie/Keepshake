import React from 'react';
import { Pressable, StyleSheet, Text, View, type StyleProp, type TextStyle, type ViewStyle } from 'react-native';
import { color, hairline, radius } from '../theme';

export function SectionLabel({ children, style, color: c }: { children: string; style?: StyleProp<TextStyle>; color?: string }) {
  return <Text style={[styles.sectionLabel, c ? { color: c } : null, style]}>{children}</Text>;
}

export function Card({ children, style }: { children: React.ReactNode; style?: StyleProp<ViewStyle> }) {
  return <View style={[styles.card, style]}>{children}</View>;
}

/** Card that scales down slightly while pressed, like the prototype's style-active */
export function PressableCard({
  children,
  onPress,
  style,
  scale = 0.98,
}: {
  children: React.ReactNode;
  onPress?: () => void;
  style?: StyleProp<ViewStyle>;
  scale?: number;
}) {
  return (
    <Pressable onPress={onPress} style={({ pressed }) => [styles.card, style, pressed && { transform: [{ scale }] }]}>
      {children}
    </Pressable>
  );
}

export function Dot({ c, size = 7, style }: { c: string; size?: number; style?: StyleProp<ViewStyle> }) {
  return <View style={[{ width: size, height: size, borderRadius: radius.pill, backgroundColor: c }, style]} />;
}

export function Separator() {
  return <View style={styles.separator} />;
}

export function Chip({
  label,
  active,
  onPress,
  dot,
}: {
  label: string;
  active: boolean;
  onPress: () => void;
  dot?: string;
}) {
  return (
    <Pressable onPress={onPress} style={[styles.chip, { backgroundColor: active ? '#fff' : color.card }]}>
      {dot ? <Dot c={dot} size={6} /> : null}
      <Text style={{ fontSize: 13, fontWeight: active ? '600' : '400', color: active ? '#000' : color.text7 }}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  sectionLabel: {
    fontSize: 12,
    fontWeight: '600',
    color: color.text2,
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    paddingHorizontal: 4,
  },
  card: {
    backgroundColor: color.card,
    borderRadius: radius.card,
    overflow: 'hidden',
  },
  separator: {
    height: hairline,
    backgroundColor: color.separator,
  },
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 5,
    borderRadius: radius.pill,
    paddingVertical: 6,
    paddingHorizontal: 13,
  },
});
