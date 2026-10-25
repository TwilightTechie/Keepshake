import React from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import { ExportIcon } from '@/components/icons';
import { ScreenShell } from '@/components/ScreenShell';
import { TaskRow } from '@/components/TaskRow';
import { Card, Chip, SectionLabel } from '@/components/ui';
import { useAppStore } from '@/store/appStore';
import { color, radius } from '@/theme';

const PEOPLE = ['all', 'Maya', 'Sam', 'Priya', 'Ana'] as const;

export default function TasksScreen() {
  const tasks = useAppStore((s) => s.tasks);
  const taskFilter = useAppStore((s) => s.taskFilter);
  const setTaskFilter = useAppStore((s) => s.setTaskFilter);

  const matches = tasks.filter((t) => taskFilter === 'all' || t.person === taskFilter);
  const overdue = matches.filter((t) => t.group === 'overdue');
  const today = matches.filter((t) => t.group === 'today');
  const later = matches.filter((t) => t.group === 'later');

  return (
    <ScreenShell>
      <View style={styles.header}>
        <Text style={styles.title}>Tasks</Text>
        <Text style={styles.select}>Select</Text>
      </View>
      <View style={styles.chips}>
        {PEOPLE.map((p) => (
          <Chip key={p} label={p === 'all' ? 'All' : p} active={taskFilter === p} onPress={() => setTaskFilter(p)} />
        ))}
      </View>
      <View style={styles.banner}>
        <ExportIcon />
        <Text style={styles.bannerText}>Syncing to Apple Reminders · 2 pending</Text>
        <Text style={styles.bannerLink}>Change ›</Text>
      </View>
      <ScrollView contentContainerStyle={styles.scroll}>
        {overdue.length > 0 && (
          <View style={styles.section}>
            <SectionLabel color={color.recording}>Overdue</SectionLabel>
            <Card style={styles.overdueCard}>
              {overdue.map((t, i) => (
                <TaskRow
                  key={t.id}
                  task={t}
                  last={i === overdue.length - 1}
                  metaColor={color.overdue}
                  circleColor="rgba(255,98,89,.6)"
                />
              ))}
            </Card>
          </View>
        )}
        <SectionLabel style={styles.sectionGap}>Due today</SectionLabel>
        <Card>
          {today.map((t, i) => (
            <TaskRow key={t.id} task={t} last={i === today.length - 1} showExport />
          ))}
        </Card>
        <SectionLabel style={styles.sectionGap}>Later</SectionLabel>
        <Card>
          {later.map((t, i) => (
            <TaskRow key={t.id} task={t} last={i === later.length - 1} />
          ))}
        </Card>
        <View style={styles.historyWrap}>
          <Text style={styles.history}>Completed history ›</Text>
        </View>
      </ScrollView>
    </ScreenShell>
  );
}

const styles = StyleSheet.create({
  header: {
    paddingTop: 14,
    paddingHorizontal: 20,
    flexDirection: 'row',
    alignItems: 'baseline',
    justifyContent: 'space-between',
  },
  title: { fontSize: 32, fontWeight: '700', color: color.text, letterSpacing: 0.3 },
  select: { fontSize: 13.5, fontWeight: '600', color: color.link },
  chips: { paddingTop: 10, paddingHorizontal: 16, flexDirection: 'row', gap: 7 },
  banner: {
    marginTop: 10,
    marginHorizontal: 16,
    backgroundColor: color.card,
    borderRadius: radius.banner,
    paddingVertical: 9,
    paddingHorizontal: 13,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 9,
  },
  bannerText: { flex: 1, fontSize: 12.5, color: color.text2 },
  bannerLink: { fontSize: 12.5, fontWeight: '600', color: color.link },
  scroll: { paddingTop: 14, paddingHorizontal: 16, paddingBottom: 16, gap: 8 },
  section: { gap: 8 },
  sectionGap: { paddingTop: 6 },
  overdueCard: { borderWidth: 0.5, borderColor: 'rgba(255,98,89,.35)' },
  historyWrap: { alignItems: 'center', paddingTop: 4 },
  history: { fontSize: 13, fontWeight: '600', color: color.link },
});
