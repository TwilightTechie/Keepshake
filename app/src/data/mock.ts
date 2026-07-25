import type { Conversation, MemoryEntry, ReviewCandidate, Task } from '../types';

export const seedTasks: Task[] = [
  { id: 'retro', title: 'Retro proposal for Priya', meta: '7 days overdue · offsite, Jul 15', group: 'overdue', person: 'Priya', done: false },
  { id: 'refill', title: "Pick up Nora's allergy refill", meta: 'before 6 pm · to Maya · kitchen, 7:44 AM', group: 'today', person: 'Maya', done: false },
  { id: 'notes', title: 'Send Sam the 1.4.2 release-notes draft', meta: 'end of day · to Sam · standup, 9:19 AM', group: 'today', person: 'Sam', done: false },
  { id: 'appt', title: "Book Nora's follow-up appointment", meta: "by Aug 1 · Dr. Okafor's office, 11:04 AM", group: 'later', person: 'Maya', done: false },
  { id: 'guide', title: 'Send Ana the sourdough starter guide', meta: 'this week · lunch, 1:02 PM', group: 'later', person: 'Ana', done: false },
];

export const seedReview: ReviewCandidate[] = [
  {
    id: 'r1', status: 'pending', label: 'COMMITMENT?', type: 'commitment',
    headline: "Review Ana's pitch deck this weekend",
    note: "The AI wasn't sure — casual phrasing, no firm date.",
    quote: '"…sure, send it over. I\'ll take a look this weekend — probably Saturday morning."',
    src: 'you · lunch with Ana, 1:08 PM',
    meta: 'with Ana · due: this weekend (editable)',
    memMeta: 'commitment · Ana · confirmed by you just now',
  },
  {
    id: 'r2', status: 'pending', label: 'FACT?', type: 'fact',
    headline: 'Ana prefers morning flights for long trips',
    note: 'Heard once, low stakes — might just be small talk.',
    quote: '"…I always book the 7 AM out of SFO, I\'m useless on red-eyes."',
    src: 'Ana · lunch, 12:58 PM',
    meta: 'about Ana',
    memMeta: 'fact · Ana · confirmed by you just now',
  },
  {
    id: 'r3', status: 'pending', label: 'QUESTION?', type: 'question',
    headline: 'Should the team sponsor the RN meetup?',
    note: 'Raised in passing at standup, no one answered.',
    quote: '"…also, do we want to sponsor the React Native meetup again this year?"',
    src: 'Sam · standup, 9:30 AM',
    meta: 'raised by Sam · open',
    memMeta: 'question · Sam · confirmed by you just now',
  },
  {
    id: 'r4', status: 'pending', label: 'COMMITMENT?', type: 'commitment',
    headline: "Take Thursday's school run",
    note: 'Said yesterday on the planning call — double-checking the day.',
    quote: '"…yep, I\'ve got Thursday, you take Friday."',
    src: 'you · call with Maya, 5:40 PM',
    meta: 'with Maya · Thursday',
    memMeta: 'commitment · Maya · confirmed by you just now',
  },
];

export const seedMemory: MemoryEntry[] = [
  { id: 'm1', type: 'fact', headline: 'Ana is moving to Lisbon in October', meta: 'fact · Ana · 1:15 PM · auto' },
  { id: 'm2', type: 'fact', headline: "Nora's allergist is Dr. Okafor, Cedar Clinic", meta: 'fact · 11:04 AM · auto' },
  { id: 'm3', type: 'question', headline: 'What cadence should retros run on?', meta: 'question · Priya · 9:27 AM · open' },
  { id: 'm4', type: 'decision', headline: 'Ship the sync fix in 1.4.2, not as a hotfix', meta: 'decision · Leo, Sam · 9:21 AM · confirmed ✓' },
  { id: 'm5', type: 'commitment', headline: "Pick up Nora's allergy refill before 6 pm", meta: 'commitment · Maya · 7:44 AM · auto' },
  { id: 'm6', type: 'decision', headline: 'Expand 1.5 scope to include the importer', meta: 'decision · Leo · Jul 21 · supersedes ↓' },
  { id: 'm7', type: 'decision', headline: 'Hold 1.5 scope to sync + exports only', meta: 'decision · Jul 18 · superseded Jul 21 ↑', struck: true },
];

export const seedConvos: Conversation[] = [
  {
    id: 'lunch', title: 'Lunch — catching up with Ana', timeLabel: '12:35 · 41 min',
    participants: 'Ana, you', section: 'today',
    badges: [
      { type: 'fact', label: '2 facts' },
      { type: 'commitment', label: '1 commitment' },
    ],
  },
  {
    id: 'okafor', title: "Dr. Okafor's office — call", timeLabel: '11:02 · 4 min',
    participants: 'Receptionist, you', section: 'today',
    badges: [{ type: 'fact', label: '2 facts' }],
  },
  {
    id: 'standup', title: 'Standup — 1.4.2 release call', timeLabel: '9:15 · 17 min',
    participants: 'Leo, Sam, Priya, you', section: 'today',
    badges: [
      { type: 'decision', label: '1 decision' },
      { type: 'commitment', label: '1 task' },
      { type: 'question', label: '1 question' },
    ],
    detail: {
      subtitle: 'Today, 9:15–9:32 AM · 17 min · Leo, Sam, Priya, you',
      summary:
        'The team weighed hotfixing the sync bug against holding it for 1.4.2 and chose the release train. Sam took release notes; Priya reopened the retro-cadence question without resolution.',
      actionItems: [
        { title: 'Send Sam the release-notes draft' },
        { title: 'Leo: re-run BLE regression suite on Android' },
      ],
      entries: [
        { type: 'decision', headline: 'Ship the sync fix in 1.4.2, not as a hotfix' },
        { type: 'question', headline: 'Retro cadence — open question from Priya' },
      ],
      transcript: [
        { time: '9:18', speaker: 'Leo', text: "If we hotfix the sync bug we skip QA entirely. I'd rather hold it." },
        { time: '9:19', speaker: 'You', text: 'Agreed — it rides in 1.4.2. Sam, can you own the release notes?', isYou: true },
        { time: '9:19', speaker: 'Sam', text: "Yep, I'll have a draft by end of day." },
        { time: '9:27', speaker: 'Priya', text: 'One more thing — did we ever settle the retro cadence?' },
      ],
    },
  },
  {
    id: 'kitchen', title: 'Kitchen — morning logistics', timeLabel: '7:42 · 8 min',
    participants: 'Maya, you', section: 'today',
    badges: [{ type: 'commitment', label: '1 commitment' }],
  },
  {
    id: 'planning', title: '1.5 planning — long call with Leo', timeLabel: '2:00 · 48 min',
    participants: 'Leo, you', section: 'yesterday',
    badges: [
      { type: 'decision', label: '2 decisions' },
      { type: 'commitment', label: '3 tasks' },
    ],
  },
];
