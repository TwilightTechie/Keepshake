/** ApiClient for the Keepsake backend (docs/backend-plan.md §4).
 * Maps server payloads onto the app's domain types; the zustand store stays the
 * single source the screens read from. */

import type { Conversation, ConvoBadge, EntryType, MemoryEntry, ReviewCandidate, Task } from '../types';
import { API_TOKEN, API_URL } from './config';

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${API_URL}/v1${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${API_TOKEN}`,
      'Content-Type': 'application/json',
      ...init?.headers,
    },
  });
  if (!res.ok) throw new Error(`${init?.method ?? 'GET'} ${path} → ${res.status}`);
  return (await res.json()) as T;
}

/* ---- server payload shapes ---- */

interface ServerTask {
  id: string;
  title: string;
  meta: string | null;
  due: string | null;
  person: string | null;
  done: boolean;
  group: 'overdue' | 'today' | 'later';
}

interface ServerWalEntry {
  id: string;
  ts: string;
  type: EntryType;
  headline: string;
  participants: string[];
  provenance: string;
  superseded_by: string | null;
}

interface ServerReviewCandidate {
  id: string;
  type: EntryType;
  headline: string;
  why: string | null;
  participants: string[];
  confidence: number;
  due: string | null;
  evidence: { conversation_id?: string; quote?: string | null } | null;
}

interface ServerConversation {
  id: string;
  title: string;
  started_at: string;
  ended_at: string;
  participants: string[];
  summary: string | null;
  badges?: { type: string; count: number }[];
}

interface ServerConvoDetail extends ServerConversation {
  transcript: { time: string; speaker: string; text: string }[];
  entries: { id: string; type: EntryType; headline: string }[];
}

export interface DayStats {
  day: string;
  conversations: number;
  captured_seconds: number;
  wal_entries: number;
  review_pending: number;
  narrative: string | null;
}

export interface AskResult {
  answer: string;
  citations: {
    kind: 'wal' | 'task';
    id: string;
    type?: EntryType;
    headline: string;
    conversation_id?: string | null;
  }[];
  searched: { wal_entries: number; open_tasks: number };
}

/* ---- mappers ---- */

const hhmm = (iso: string) =>
  new Date(iso).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });

function mapTask(t: ServerTask): Task {
  return {
    id: t.id,
    title: t.title,
    meta: t.meta ?? (t.due ? `due ${new Date(t.due).toLocaleDateString()}` : ''),
    group: t.group,
    person: t.person ?? '',
    done: t.done,
  };
}

function mapWal(e: ServerWalEntry): MemoryEntry {
  const bits = [e.type, e.participants.join(', '), hhmm(e.ts), e.provenance];
  return {
    id: e.id,
    type: e.type,
    headline: e.headline,
    meta: bits.filter(Boolean).join(' · '),
    struck: e.superseded_by != null,
  };
}

function mapReview(r: ServerReviewCandidate): ReviewCandidate {
  return {
    id: r.id,
    status: 'pending',
    label: `${r.type.toUpperCase()}?`,
    type: r.type,
    headline: r.headline,
    note: r.why ?? `Confidence ${Math.round(r.confidence * 100)}% — needs your judgment.`,
    quote: r.evidence?.quote ?? '',
    src: r.participants.join(', '),
    meta: [r.participants.length ? `with ${r.participants[0]}` : null, r.due ? `due ${r.due}` : null]
      .filter(Boolean)
      .join(' · '),
    memMeta: `${r.type} · ${r.participants[0] ?? ''} · confirmed by you just now`,
  };
}

function mapBadges(badges: { type: string; count: number }[] | undefined): ConvoBadge[] {
  return (badges ?? []).map((b) => ({
    type: (b.type === 'rollback' ? 'decision' : b.type) as ConvoBadge['type'],
    label: `${b.count} ${b.type}${b.count > 1 ? 's' : ''}`,
  }));
}

function sectionFor(iso: string): 'today' | 'yesterday' {
  return new Date(iso).toDateString() === new Date().toDateString() ? 'today' : 'yesterday';
}

function mapConversation(c: ServerConversation): Conversation {
  const mins = Math.max(
    1,
    Math.round((new Date(c.ended_at).getTime() - new Date(c.started_at).getTime()) / 60000),
  );
  return {
    id: c.id,
    title: c.title,
    timeLabel: `${hhmm(c.started_at)} · ${mins} min`,
    participants: c.participants.join(', '),
    section: sectionFor(c.started_at),
    badges: mapBadges(c.badges),
  };
}

function mapConvoDetail(c: ServerConvoDetail): Conversation {
  return {
    ...mapConversation(c),
    detail: {
      subtitle: `${hhmm(c.started_at)}–${hhmm(c.ended_at)} · ${c.participants.join(', ')}`,
      summary: c.summary ?? '',
      actionItems: [],
      entries: c.entries.map((e) => ({ type: e.type, headline: e.headline })),
      transcript: c.transcript.map((t) => ({
        time: hhmm(t.time),
        speaker: t.speaker,
        text: t.text,
        isYou: t.speaker.toLowerCase() === 'you',
      })),
    },
  };
}

/* ---- client ---- */

const today = () => new Date().toISOString().slice(0, 10);

export const api = {
  async snapshot() {
    const [day, tasks, wal, review, convos] = await Promise.all([
      request<DayStats>(`/days/${today()}`),
      request<ServerTask[]>('/tasks'),
      request<ServerWalEntry[]>('/wal'),
      request<ServerReviewCandidate[]>('/review'),
      request<ServerConversation[]>('/conversations'),
    ]);
    return {
      stats: day,
      tasks: tasks.map(mapTask),
      mem: wal.map(mapWal),
      review: review.map(mapReview),
      convos: convos.map(mapConversation),
    };
  },
  async conversation(id: string): Promise<Conversation> {
    return mapConvoDetail(await request<ServerConvoDetail>(`/conversations/${id}`));
  },
  toggleTask(id: string, done: boolean) {
    return request(`/tasks/${id}`, { method: 'PATCH', body: JSON.stringify({ done }) });
  },
  resolveReview(id: string, verdict: 'accepted' | 'rejected') {
    return request(`/review/${id}/resolve`, { method: 'POST', body: JSON.stringify({ verdict }) });
  },
  ask(question: string) {
    return request<AskResult>('/ask', { method: 'POST', body: JSON.stringify({ question }) });
  },
};
