import type { BottomTabBarProps } from '@react-navigation/bottom-tabs';
import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { selectReviewCount, useAppStore } from '../store/appStore';
import { color, hairline, radius } from '../theme';
import { ConvosTabIcon, HomeTabIcon, MemoryTabIcon, TasksTabIcon } from './icons';

const TABS: { name: string; label: string; icon?: (c: string) => React.ReactNode }[] = [
  { name: 'index', label: 'Home', icon: (c) => <HomeTabIcon c={c} /> },
  { name: 'convos', label: 'Convos', icon: (c) => <ConvosTabIcon c={c} /> },
  { name: 'tasks', label: 'Tasks', icon: (c) => <TasksTabIcon c={c} /> },
  { name: 'memory', label: 'Memory', icon: (c) => <MemoryTabIcon c={c} /> },
  { name: 'ask', label: 'Ask' },
];

export function TabBar({ state, navigation }: BottomTabBarProps) {
  const insets = useSafeAreaInsets();
  const reviewCount = useAppStore(selectReviewCount);

  return (
    <View style={[styles.bar, { paddingBottom: Math.max(insets.bottom, 30) }]}>
      {TABS.map((tab) => {
        const routeIndex = state.routes.findIndex((r) => r.name === tab.name);
        if (routeIndex < 0) return null;
        const route = state.routes[routeIndex];
        const active = state.index === routeIndex;
        const c = active ? color.tabActive : color.tabInactive;
        return (
          <Pressable
            key={tab.name}
            style={styles.item}
            onPress={() => {
              const event = navigation.emit({ type: 'tabPress', target: route.key, canPreventDefault: true });
              if (!event.defaultPrevented) navigation.navigate(route.name, route.params);
            }}
          >
            {tab.icon ? tab.icon(c) : <Text style={[styles.askGlyph, { color: c }]}>?</Text>}
            <Text style={[styles.label, { color: c }]}>{tab.label}</Text>
            {tab.name === 'memory' && reviewCount > 0 && (
              <View style={styles.badge}>
                <Text style={styles.badgeText}>{reviewCount}</Text>
              </View>
            )}
          </Pressable>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    paddingTop: 10,
    paddingHorizontal: 8,
    borderTopWidth: hairline,
    borderTopColor: color.separator,
    backgroundColor: color.tabBarBg,
  },
  item: { flex: 1, alignItems: 'center', gap: 4 },
  askGlyph: { fontSize: 19, lineHeight: 22, fontWeight: '600' },
  label: { fontSize: 10, fontWeight: '600' },
  badge: {
    position: 'absolute',
    top: -4,
    right: 14,
    backgroundColor: color.commitment,
    borderRadius: radius.pill,
    paddingHorizontal: 5,
    paddingVertical: 1,
  },
  badgeText: { color: '#1a1a1a', fontSize: 10, fontWeight: '700' },
});
