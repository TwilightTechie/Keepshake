import { useRouter } from 'expo-router';
import React, { useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { BubbleSmallIcon, MicIcon } from '@/components/icons';
import { ScreenShell } from '@/components/ScreenShell';
import { Dot } from '@/components/ui';
import { useAppStore } from '@/store/appStore';
import { color, radius } from '@/theme';

const SUGGESTIONS = ['What did I promise Priya this week?', "When is Nora's follow-up due?"];

export default function AskScreen() {
  const router = useRouter();
  const askStep = useAppStore((s) => s.askStep);
  const askQuestion = useAppStore((s) => s.askQuestion);
  const askResult = useAppStore((s) => s.askResult);
  const askGo = useAppStore((s) => s.askGo);
  const setMemSeg = useAppStore((s) => s.setMemSeg);
  const [draft, setDraft] = useState('');

  const send = (q: string) => {
    const question = q.trim();
    if (question) {
      setDraft('');
      askGo(question);
    }
  };

  const openCitation = (c: NonNullable<typeof askResult>['citations'][number]) => {
    if (c.kind === 'task') {
      router.navigate('/tasks');
    } else if (c.conversation_id) {
      router.navigate(`/convos/${c.conversation_id}`);
    } else {
      setMemSeg('log');
      router.navigate('/memory');
    }
  };

  return (
    <ScreenShell>
      <View style={styles.header}>
        <Text style={styles.title}>Ask</Text>
      </View>
      <ScrollView contentContainerStyle={[styles.scroll, askStep === 0 && styles.scrollIdle]}>
        {askStep === 0 ? (
          <View style={styles.idle}>
            <Text style={styles.idleHint}>
              Ask anything across your conversations, tasks, and memory. Answers cite their sources.
            </Text>
            {SUGGESTIONS.map((s, i) => (
              <Pressable
                key={i}
                onPress={() => send(s)}
                style={({ pressed }) => [styles.suggestion, pressed && { transform: [{ scale: 0.97 }] }]}
              >
                <Text style={i === 0 ? styles.suggestionActive : styles.suggestionMuted}>
                  &quot;{s}&quot;
                </Text>
              </Pressable>
            ))}
          </View>
        ) : (
          <View style={styles.thread}>
            <View style={styles.userBubble}>
              <Text style={styles.userText}>{askQuestion}</Text>
            </View>
            {askStep === 1 && (
              <View style={styles.thinking}>
                <Dot c="rgba(235,235,245,.45)" />
                <Dot c="rgba(235,235,245,.3)" />
                <Dot c="rgba(235,235,245,.18)" />
              </View>
            )}
            {askStep === 2 && askResult && (
              <View style={styles.answerWrap}>
                <View style={styles.answerBubble}>
                  <Text style={styles.answerText}>{askResult.answer}</Text>
                  {askResult.citations.length > 0 && (
                    <View style={styles.citations}>
                      {askResult.citations.map((c, i) => (
                        <Pressable
                          key={i}
                          onPress={() => openCitation(c)}
                          style={[
                            styles.citation,
                            c.kind === 'task'
                              ? styles.citationTask
                              : c.conversation_id
                                ? styles.citationConvo
                                : styles.citationMem,
                          ]}
                        >
                          {c.kind === 'task' ? (
                            <Dot c={color.commitment} size={6} />
                          ) : c.conversation_id ? (
                            <BubbleSmallIcon />
                          ) : (
                            <Dot c={c.type ? color[c.type] : color.question} size={6} />
                          )}
                          <Text style={styles.citationText} numberOfLines={1}>
                            {c.headline}
                          </Text>
                        </Pressable>
                      ))}
                    </View>
                  )}
                </View>
                <Text style={styles.provenance}>
                  Searched {askResult.searched.wal_entries} memory entries ·{' '}
                  {askResult.searched.open_tasks} open tasks · on your server
                </Text>
              </View>
            )}
          </View>
        )}
      </ScrollView>
      <View style={styles.inputBar}>
        <TextInput
          style={styles.input}
          placeholder="Ask your memory…"
          placeholderTextColor="rgba(235,235,245,.4)"
          value={draft}
          onChangeText={setDraft}
          onSubmitEditing={() => send(draft)}
          returnKeyType="send"
        />
        <View style={styles.micBtn}>
          <MicIcon />
        </View>
      </View>
    </ScreenShell>
  );
}

const styles = StyleSheet.create({
  header: { paddingTop: 14, paddingHorizontal: 20 },
  title: { fontSize: 32, fontWeight: '700', color: color.text, letterSpacing: 0.3 },
  scroll: { paddingTop: 16, paddingHorizontal: 16, gap: 14 },
  scrollIdle: { flexGrow: 1 },
  idle: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 16, paddingHorizontal: 24 },
  idleHint: { fontSize: 15, lineHeight: 22.5, color: color.text55, textAlign: 'center' },
  suggestion: {
    backgroundColor: color.card,
    borderWidth: 0.5,
    borderColor: 'rgba(235,235,245,.18)',
    borderRadius: radius.pill,
    paddingVertical: 10,
    paddingHorizontal: 18,
  },
  suggestionActive: { fontSize: 14, color: color.link },
  suggestionMuted: { fontSize: 14, color: color.text5 },
  thread: { gap: 14 },
  userBubble: {
    alignSelf: 'flex-end',
    maxWidth: '78%',
    backgroundColor: color.bubbleUser,
    borderTopLeftRadius: 18,
    borderTopRightRadius: 18,
    borderBottomRightRadius: 4,
    borderBottomLeftRadius: 18,
    paddingVertical: 11,
    paddingHorizontal: 15,
  },
  userText: { fontSize: 15, lineHeight: 21.75, color: color.text },
  thinking: { alignSelf: 'flex-start', flexDirection: 'row', gap: 6, paddingVertical: 4, paddingHorizontal: 8 },
  answerWrap: { alignSelf: 'flex-start', maxWidth: '92%', gap: 10 },
  answerBubble: {
    backgroundColor: color.card,
    borderTopLeftRadius: 18,
    borderTopRightRadius: 18,
    borderBottomRightRadius: 18,
    borderBottomLeftRadius: 4,
    paddingVertical: 13,
    paddingHorizontal: 15,
    gap: 10,
  },
  answerText: { fontSize: 15, lineHeight: 22.5, color: color.text9 },
  citations: { flexDirection: 'row', flexWrap: 'wrap', gap: 7 },
  citation: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    borderRadius: radius.pill,
    borderWidth: 0.5,
    paddingVertical: 5,
    paddingHorizontal: 11,
    maxWidth: 260,
  },
  citationTask: { backgroundColor: 'rgba(229,165,75,.14)', borderColor: 'rgba(229,165,75,.4)' },
  citationMem: { backgroundColor: 'rgba(178,140,224,.14)', borderColor: 'rgba(178,140,224,.4)' },
  citationConvo: { backgroundColor: 'rgba(235,235,245,.07)', borderColor: 'rgba(235,235,245,.2)' },
  citationText: { fontSize: 12, color: 'rgba(235,235,245,.8)' },
  provenance: { fontSize: 11.5, color: 'rgba(235,235,245,.4)', paddingLeft: 4 },
  inputBar: {
    paddingTop: 10,
    paddingHorizontal: 16,
    paddingBottom: 12,
    flexDirection: 'row',
    gap: 9,
    alignItems: 'center',
  },
  input: {
    flex: 1,
    height: 42,
    borderRadius: radius.pill,
    backgroundColor: color.card,
    borderWidth: 0.5,
    borderColor: 'rgba(235,235,245,.14)',
    paddingHorizontal: 16,
    fontSize: 15,
    color: color.text,
  },
  micBtn: {
    width: 42,
    height: 42,
    borderRadius: radius.pill,
    backgroundColor: color.card,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
