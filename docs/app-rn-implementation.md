# Keepsake Companion App — React Native Implementation Plan

**Status:** v1.1 — M1 (Phases 0–7) implemented in `app/` and verified on Expo Web 2026-07-23; iOS Simulator pass pending (no Xcode on this machine)
**Date:** 2026-07-23
**Source design:** claude.ai/design project *Keepsake Companion App* → `Keepsake Prototype.dc.html` (interactive prototype, iOS dark, 402×874)
**Related docs:** [requirements.md](requirements.md) · [requirements/app.md](requirements/app.md)

> **Decision note (supersedes D4 for the companion app):** D4 in the requirements decision log chose Flutter. Per explicit direction (2026-07-23), the companion app is implemented in **React Native (Expo)** instead. APP-1…APP-6 requirements are unchanged; only the stack changes. Record as **D9: App stack = React Native / Expo, supersedes D4** in the decision log when requirements.md is next revised.

---

## 1. What we are building

The phone companion app for the Keepsake pendant: the consent surface, the day journal, and the query surface over the Memory WAL. The approved prototype defines a five-tab IA (matching APP-4):

1. **Home** — day header, stat cards (conversations / speech captured / memory entries / review queue), narrative digest line, Due-today tasks, Still-open items, pendant card, frozen past-day recaps.
2. **Convos** — searchable conversation list (Today/Yesterday sections, entry-count chips) → detail: summary, action items, linked memory entries, diarized transcript ("audio discarded" honesty label).
3. **Tasks** — commitments as a checkable list: person filter chips, Overdue/Due-today/Later sections, Apple Reminders sync banner.
4. **Memory** — Log/Review segmented control. Log: append-only WAL with type filters and supersession strikethrough. Review: card-stack triage (Accept / Edit / Reject) of low-confidence candidates; badge counts surface on the tab bar and Home.
5. **Ask** — chat over conversations + tasks + WAL; answers carry tappable citation chips ("on your server" honesty footer).

Cross-cutting surfaces:
- **Status pill** (every tab): Recording · battery% / Muted / Disconnected · last-seen. This is PR-1's consent surface in the app.
- **Pendant sheet** (modal): hard-mute toggle (with prominent "mic powered off at the hardware switch" state), battery, VAD sensitivity, firmware update, name, forget.

## 2. Milestone strategy

Two milestones, decoupled so UI work never blocks on hardware/backend:

- **M1 — Prototype parity (this plan, Phases 0–7):** pixel-faithful RN app driven entirely by an in-memory mock store seeded with the prototype's data. All interactions from the prototype work: tab nav, task toggling, memory filters, review triage mutating the log, mute toggle, ask flow.
- **M2 — Live data (Phases 8+, planned here, built later):** swap the mock store's data source for the real backend API + BLE gateway, per requirements/app.md. The store interface is designed in M1 so M2 is a data-layer swap, not a rewrite.

## 3. Tech stack

| Concern | Choice | Rationale |
|---|---|---|
| Framework | **Expo (latest SDK), React Native, TypeScript strict** | Fastest credible RN path; config plugins + dev client cover BLE later (react-native-ble-plx) without ejecting |
| Navigation | **expo-router** (file-based) | Tabs + stacks with typed routes; deep-linking free |
| State | **Zustand** | Tiny, testable domain store; mirrors the prototype's single-component state; selectors keep re-renders cheap |
| Icons/graphics | **react-native-svg** | The prototype's icons are bespoke minimal SVGs; port them 1:1 rather than approximating with an icon font |
| Styling | StyleSheet + `src/theme.ts` tokens | Design is one dark theme; no styling lib needed |
| Sheet/modal | RN `Modal` + Animated (Phase 7) | Single bottom sheet; avoid a gesture-lib dependency until swipe-to-triage warrants it |
| Tests | Jest + @testing-library/react-native for store & reducers | Store logic (triage, filters, supersession) is the risk area; screens verified in simulator |

## 4. Design tokens (extracted from the prototype)

```
Background:   app #000 · card #1C1C1E · recessed/past #141416 · sheet #161618 · chip track rgba(120,120,128,.24)
Separator:    rgba(84,84,88,.65) @ 0.5px
Text:         primary #FFF · secondary rgba(235,235,245,.6) · tertiary rgba(235,235,245,.45) · faint rgba(235,235,245,.35)
Accent/type:  decision #6CA8FF · commitment/review #E5A54B · fact/success #6FBF8F · question #B28CE0
Status:       recording #FF6259 · muted #FFB84D · link #6CA8FF · overdue #FF8A80
Radii:        card 16 · reviewCard 18 · sheet 22 (top) · row-input 11–12 · pill 999
Type scale:   screenTitle 32/700 · sheetTitle 22/700 · convoTitle 24/700 · reviewHeadline 19/600
              row 14.5/500–600 · body 13.5–15 · meta/caption 12 · sectionLabel 12/600 uppercase +0.5ls · micro 10–11.5
Spacing:      screen gutter 16 (headers 20) · card padding 12–16 · row padding 11×14 · list gap 8–11
Tab bar:      rgba(28,28,30,.9), top hairline, active #6CA8FF, inactive rgba(235,235,245,.5)
```

## 5. Architecture

```
app/                                  (Expo project root, monorepo app/ slot)
├── app/                              expo-router routes (thin — screens live in src/)
│   ├── _layout.tsx                   root stack: tabs + pendant-sheet modal
│   ├── (tabs)/_layout.tsx            custom 5-tab bar + status pill overlay
│   ├── (tabs)/index.tsx              Home
│   ├── (tabs)/convos/index.tsx       Conversations list
│   ├── (tabs)/convos/[id].tsx        Conversation detail
│   ├── (tabs)/tasks.tsx              Tasks
│   ├── (tabs)/memory.tsx             Memory (Log | Review)
│   └── (tabs)/ask.tsx                Ask
├── src/
│   ├── theme.ts                      tokens from §4
│   ├── types.ts                      domain model (§6)
│   ├── store/appStore.ts             Zustand store: state + actions (§6)
│   ├── data/mock.ts                  prototype seed data, one file, replaceable
│   ├── components/                   StatCard, TaskRow, MemoryRow, Chip, SectionLabel,
│   │                                 StatusPill, TabBar, ReviewCard, CitationChip,
│   │                                 PendantSheet, BatteryGlyph, icons/…
│   └── services/                     M2 seam: PendantService, ApiClient interfaces
│                                     (mock implementations in M1)
```

Principles:
- **Screens read the store through selectors; all mutations are named store actions** (`toggleTask`, `resolveReview(verdict)`, `setMemFilter`, `togglePendantMute`…). This mirrors the prototype's `renderVals()` and gives M2 a single seam.
- **Review triage is the one non-trivial state machine:** accept/edit → mark candidate resolved **and** prepend a WAL entry; reject → mark resolved, remembered. Guard against double-resolve (prototype does; we keep the invariant and unit-test it).
- **Append-only WAL discipline in the UI:** superseded entries render struck-through, never removed — the UI teaches MEM-1.
- **Pendant state** (`recording | muted | disconnected`) is store-global; the pill, Home listening line, pendant card, and sheet all derive from it.

## 6. Domain model (mock-phase; field names chosen to survive M2)

```ts
type PendantState = 'recording' | 'muted' | 'disconnected';
type EntryType = 'decision' | 'commitment' | 'fact' | 'question';

interface Task { id; title; meta; group: 'overdue'|'today'|'later'; person; done }
interface MemoryEntry { id; type: EntryType; headline; meta; struck?; convoId? }
interface ReviewCandidate { id; status: 'pending'|'accepted'|'rejected';
  label; type: EntryType; headline; note; quote; src; meta; memMeta }
interface Conversation { id; title; timeLabel; participants; section: 'today'|'yesterday';
  badges: {type: EntryType|'task'; count}[]; summary?; actionItems?; entries?; transcript? }
interface DayRecap { dateLabel; narrative; stats; frozenAt }
```

## 7. Phases

Each phase ends buildable and demoable in the iOS Simulator. One commit per phase.

| Phase | Scope | Done when |
|---|---|---|
| **0. Scaffold** | create-expo-app (TS), expo-router, zustand, react-native-svg, strict TS, `src/` skeleton, `theme.ts` | App boots to a black screen with theme in place; `tsc --noEmit` clean |
| **1. Shell** | Custom tab bar (5 tabs, ported SVG icons, review badge), StatusPill (3 variants), store + full mock seed | Tabs switch between placeholder screens; pill reflects store; badge shows 4 |
| **2. Home** | Stat grid (review card amber variant + "review clear" state), digest line, Due-today list (toggleable), Still open, pendant card, past-day recap | All Home taps navigate correctly; task toggle persists across tabs |
| **3. Convos** | List: search field (visual), sections, badge chips; Detail: summary, action items ("in Tasks ›"), linked entries, transcript with highlighted "you" turn | List → detail → back; cross-links to Tasks/Memory work |
| **4. Tasks** | Person chips (filter all sections), Reminders banner, Overdue (red-accented) / Due today / Later, done strikethrough | Filters + toggles correct; Overdue section hides when empty |
| **5. Memory** | Segmented Log/Review with badge; Log: type chips, Person/Date placeholder pills, supersession strikethrough, append-only footer; Review: stacked card, quote block, Accept/Edit/Reject, "N of M · oldest first", All-clear empty state | Accepting prepends to Log (memCount updates everywhere); queue drains to All clear; store unit tests pass |
| **6. Ask** | Idle suggestions, question bubble → thinking dots (~900 ms) → answer with 3 citation chips (→ Tasks/Memory/Convo detail), search-scope footer, input bar (visual) | Full flow runs; citations navigate |
| **7. Pendant sheet** | Modal sheet: grabber, mute card (amber warning ↔ normal + toggle), battery card, settings rows, "Forget this pendant"; entry points: pendant card + pill | Mute toggle flips pill/listening line everywhere; sheet dismisses on scrim/Done. Full-app pass in simulator against prototype |

**M2 backlog (planned, not in this pass):** Phase 8 — services seam wired to real REST/WebSocket client per BE-5; Phase 9 — BLE gateway (react-native-ble-plx via dev client, background modes per APP-1); Phase 10 — offline cache + honesty stats (APP-5/6); Phase 11 — settings sheet (backend URL, providers, retention per APP-4).

## 8. Risks / notes

- **Expo default template ships example screens** — strip to bare router shell in Phase 0 so no template residue leaks into the app.
- **Custom tab bar over `expo-router` Tabs:** use `tabBar` prop replacement, keeping router state as source of truth.
- **0.5px hairlines:** use `StyleSheet.hairlineWidth`.
- **Review "Edit" is accept-with-edit in the prototype** (no editor UI); M1 keeps that, editor comes with M2.
- **BLE later, not never:** nothing in M1 may assume web-only APIs; keep components RN-pure so the dev-client transition is clean.
- **zustand v5 selector rule (hit during M1):** a selector passed to `useAppStore` must return a cached/stable reference — returning a fresh array (e.g. `s.review.filter(...)`) loops `useSyncExternalStore` infinitely ("getSnapshot should be cached"). Select raw slices and derive arrays inside the component.
