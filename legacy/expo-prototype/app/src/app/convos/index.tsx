import { useRouter } from 'expo-router';
import React from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import { SearchIcon } from '@/components/icons';
import { ScreenShell } from '@/components/ScreenShell';
import { Dot, PressableCard, SectionLabel } from '@/components/ui';
import { useAppStore } from '@/store/appStore';
import { color, radius } from '@/theme';
import type { Conversation } from '@/types';
import { entryColor } from '@/theme';

function badgeColor(type: Conversation['badges'][number]['type']): string {
  return type === 'task' ? color.commitment : entryColor[type];
}

export default function ConvosScreen() {
  const convos = useAppStore((s) => s.convos);
  const today = convos.filter((c) => c.section === 'today');
  const yesterday = convos.filter((c) => c.section === 'yesterday');

  return (
    <ScreenShell>
      <View style={styles.header}>
        <Text style={styles.title}>Conversations</Text>
      </View>
      <View style={styles.search}>
        <SearchIcon />
        <Text style={styles.searchPlaceholder}>Search people, places, words…</Text>
      </View>
      <ScrollView contentContainerStyle={styles.scroll}>
        {today.length > 0 && <SectionLabel>Today</SectionLabel>}
        {today.map((c) => (
          <ConvoCard key={c.id} convo={c} />
        ))}
        {yesterday.length > 0 && (
          <SectionLabel style={styles.yesterdayLabel}>Yesterday</SectionLabel>
        )}
        {yesterday.map((c) => (
          <ConvoCard key={c.id} convo={c} />
        ))}
      </ScrollView>
    </ScreenShell>
  );
}

function ConvoCard({ convo }: { convo: Conversation }) {
  const router = useRouter();
  return (
    <PressableCard style={styles.card} onPress={() => router.push(`/convos/${convo.id}`)}>
      <View style={styles.cardHeader}>
        <Text style={styles.cardTitle}>{convo.title}</Text>
        <Text style={styles.cardTime}>{convo.timeLabel}</Text>
      </View>
      <Text style={styles.participants}>{convo.participants}</Text>
      <View style={styles.badges}>
        {convo.badges.map((b, i) => (
          <View key={i} style={styles.badge}>
            <Dot c={badgeColor(b.type)} size={6} />
            <Text style={styles.badgeText}>{b.label}</Text>
          </View>
        ))}
      </View>
    </PressableCard>
  );
}

const styles = StyleSheet.create({
  header: { paddingTop: 14, paddingHorizontal: 20, paddingBottom: 2 },
  title: { fontSize: 32, fontWeight: '700', color: color.text, letterSpacing: 0.3 },
  search: {
    marginTop: 10,
    marginHorizontal: 16,
    height: 36,
    borderRadius: radius.input,
    backgroundColor: color.card,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingHorizontal: 12,
  },
  searchPlaceholder: { fontSize: 15, color: 'rgba(235,235,245,.4)' },
  scroll: { paddingTop: 14, paddingHorizontal: 16, paddingBottom: 16, gap: 8 },
  yesterdayLabel: { paddingTop: 6 },
  card: { padding: 12, paddingHorizontal: 14, gap: 5 },
  cardHeader: { flexDirection: 'row', alignItems: 'baseline', gap: 8 },
  cardTitle: { flex: 1, fontSize: 15.5, fontWeight: '600', color: color.text },
  cardTime: { fontSize: 12, color: color.text3 },
  participants: { fontSize: 13, color: color.text2 },
  badges: { flexDirection: 'row', gap: 10, alignItems: 'center' },
  badge: { flexDirection: 'row', alignItems: 'center', gap: 5 },
  badgeText: { fontSize: 12, color: color.text55 },
});
