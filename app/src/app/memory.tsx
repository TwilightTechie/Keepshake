import React from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { AcceptIcon, AllClearIcon, PencilIcon, XIcon } from '@/components/icons';
import { ScreenShell } from '@/components/ScreenShell';
import { Card, Chip, Dot, Separator } from '@/components/ui';
import { selectReviewCount, useAppStore, type MemFilter } from '@/store/appStore';
import { color, entryColor, radius } from '@/theme';

const MEM_CHIPS: { key: MemFilter; label: string; dot?: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'decision', label: 'Decisions', dot: color.decision },
  { key: 'commitment', label: 'Commitments', dot: color.commitment },
  { key: 'fact', label: 'Facts', dot: color.fact },
];

export default function MemoryScreen() {
  const memSeg = useAppStore((s) => s.memSeg);
  const setMemSeg = useAppStore((s) => s.setMemSeg);
  const reviewCount = useAppStore(selectReviewCount);

  return (
    <ScreenShell>
      <View style={styles.header}>
        <Text style={styles.title}>Memory</Text>
      </View>
      <View style={styles.segment}>
        <Pressable onPress={() => setMemSeg('log')} style={[styles.segBtn, memSeg === 'log' && styles.segActive]}>
          <Text style={[styles.segText, memSeg === 'log' && styles.segTextActive]}>Log</Text>
        </Pressable>
        <Pressable onPress={() => setMemSeg('review')} style={[styles.segBtn, memSeg === 'review' && styles.segActive]}>
          <Text style={[styles.segText, memSeg === 'review' && styles.segTextActive]}>Review</Text>
          {reviewCount > 0 && (
            <View style={styles.segBadge}>
              <Text style={styles.segBadgeText}>{reviewCount}</Text>
            </View>
          )}
        </Pressable>
      </View>
      {memSeg === 'log' ? <MemoryLog /> : <ReviewQueue />}
    </ScreenShell>
  );
}

function MemoryLog() {
  const mem = useAppStore((s) => s.mem);
  const memFilter = useAppStore((s) => s.memFilter);
  const setMemFilter = useAppStore((s) => s.setMemFilter);
  const filtered = mem.filter((e) => memFilter === 'all' || e.type === memFilter);

  return (
    <View style={styles.fill}>
      <View style={styles.chips}>
        {MEM_CHIPS.map((c) => (
          <Chip key={c.key} label={c.label} dot={c.dot} active={memFilter === c.key} onPress={() => setMemFilter(c.key)} />
        ))}
      </View>
      <View style={styles.subFilters}>
        <Text style={styles.subFilter}>Person: anyone ▾</Text>
        <Text style={styles.subFilter}>Date: all time ▾</Text>
      </View>
      <ScrollView contentContainerStyle={styles.scroll}>
        <Card>
          {filtered.map((e, i) => (
            <View key={e.id}>
              {i > 0 && <Separator />}
              <View style={[styles.memRow, e.struck && styles.memRowStruck]}>
                <Dot c={entryColor[e.type]} style={styles.memDot} />
                <View style={styles.memText}>
                  <Text
                    style={[
                      styles.memHeadline,
                      { color: e.struck ? color.text3 : color.text },
                      e.struck && { textDecorationLine: 'line-through' },
                    ]}
                  >
                    {e.headline}
                  </Text>
                  <Text style={styles.memMeta}>{e.meta}</Text>
                </View>
              </View>
            </View>
          ))}
        </Card>
        <Text style={styles.appendOnly}>Append-only · entries are never edited, only superseded</Text>
      </ScrollView>
    </View>
  );
}

function ReviewQueue() {
  const review = useAppStore((s) => s.review);
  const resolveReview = useAppStore((s) => s.resolveReview);
  const queue = review.filter((r) => r.status === 'pending');
  const cur = queue[0];

  if (!cur) {
    return (
      <View style={styles.allClear}>
        <View style={styles.allClearRing}>
          <AllClearIcon />
        </View>
        <Text style={styles.allClearTitle}>All clear</Text>
        <Text style={styles.allClearSub}>
          Nothing needs your judgment. When the AI isn&apos;t sure about something it heard, it will wait for you here.
        </Text>
      </View>
    );
  }

  const pos = review.length - queue.length + 1;
  const c = entryColor[cur.type];

  return (
    <View style={styles.fill}>
      <View style={styles.reviewHeader}>
        <Text style={styles.reviewPos}>
          {pos} of {review.length} · oldest first
        </Text>
        <Text style={styles.reviewSort}>Sort ▾</Text>
      </View>
      <ScrollView contentContainerStyle={styles.scroll}>
        <View>
          <View style={styles.stackShadow} />
          <View style={styles.reviewCard}>
            <View style={styles.reviewCardHeader}>
              <View style={styles.typeTag}>
                <Dot c={c} size={6} />
                <Text style={[styles.typeTagText, { color: c }]}>{cur.label}</Text>
              </View>
              <Text style={styles.proposed}>proposed today</Text>
            </View>
            <Text style={styles.reviewHeadline}>{cur.headline}</Text>
            <Text style={styles.reviewNote}>{cur.note}</Text>
            <View style={styles.quoteBox}>
              <Text style={styles.quote}>{cur.quote}</Text>
              <Text style={styles.quoteSrc}>{cur.src}</Text>
            </View>
            <Text style={styles.reviewMeta}>{cur.meta}</Text>
          </View>
        </View>

        <View style={styles.actions}>
          <Pressable
            onPress={() => resolveReview(cur.id, 'rejected')}
            style={({ pressed }) => [styles.actionBtn, styles.rejectBtn, pressed && styles.actionPressed]}
          >
            <XIcon />
          </Pressable>
          <Pressable
            onPress={() => resolveReview(cur.id, 'accepted')}
            style={({ pressed }) => [styles.actionBtn, styles.editBtn, pressed && styles.actionPressed]}
          >
            <PencilIcon />
          </Pressable>
          <Pressable
            onPress={() => resolveReview(cur.id, 'accepted')}
            style={({ pressed }) => [styles.actionBtn, styles.acceptBtn, pressed && styles.actionPressed]}
          >
            <AcceptIcon />
          </Pressable>
        </View>
        <View style={styles.actionLabels}>
          <Text style={styles.actionLabel}>Reject</Text>
          <Text style={styles.actionLabel}>Edit</Text>
          <Text style={styles.actionLabel}>Accept</Text>
        </View>
        <Text style={styles.reviewFooter}>Accepted entries land in the Log · rejections are remembered</Text>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1, minHeight: 0 },
  header: { paddingTop: 14, paddingHorizontal: 20 },
  title: { fontSize: 32, fontWeight: '700', color: color.text, letterSpacing: 0.3 },
  segment: {
    marginTop: 10,
    marginHorizontal: 16,
    backgroundColor: color.card,
    borderRadius: radius.input,
    padding: 2,
    flexDirection: 'row',
  },
  segBtn: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    borderRadius: 9,
    paddingVertical: 6,
  },
  segActive: { backgroundColor: '#fff' },
  segText: { fontSize: 13.5, fontWeight: '600', color: color.text7 },
  segTextActive: { color: '#000' },
  segBadge: { backgroundColor: color.commitment, borderRadius: radius.pill, paddingHorizontal: 6, paddingVertical: 1 },
  segBadgeText: { color: '#1a1a1a', fontSize: 10.5, fontWeight: '700' },
  chips: { paddingTop: 10, paddingHorizontal: 16, flexDirection: 'row', gap: 7, flexWrap: 'wrap' },
  subFilters: { paddingTop: 8, paddingHorizontal: 16, flexDirection: 'row', gap: 7 },
  subFilter: {
    fontSize: 12.5,
    color: color.text2,
    borderWidth: 0.5,
    borderColor: 'rgba(235,235,245,.25)',
    borderRadius: radius.pill,
    paddingVertical: 4,
    paddingHorizontal: 11,
  },
  scroll: { paddingTop: 12, paddingHorizontal: 16, paddingBottom: 16, gap: 10 },
  memRow: { paddingVertical: 11, paddingHorizontal: 14, flexDirection: 'row', gap: 10 },
  memRowStruck: { backgroundColor: 'rgba(235,235,245,.03)' },
  memDot: { marginTop: 6 },
  memText: { flex: 1, gap: 1 },
  memHeadline: { fontSize: 14.5, fontWeight: '500', lineHeight: 19.6 },
  memMeta: { fontSize: 12, color: color.text5 },
  appendOnly: { fontSize: 11.5, color: color.text4, textAlign: 'center', paddingTop: 2 },
  reviewHeader: {
    paddingTop: 12,
    paddingHorizontal: 20,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  reviewPos: { fontSize: 13, color: color.text5 },
  reviewSort: { fontSize: 13, fontWeight: '600', color: color.link },
  stackShadow: {
    position: 'absolute',
    left: 8,
    right: 8,
    top: 10,
    bottom: -8,
    backgroundColor: color.cardRecessed,
    borderWidth: 0.5,
    borderColor: 'rgba(235,235,245,.08)',
    borderRadius: radius.review,
  },
  reviewCard: {
    backgroundColor: color.card,
    borderWidth: 0.5,
    borderColor: 'rgba(229,165,75,.4)',
    borderRadius: radius.review,
    padding: 16,
    gap: 11,
  },
  reviewCardHeader: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  typeTag: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    backgroundColor: 'rgba(235,235,245,.07)',
    borderRadius: radius.pill,
    paddingVertical: 4,
    paddingHorizontal: 10,
  },
  typeTagText: { fontSize: 11, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 0.7 },
  proposed: { marginLeft: 'auto', fontSize: 11.5, color: color.text3 },
  reviewHeadline: { fontSize: 19, fontWeight: '600', color: color.text, lineHeight: 24.7 },
  reviewNote: { fontSize: 13.5, lineHeight: 20.25, color: color.text2 },
  quoteBox: { backgroundColor: 'rgba(235,235,245,.05)', borderRadius: 12, paddingVertical: 11, paddingHorizontal: 13, gap: 6 },
  quote: { fontSize: 13.5, lineHeight: 20.25, color: color.text75, fontStyle: 'italic' },
  quoteSrc: { fontSize: 12, color: color.text3 },
  reviewMeta: { fontSize: 12, color: color.text3 },
  actions: { flexDirection: 'row', justifyContent: 'center', gap: 22, paddingTop: 14 },
  actionBtn: { width: 58, height: 58, borderRadius: radius.pill, alignItems: 'center', justifyContent: 'center' },
  actionPressed: { transform: [{ scale: 0.92 }] },
  rejectBtn: { backgroundColor: color.card, borderWidth: 0.5, borderColor: 'rgba(255,98,89,.5)' },
  editBtn: { backgroundColor: color.card, borderWidth: 0.5, borderColor: 'rgba(235,235,245,.25)' },
  acceptBtn: { backgroundColor: 'rgba(111,191,143,.16)', borderWidth: 0.5, borderColor: 'rgba(111,191,143,.55)' },
  actionLabels: { flexDirection: 'row', justifyContent: 'center', gap: 26 },
  actionLabel: { fontSize: 11, color: color.text3, width: 58, textAlign: 'center' },
  reviewFooter: { fontSize: 11.5, color: color.text4, textAlign: 'center' },
  allClear: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 14, paddingHorizontal: 40 },
  allClearRing: {
    width: 64,
    height: 64,
    borderRadius: radius.pill,
    borderWidth: 1.5,
    borderColor: 'rgba(111,191,143,.5)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  allClearTitle: { fontSize: 19, fontWeight: '600', color: color.text },
  allClearSub: { fontSize: 14, lineHeight: 21, color: color.text55, textAlign: 'center' },
});
