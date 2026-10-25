export type PendantState = 'recording' | 'muted' | 'disconnected';

export type EntryType = 'decision' | 'commitment' | 'fact' | 'question';

export type TaskGroup = 'overdue' | 'today' | 'later';

export interface Task {
  id: string;
  title: string;
  meta: string;
  group: TaskGroup;
  person: string;
  done: boolean;
}

export interface MemoryEntry {
  id: string;
  type: EntryType;
  headline: string;
  meta: string;
  struck?: boolean;
}

export interface ReviewCandidate {
  id: string;
  status: 'pending' | 'accepted' | 'rejected';
  label: string;
  type: EntryType;
  headline: string;
  note: string;
  quote: string;
  src: string;
  meta: string;
  /** meta line the entry gets when accepted into the log */
  memMeta: string;
}

export interface ConvoBadge {
  type: EntryType | 'task';
  label: string;
}

export interface TranscriptTurn {
  time: string;
  speaker: string;
  text: string;
  isYou?: boolean;
}

export interface ConvoActionItem {
  title: string;
}

export interface ConvoEntryLink {
  type: EntryType;
  headline: string;
}

export interface Conversation {
  id: string;
  title: string;
  timeLabel: string;
  participants: string;
  section: 'today' | 'yesterday';
  badges: ConvoBadge[];
  detail?: {
    subtitle: string;
    summary: string;
    actionItems: ConvoActionItem[];
    entries: ConvoEntryLink[];
    transcript: TranscriptTurn[];
  };
}
