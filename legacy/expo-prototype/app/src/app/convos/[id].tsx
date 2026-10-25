import { useLocalSearchParams, useRouter } from 'expo-router';
import React, { useEffect } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { BackChevron, Chevron } from '@/components/icons';
import { ScreenShell } from '@/components/ScreenShell';
import { Card, Dot, SectionLabel, Separator } from '@/components/ui';
import { useAppStore } from '@/store/appStore';
import { color, entryColor } from '@/theme';

export default function ConvoDetailScreen() {
  const router = useRouter();
  const { id } = useLocalSearchParams<{ id: string }>();
  const convo = useAppStore((s) => s.convos.find((c) => c.id === id));
  const setMemSeg = useAppStore((s) => s.setMemSeg);
  const loadConvoDetail = useAppStore((s) => s.loadConvoDetail);

  useEffect(() => {
    if (id) void loadConvoDetail(id);
  }, [id, loadConvoDetail]);

  if (!convo) return null;
  const detail = convo.detail;

  const goTasks = () => router.navigate('/tasks');
  const goMemory = () => {
    setMemSeg('log');
    router.navigate('/memory');
  };

  return (
    <ScreenShell>
      <View style={styles.header}>
        <Pressable onPress={() => router.back()} style={styles.back}>
          <BackChevron />
          <Text style={styles.backText}>Conversations</Text>
        </Pressable>
        <Text style={styles.title}>{convo.title}</Text>
        <Text style={styles.subtitle}>{detail?.subtitle ?? `${convo.timeLabel} · ${convo.participants}`}</Text>
      </View>
      <ScrollView contentContainerStyle={styles.scroll}>
        {detail ? (
          <>
            {detail.summary ? (
              <View style={styles.section}>
                <SectionLabel>Summary</SectionLabel>
                <Text style={styles.summary}>{detail.summary}</Text>
              </View>
            ) : null}

            {detail.actionItems.length > 0 && (
              <View style={styles.section}>
                <SectionLabel>Action items</SectionLabel>
                <Card>
                  {detail.actionItems.map((item, i) => (
                    <View key={i}>
                      {i > 0 && <Separator />}
                      <View style={styles.actionRow}>
                        <View style={styles.openCircle} />
                        <Text style={styles.actionTitle}>{item.title}</Text>
                        <Pressable onPress={goTasks}>
                          <Text style={styles.inTasks}>in Tasks ›</Text>
                        </Pressable>
                      </View>
                    </View>
                  ))}
                </Card>
              </View>
            )}

            {detail.entries.length > 0 && (
              <View style={styles.section}>
                <SectionLabel>Memory entries from this conversation</SectionLabel>
                <Card>
                  {detail.entries.map((e, i) => (
                    <View key={i}>
                      {i > 0 && <Separator />}
                      <Pressable onPress={goMemory} style={styles.entryRow}>
                        <Dot c={entryColor[e.type]} />
                        <Text style={styles.entryHeadline}>{e.headline}</Text>
                        <Chevron />
                      </Pressable>
                    </View>
                  ))}
                </Card>
              </View>
            )}

            {detail.transcript.length > 0 && (
              <View style={styles.section}>
                <View style={styles.transcriptHeader}>
                  <SectionLabel>Transcript</SectionLabel>
                  <Text style={styles.transcriptMeta}>diarized · audio discarded</Text>
                </View>
                <View style={styles.transcript}>
                  {detail.transcript.map((turn, i) => (
                    <View key={i} style={styles.turn}>
                      <Text style={styles.turnTime}>{turn.time}</Text>
                      <Text style={[styles.turnText, turn.isYou && styles.turnYou]}>
                        <Text style={styles.turnSpeaker}>{turn.speaker}</Text>
                        {'  '}
                        {turn.text}
                      </Text>
                    </View>
                  ))}
                </View>
              </View>
            )}
          </>
        ) : (
          <Text style={styles.pending}>Summary and transcript are still processing.</Text>
        )}
      </ScrollView>
    </ScreenShell>
  );
}

const styles = StyleSheet.create({
  header: { paddingTop: 14, paddingHorizontal: 20, gap: 6 },
  back: { flexDirection: 'row', alignItems: 'center', gap: 4, alignSelf: 'flex-start' },
  backText: { fontSize: 14, color: color.link },
  title: { fontSize: 24, fontWeight: '700', color: color.text, letterSpacing: 0.2, lineHeight: 29 },
  subtitle: { fontSize: 13, color: color.text2 },
  scroll: { paddingTop: 14, paddingHorizontal: 16, paddingBottom: 16, gap: 12 },
  section: { gap: 6 },
  summary: { fontSize: 14.5, lineHeight: 21.75, color: color.text85, paddingHorizontal: 4 },
  actionRow: { paddingVertical: 11, paddingHorizontal: 14, flexDirection: 'row', alignItems: 'center', gap: 10 },
  openCircle: { width: 20, height: 20, borderRadius: 999, borderWidth: 1.5, borderColor: 'rgba(235,235,245,.3)' },
  actionTitle: { flex: 1, fontSize: 14.5, color: color.text, lineHeight: 19 },
  inTasks: { fontSize: 11.5, color: color.text3 },
  entryRow: { paddingVertical: 11, paddingHorizontal: 14, flexDirection: 'row', alignItems: 'center', gap: 10 },
  entryHeadline: { flex: 1, fontSize: 14.5, fontWeight: '500', color: color.text, lineHeight: 19 },
  transcriptHeader: {
    flexDirection: 'row',
    alignItems: 'baseline',
    justifyContent: 'space-between',
    paddingHorizontal: 4,
  },
  transcriptMeta: { fontSize: 12, color: color.text3 },
  transcript: { gap: 8, paddingHorizontal: 4 },
  turn: { flexDirection: 'row', gap: 10 },
  turnTime: { fontSize: 11.5, color: 'rgba(235,235,245,.4)', minWidth: 34, paddingTop: 2 },
  turnText: { flex: 1, fontSize: 14, lineHeight: 20.3, color: color.text75 },
  turnYou: {
    color: color.text9,
    backgroundColor: 'rgba(108,168,255,.14)',
    borderRadius: 8,
    paddingHorizontal: 8,
    paddingVertical: 4,
    overflow: 'hidden',
  },
  turnSpeaker: { fontWeight: '600', color: color.text },
  pending: { fontSize: 13.5, color: color.text3, paddingHorizontal: 4, paddingTop: 4 },
});
