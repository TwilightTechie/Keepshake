import { useRouter } from 'expo-router';
import React from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { BatteryGlyph } from '@/components/BatteryGlyph';
import { Chevron } from '@/components/icons';
import { ScreenShell } from '@/components/ScreenShell';
import { TaskRow } from '@/components/TaskRow';
import { Card, Dot, PressableCard, SectionLabel } from '@/components/ui';
import {
  selectListeningLine,
  selectMemCount,
  selectPendantLine,
  selectPendantSub,
  selectReviewCount,
  useAppStore,
} from '@/store/appStore';
import { color, hairline, radius } from '@/theme';

const MEM_BARS: { w: number; c: string }[] = [
  { w: 16, c: color.decision },
  { w: 32, c: color.commitment },
  { w: 16, c: color.fact },
  { w: 8, c: color.question },
];

export default function HomeScreen() {
  const router = useRouter();
  const listeningLine = useAppStore(selectListeningLine);
  const memCount = useAppStore(selectMemCount);
  const reviewCount = useAppStore(selectReviewCount);
  const pendantLine = useAppStore(selectPendantLine);
  const pendantSub = useAppStore(selectPendantSub);
  const tasks = useAppStore((s) => s.tasks);
  const stats = useAppStore((s) => s.stats);
  const setDeviceOpen = useAppStore((s) => s.setDeviceOpen);
  const setMemSeg = useAppStore((s) => s.setMemSeg);

  const now = new Date();
  const weekday = now.toLocaleDateString([], { weekday: 'long' });
  const monthDay = now.toLocaleDateString([], { month: 'long', day: 'numeric' });
  const todayTasks = tasks.filter((t) => t.group === 'today');
  const mem = useAppStore((s) => s.mem);
  const dataSource = useAppStore((s) => s.dataSource);
  const openQuestion = mem.find((e) => e.type === 'question' && !e.struck);

  const goMemory = (seg: 'log' | 'review') => {
    setMemSeg(seg);
    router.navigate('/memory');
  };

  return (
    <ScreenShell>
      <View style={styles.header}>
        <Text style={styles.day}>{weekday}</Text>
        <Text style={styles.sub}>
          {monthDay} · {listeningLine}
        </Text>
      </View>
      <ScrollView contentContainerStyle={styles.scroll}>
        <View style={styles.grid}>
          <PressableCard scale={0.97} style={styles.statCard} onPress={() => router.navigate('/convos')}>
            <Text style={styles.statNum}>{stats.conversations}</Text>
            <Text style={styles.statLabel}>conversations</Text>
            <View style={styles.statChevron}>
              <Chevron />
            </View>
          </PressableCard>
          <PressableCard scale={0.97} style={styles.statCard} onPress={() => router.navigate('/convos')}>
            <Text style={styles.statNum}>{stats.captured}</Text>
            <Text style={styles.statLabel}>speech captured</Text>
            <View style={styles.statChevron}>
              <Chevron />
            </View>
          </PressableCard>
          <PressableCard scale={0.97} style={[styles.statCard, { gap: 5 }]} onPress={() => goMemory('log')}>
            <Text style={styles.statNum}>{memCount}</Text>
            <Text style={styles.statLabel}>memory entries</Text>
            <View style={styles.memBars}>
              {MEM_BARS.map((b, i) => (
                <View key={i} style={{ width: b.w, height: 4, borderRadius: 2, backgroundColor: b.c }} />
              ))}
            </View>
            <View style={styles.statChevron}>
              <Chevron />
            </View>
          </PressableCard>
          {reviewCount > 0 ? (
            <Pressable
              onPress={() => goMemory('review')}
              style={({ pressed }) => [styles.reviewCard, pressed && { transform: [{ scale: 0.97 }] }]}
            >
              <Text style={[styles.statNum, { color: color.commitment }]}>{reviewCount}</Text>
              <Text style={[styles.statLabel, { color: color.text7 }]}>waiting for review</Text>
              <Text style={styles.triage}>Triage ›</Text>
            </Pressable>
          ) : (
            <PressableCard scale={0.97} style={styles.statCard} onPress={() => goMemory('review')}>
              <Text style={[styles.statNum, { color: color.fact }]}>✓</Text>
              <Text style={styles.statLabel}>review clear</Text>
            </PressableCard>
          )}
        </View>

        <View style={styles.digest}>
          <View style={styles.digestBar} />
          <Text style={styles.digestText}>{stats.digest}</Text>
        </View>

        {todayTasks.length > 0 && (
          <View style={styles.section}>
            <SectionLabel>Due today</SectionLabel>
            <Card>
              {todayTasks.map((t, i) => (
                <TaskRow key={t.id} task={t} last={i === todayTasks.length - 1} />
              ))}
            </Card>
          </View>
        )}

        {openQuestion && (
          <View style={styles.section}>
            <SectionLabel>Still open</SectionLabel>
            <Card style={styles.openRow}>
              <Dot c={color.question} />
              <Text style={styles.openText}>{openQuestion.headline}</Text>
            </Card>
          </View>
        )}

        <PressableCard style={styles.pendantCard} onPress={() => setDeviceOpen(true)}>
          <BatteryGlyph />
          <View style={styles.pendantText}>
            <Text style={styles.pendantLine}>{pendantLine}</Text>
            <Text style={styles.pendantSub}>{pendantSub}</Text>
          </View>
          <Chevron />
        </PressableCard>

        {dataSource === 'mock' && (
        <View style={styles.pastSection}>
          <View style={styles.pastHeader}>
            <View style={styles.pastRule} />
            <Text style={styles.pastLabel}>TUESDAY · JULY 21</Text>
            <View style={styles.pastRule} />
          </View>
          <View style={styles.pastCard}>
            <Text style={styles.pastNarrative}>
              A quieter Tuesday — mostly heads-down. One long planning call with Leo settled the 1.5 scope; you told Maya
              you&apos;d handle Thursday&apos;s school run.
            </Text>
            <View style={styles.pastStats}>
              <PastStat num="6" label="convos" />
              <PastStat num="3h 02m" label="captured" />
              <PastStat num="11" label="entries" />
              <PastStat num="✓" label="reviewed" numColor={color.fact} />
            </View>
            <View style={styles.pastFooter}>
              <Text style={styles.pastFrozen}>recap frozen 11:58 PM</Text>
              <Text style={styles.pastRead}>Read day ›</Text>
            </View>
          </View>
        </View>
        )}
      </ScrollView>
    </ScreenShell>
  );
}

function PastStat({ num, label, numColor }: { num: string; label: string; numColor?: string }) {
  return (
    <View style={styles.pastStat}>
      <Text style={[styles.pastStatNum, numColor ? { color: numColor } : null]}>{num}</Text>
      <Text style={styles.pastStatLabel}>{label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  header: { paddingTop: 18, paddingHorizontal: 20, paddingBottom: 2, gap: 2 },
  day: { fontSize: 32, fontWeight: '700', color: color.text, letterSpacing: 0.3 },
  sub: { fontSize: 14, color: color.text2 },
  scroll: { paddingTop: 12, paddingHorizontal: 16, paddingBottom: 16, gap: 11 },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: 10 },
  statCard: { width: '48%', flexGrow: 1, padding: 12, paddingHorizontal: 14, gap: 2 },
  statNum: { fontSize: 25, fontWeight: '700', color: color.text, letterSpacing: -0.3 },
  statLabel: { fontSize: 12, color: color.text2 },
  statChevron: { position: 'absolute', top: 14, right: 13 },
  memBars: { flexDirection: 'row', gap: 5 },
  reviewCard: {
    width: '48%',
    flexGrow: 1,
    backgroundColor: 'rgba(229,165,75,.14)',
    borderWidth: 0.5,
    borderColor: 'rgba(229,165,75,.4)',
    borderRadius: radius.card,
    padding: 12,
    paddingHorizontal: 14,
    gap: 2,
  },
  triage: { position: 'absolute', top: 13, right: 13, fontSize: 12, fontWeight: '600', color: color.commitment },
  digest: { flexDirection: 'row', gap: 9, alignItems: 'flex-start', paddingHorizontal: 4, paddingTop: 2 },
  digestBar: { width: 3, alignSelf: 'stretch', borderRadius: 2, backgroundColor: 'rgba(235,235,245,.18)' },
  digestText: { flex: 1, fontSize: 13.5, lineHeight: 19.5, color: color.text7 },
  section: { gap: 7 },
  openRow: { paddingVertical: 11, paddingHorizontal: 14, flexDirection: 'row', alignItems: 'center', gap: 10 },
  openText: { flex: 1, fontSize: 14.5, color: color.text, lineHeight: 19 },
  pendantCard: { paddingVertical: 11, paddingHorizontal: 14, flexDirection: 'row', alignItems: 'center', gap: 12 },
  pendantText: { flex: 1, gap: 1 },
  pendantLine: { fontSize: 14.5, fontWeight: '600', color: color.text },
  pendantSub: { fontSize: 12, color: color.text2 },
  pastSection: { gap: 11 },
  pastHeader: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 4 },
  pastRule: { flex: 1, height: hairline, backgroundColor: color.separator },
  pastLabel: { fontSize: 11.5, fontWeight: '600', color: color.text3, letterSpacing: 0.8 },
  pastCard: {
    backgroundColor: color.cardRecessed,
    borderWidth: 0.5,
    borderColor: 'rgba(235,235,245,.1)',
    borderRadius: radius.card,
    padding: 14,
    gap: 10,
  },
  pastNarrative: { fontSize: 14, lineHeight: 21, color: color.text75 },
  pastStats: { flexDirection: 'row', gap: 8 },
  pastStat: {
    flex: 1,
    backgroundColor: 'rgba(235,235,245,.06)',
    borderRadius: 10,
    paddingVertical: 7,
    paddingHorizontal: 4,
    alignItems: 'center',
    gap: 1,
  },
  pastStatNum: { fontSize: 16, fontWeight: '700', color: color.text85 },
  pastStatLabel: { fontSize: 10, color: color.text5 },
  pastFooter: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  pastFrozen: { flex: 1, fontSize: 12, color: color.text3 },
  pastRead: { fontSize: 12.5, fontWeight: '600', color: color.decision },
});
