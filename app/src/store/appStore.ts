import { create } from 'zustand';
import { seedConvos, seedMemory, seedReview, seedTasks } from '../data/mock';
import { api, type AskResult } from '../services/api';
import type { Conversation, EntryType, MemoryEntry, PendantState, ReviewCandidate, Task } from '../types';

export type MemFilter = 'all' | EntryType;
export type TaskFilter = 'all' | string;
export type MemSegment = 'log' | 'review';
export type AskStep = 0 | 1 | 2;
export type DataSource = 'mock' | 'server';

export interface HomeStats {
  conversations: string;
  captured: string;
  digest: string;
}

const MOCK_STATS: HomeStats = {
  conversations: '6',
  captured: '2h 41m',
  digest:
    'Morning ran on family logistics and the 1.4.2 release — one promise to Maya due before 6 pm.',
};

const MOCK_ASK: AskResult = {
  answer:
    'One open promise: a retro-cadence proposal, made at the offsite on Jul 15 — now 7 days ' +
    "overdue. She nudged you about it at standup this morning; it's still unanswered.",
  citations: [
    { kind: 'task', id: 'retro', headline: 'Retro proposal · Jul 15' },
    { kind: 'wal', id: 'm3', type: 'question', headline: 'Retro cadence? · 9:27 AM' },
    { kind: 'wal', id: 'm4', type: 'decision', headline: 'Standup, 9:27 AM', conversation_id: 'standup' },
  ],
  searched: { wal_entries: 214, open_tasks: 41 },
};

function fmtCaptured(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.round((seconds % 3600) / 60);
  return h > 0 ? `${h}h ${m.toString().padStart(2, '0')}m` : `${m}m`;
}

interface AppState {
  dataSource: DataSource;
  stats: HomeStats;
  pendant: PendantState;
  deviceOpen: boolean;
  memSeg: MemSegment;
  memFilter: MemFilter;
  taskFilter: TaskFilter;
  askStep: AskStep;
  askQuestion: string;
  askResult: AskResult | null;
  tasks: Task[];
  review: ReviewCandidate[];
  mem: MemoryEntry[];
  convos: Conversation[];

  hydrate: () => Promise<void>;
  loadConvoDetail: (id: string) => Promise<void>;
  setPendant: (p: PendantState) => void;
  toggleMute: () => void;
  setDeviceOpen: (open: boolean) => void;
  setMemSeg: (seg: MemSegment) => void;
  setMemFilter: (f: MemFilter) => void;
  setTaskFilter: (f: TaskFilter) => void;
  toggleTask: (id: string) => void;
  resolveReview: (id: string, verdict: 'accepted' | 'rejected') => void;
  askGo: (question?: string) => void;
  resetAsk: () => void;
}

export const useAppStore = create<AppState>((set, get) => ({
  dataSource: 'mock',
  stats: MOCK_STATS,
  pendant: 'recording',
  deviceOpen: false,
  memSeg: 'log',
  memFilter: 'all',
  taskFilter: 'all',
  askStep: 0,
  askQuestion: '',
  askResult: null,
  tasks: seedTasks,
  review: seedReview,
  mem: seedMemory,
  convos: seedConvos,

  /** Pull a full snapshot from the backend; on failure stay on mock seeds. */
  hydrate: async () => {
    try {
      const snap = await api.snapshot();
      set({
        dataSource: 'server',
        tasks: snap.tasks,
        mem: snap.mem,
        review: snap.review,
        convos: snap.convos,
        stats: {
          conversations: String(snap.stats.conversations),
          captured: fmtCaptured(snap.stats.captured_seconds),
          digest: snap.stats.narrative ?? 'No digest yet — it builds as the day is captured.',
        },
      });
    } catch {
      // backend unreachable: mock fixture keeps the app fully usable (APP-6)
    }
  },

  loadConvoDetail: async (id) => {
    if (get().dataSource !== 'server') return;
    try {
      const detail = await api.conversation(id);
      set((s) => ({ convos: s.convos.map((c) => (c.id === id ? detail : c)) }));
    } catch {
      // detail stays list-shaped; screen renders what it has
    }
  },

  setPendant: (pendant) => set({ pendant }),
  toggleMute: () => set((s) => ({ pendant: s.pendant === 'muted' ? 'recording' : 'muted' })),
  setDeviceOpen: (deviceOpen) => set({ deviceOpen }),
  setMemSeg: (memSeg) => set({ memSeg }),
  setMemFilter: (memFilter) => set({ memFilter }),
  setTaskFilter: (taskFilter) => set({ taskFilter }),

  toggleTask: (id) => {
    const wasDone = get().tasks.find((t) => t.id === id)?.done ?? false;
    set((s) => ({ tasks: s.tasks.map((t) => (t.id === id ? { ...t, done: !t.done } : t)) }));
    if (get().dataSource === 'server') {
      api.toggleTask(id, !wasDone).catch(() => {
        set((s) => ({ tasks: s.tasks.map((t) => (t.id === id ? { ...t, done: wasDone } : t)) }));
      });
    }
  },

  // Append-only WAL discipline: accept/edit prepends a new entry; nothing is removed.
  resolveReview: (id, verdict) => {
    const target = get().review.find((r) => r.id === id);
    if (!target || target.status !== 'pending') return;
    set((s) => ({
      review: s.review.map((r) => (r.id === id ? { ...r, status: verdict } : r)),
      mem:
        verdict === 'accepted'
          ? [
              { id: `mem-${target.id}`, type: target.type, headline: target.headline, meta: target.memMeta },
              ...s.mem,
            ]
          : s.mem,
    }));
    if (get().dataSource === 'server') {
      api.resolveReview(id, verdict).catch(() => {});
    }
  },

  askGo: (question) => {
    const q = question ?? 'What did I promise Priya this week?';
    if (get().askStep === 1) return;
    set({ askStep: 1, askQuestion: q, askResult: null });
    if (get().dataSource === 'server') {
      api
        .ask(q)
        .then((result) => set({ askStep: 2, askResult: result }))
        .catch(() =>
          set({
            askStep: 2,
            askResult: { answer: 'Could not reach your server.', citations: [], searched: { wal_entries: 0, open_tasks: 0 } },
          }),
        );
    } else {
      setTimeout(() => set((s) => (s.askStep === 1 ? { askStep: 2, askResult: MOCK_ASK } : s)), 900);
    }
  },
  resetAsk: () => set({ askStep: 0, askQuestion: '', askResult: null }),
}));

/* ---- derived selectors (primitives/stable refs only — zustand v5 getSnapshot rule) ---- */

export const selectReviewCount = (s: AppState) =>
  s.review.filter((r) => r.status === 'pending').length;
export const selectMemCount = (s: AppState) => s.mem.filter((e) => !e.struck).length;

export const selectListeningLine = (s: AppState) =>
  s.pendant === 'recording'
    ? 'listening since 7:31 AM'
    : s.pendant === 'muted'
      ? 'muted by you at 2:20 PM'
      : 'captured 7:31 AM – 2:14 PM';

export const selectPendantLine = (s: AppState) =>
  s.pendant === 'disconnected' ? 'Pendant out of range' : 'Pendant connected';

export const selectPendantSub = (s: AppState) =>
  s.pendant === 'disconnected' ? 'Will sync on reconnect' : '82% · about 2 days · fully synced';
