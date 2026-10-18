# Product & Technical Master Plan: Keepsake AI Companion (Mobile Application)

> **Document Status**: Production-Ready Architectural & Product Specification  
> **Target Platform**: iOS 16.0+ (SwiftUI, Modern Concurrency, WebSocket, BLE Gateway)  
> **Author**: Keepsake AI Core Team  
> **Target Audience**: Product Managers, AI Engineers, and Autonomous Coding Agents  

---

## 1. Executive Product Vision & Strategy

### 1.1 The Product Concept: Anup's Ambient Second Brain
Keepsake is not a gadget or a Bluetooth debugging utility; it is **Anup's ambient intelligence companion**. While the physical pendant silently and reliably captures raw 16 kHz audio throughout the day, the mobile application transforms that continuous stream into **clarity, accountability, and effortless memory recall**.

Most wearable companion apps fail because they either look like raw developer consoles or overwhelm the user with endless unstructured transcript walls. Keepsake solves this by prioritizing **high-signal, structured daily synthesis**:
1. **Live Presence**: Instantly seeing spoken words transcribed live with an animated waveform indicator.
2. **The Verdict ("Calls You Made Today")**: A dedicated, prominent ledger of every strategic decision, agreement, and commitment Anup made across all conversations.
3. **Personalized Day Briefings**: High-signal, second-person summaries directly addressing Anup (*"Hey Anup, you decided to..."*).
4. **Ask Your Day**: Conversational semantic search over ambient audio history.
5. **Preserved Engineering Vault**: The existing diagnostic gateway (packet stats, sequence gaps, upload queue, chunk inspector, 3-day logs) is retained 100% intact as an engineering panel.

---

### 1.2 Market & Competitor Benchmarking

| Feature Dimension | Limitless / Rewind Pendant | Omi / Friend | Plaud NotePin | Keepsake AI (Our Plan) |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Value Prop** | "Remember everything you heard" | Emotional AI companion | Business meeting summaries | **Decisions, Action Items & Personal Executive Digest** |
| **Live Speech View** | Real-time text stream | App-based live transcript | Post-recording upload only | **Real-time WebSocket transcript with animated waveform** |
| **Decisions Tracking** | Embedded in notes | None | Bullet list in summary | **Dedicated "The Verdict" Daily Ledger with checkmarks** |
| **Personalization** | Third-person generic | Chat persona | Generic corporate | **Second-person conversational ("Hey Anup, you...")** |
| **Hardware Link** | Proprietary BLE | Open BLE (Opus/PCM) | Proprietary BLE | **Native 16 kHz Mono PCM16 raw link with watchdog** |
| **System Diagnostics** | Hidden | Basic battery | Minimal | **Preserved Engineering Vault with bit-exact chunk audit** |

---

## 2. Information Architecture & Navigation

The application uses an intuitive **3+1 Tab Hierarchy** designed for effortless everyday use, while keeping deep technical tools easily accessible.

```
                    ┌──────────────────────────────────────────────┐
                    │               Keepsake AI App                │
                    └──────────────────────┬───────────────────────┘
                                           │
         ┌──────────────────┬──────────────┴─────┬──────────────────┐
         ▼                  ▼                    ▼                  ▼
   ┌───────────┐      ┌───────────┐        ┌───────────┐      ┌───────────┐
   │ 1. Today  │      │2. Timeline│        │3. Ask AI  │      │ 4. Device │
   │  (Home)   │      │(Convers.) │        │(Recall)   │      │ (Gateway) │
   └─────┬─────┘      └───────────┘        └───────────┘      └─────┬─────┘
         │                                                          │
         ├► Status & Presence Dock (Battery, BLE, Mic pulse)        ├► Keepsake-P0 BLE link
         ├► Live Speech Stream (WebSocket real-time text)          ├► Ingestion Server & Token
         ├► The Verdict: Decisions Taken Today                      ├► Packet stats & gaps
         ├► Personalized Day Briefing ("Hey Anup...")               ├► Upload queue & chunks
         └► Action Items & Commitments                              └► 3-Day Diagnostic Logs
```

### 2.1 Tab Structure
1. **Today (Primary Home)**: The daily executive dashboard. Contains the live speech streaming dock, today's aggregated decisions block, the latest personalized AI summary, and action items.
2. **Timeline (Memory Stream)**: Chronological conversational sessions. Grouped by time (Morning, Afternoon, Evening) with speaker turns, tags, and word counts.
3. **Ask AI (Conversational Recall)**: Direct question-answering over your conversational history (*"What did we discuss regarding server deployment?"*).
4. **Device & Gateway (Engineering Vault)**: The existing `GatewayView` in its entirety. Shows BLE connection status, device battery/power, live streaming toggle, packet statistics, upload queue, chunk file inspector, server auth settings, and diagnostic logs.

---

## 3. Screen-by-Screen Product Specifications

### 3.1 Screen 1: "Today" (The Executive Dashboard)

#### Visual Layout & Hierarchy:
1. **Top Ambient Header**:
   - Greeting: Dynamic greeting based on time of day (*"Good morning, Anup 👋"*, *"Good afternoon, Anup 👋"*, *"Good evening, Anup 👋"*).
   - Date and hardware badge: Pill indicating device state (e.g., `Keepsake-P0 · Active 16 kHz · Battery 92%`).
   - Refresh & Manual Summarize action icons.

2. **The Live Speech Dock ("Listening Now")**:
   - A modern, glowing card with an animated waveform that pulses whenever audio packets are arriving.
   - Displays real-time streaming transcripts delivered over WebSocket.
   - Tap-to-expand into an immersive, distraction-free **Full-Screen Live Speech Mode**.
   - Offline / Standby state: When the pendant is disconnected or silence is detected, smoothly transitions to *"Pendant connected. Speak anytime to transcribe live."*

3. **"The Verdict" - Decisions Taken Today**:
   - High-contrast, beautifully styled card block.
   - Creative titles: **"The Verdict: Decisions Made Today"** or **"Today's Decisions & Calls"**.
   - Aggregates decisions across all conversations of the current day.
   - Each decision displayed as an actionable card with:
     - Emerald checkmark seal icon (`checkmark.seal.fill`).
     - Concrete decision text (*"Agreed with backend team to lower RMS threshold to 70"*).
     - Time badge and conversation reference link (*"2:45 PM · Firmware Architecture"*).
     - Interactive completion / acknowledgement toggle.

4. **Personalized Day Briefing ("Day Insights")**:
   - Personalized second-person narrative for Anup:
     - Highlighted Quote Banner: *"Hey Anup, you wrapped up the firmware tests and outlined the next steps for the mobile app."*
     - Executive synthesis of the main topics and context.
     - "Summarize Now" button (`bolt.fill`) with loading spinner.

5. **Action Items & Commitments**:
   - Tasks extracted from speech, styled as an interactive checklist:
     - `arrow.right.circle.fill` badge.
     - Direct task instruction (*"Review the Caddy reverse proxy routing for WebSocket support"*).
     - Checkbox to mark as done locally.

---

### 3.2 Screen 2: "Timeline" (Conversational History)

* **Date Selector**: Horizontal calendar strip to view previous days.
* **Session Cards**: Each conversation block is automatically clustered (e.g., 5–10 minute meetings or conversational bursts):
  - Session Title (e.g., *"Firmware Optimization & Battery Life"*).
  - Time range (e.g., *"11:15 AM - 11:28 AM · 13 mins"*).
  - Word count and speech volume indicator.
  - Collapsible full transcript with speaker turn labels.
  - Quick action to copy transcript or share markdown summary.

---

### 3.3 Screen 3: "Ask AI" (Conversational Recall / Second Brain)

* **Natural Language Search & Q&A**:
  - Chat interface powered by Ollama Qwen 3 (8B) running on the Mac Mini via the server tunnel.
  - Prompt chips for quick questions:
    - *"What decisions did I make before lunch?"*
    - *"What tasks did I promise to complete today?"*
    - *"Summarize my conversation with the engineering team."*
* **Citation & Verification**: Every AI response includes direct references to the conversation time and original spoken quote.

---

### 3.4 Screen 4: "Device & Gateway" (Preserved Engineering Vault)

* **100% Retention of Existing System Functionality**:
  - **Pendant Connection**: Device name, firmware descriptor (`KSR1`), status color, connect/stop button, forget device.
  - **Live Webhook Settings**: Editable URL, simple auth token with Show/Hide toggle, Keychain storage, Reset Defaults.
  - **Connection Stats Grid**: Exact packet count, byte volume, sequence gaps, reordered/malformed packets, last packet timestamp.
  - **Upload Queue & Chunks**: Pending chunks count, local storage usage (with 1 GB limit), retry now button, and **Inspect Checkpoint Files** modal.
  - **Diagnostic Logs**: File-based 3-day auto-purging log viewer with full-text search, "Generate Report", and "Copy All".
  - **How It Works Notes**: Technical constraints (native 16 kHz PCM16, iOS background limitations).

---

## 4. Visual Design System & Theming

### 4.1 Theme Architecture (Light & Dark Mode)
The app must support seamless dynamic appearance switching with high-contrast, pixel-perfect styling in both modes:

```
┌─────────────────────────┬────────────────────────────┬────────────────────────────┐
│ UI Element              │ Dark Mode (OLED Slate)     │ Light Mode (Ceramic Glass) │
├─────────────────────────┼────────────────────────────┼────────────────────────────┤
│ Background              │ #0B0F19 (Deep Obsidian)    │ #F8FAFC (Ceramic White)    │
│ Card Surface            │ #161B26 (Frosted Glass)    │ #FFFFFF (Pure Card Surface)│
│ Card Border             │ rgba(255, 255, 255, 0.08)  │ #E2E8F0 (Subtle Slate)     │
│ Accent Primary          │ #6366F1 (Electric Indigo)  │ #4F46E5 (Deep Indigo)      │
│ Decisions & Success     │ #10B981 (Emerald Green)    │ #059669 (Forest Emerald)   │
│ Action Items            │ #3B82F6 (Sapphire Blue)    │ #2563EB (Royal Blue)       │
│ Primary Text            │ #F9FAFB (High-contrast)    │ #0F172A (Deep Slate)       │
│ Secondary Text          │ #9CA3AF (Muted Silver)     │ #64748B (Muted Slate)      │
│ Waveform Glow           │ rgba(99, 102, 241, 0.35)   │ rgba(79, 70, 229, 0.20)    │
└─────────────────────────┴────────────────────────────┴────────────────────────────┘
```

### 4.2 Typography & Iconography
- **Headings & Titles**: `SF Pro Display` with bold/semibold weights.
- **Body & Digest**: `SF Pro Text` with relaxed line spacing (1.3x) for comfortable reading.
- **Numbers & Metrics**: `SF Pro Rounded` (gives hardware and stats a friendly, polished feel).
- **Technical & Diagnostics**: `SF Mono` for timestamps, chunk IDs, and byte counters.
- **Icons**: Apple SF Symbols with hierarchical and multicolor rendering.

### 4.3 Haptic Feedback Profile
- **Soft impact** on tab selection and pull-to-refresh trigger.
- **Medium impact** on capture connect / stop button tap.
- **Success notification** on decision completion toggle and summary generation.
- **Warning notification** on BLE disconnect or sequence gap alert.

---

## 5. Technical Architecture & Data Pipeline

```
                               ┌─────────────────────────────┐
                               │     Keepsake-P0 Pendant     │
                               └──────────────┬──────────────┘
                                              │ BLE Notify (16 kHz PCM16)
                                              ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                    iOS Mobile App                                      │
│                                                                                        │
│   ┌─────────────────────┐   Audio Packets    ┌─────────────────────────────────────┐   │
│   │   PendantReceiver   │───────────────────►│       Live Audio Stream Buffer      │   │
│   │    (CoreBluetooth)  │                    └──────────────────┬──────────────────┘   │
│   └──────────┬──────────┘                                       │ HTTP POST            │
│              │ Checkpoint JSONL                                 ▼ (Every 1-2 sec)      │
│              ▼                                                                         │
│   ┌─────────────────────┐                    ┌─────────────────────────────────────┐   │
│   │     ChunkStore      │                    │          DigitalOcean Cloud         │   │
│   │ (ApplicationSupport)│                    │            (168.144.190.24)         │   │
│   └─────────────────────┘                    │                                     │   │
│                                              │   POST /omi/webhook/audio           │   │
│   ┌─────────────────────┐   WebSocket Stream │   ┌─────────────────────────────┐   │   │
│   │ WebSocketSpeechSync │◄───────────────────┼───│     FastAPI (omi_server)    │   │   │
│   │  (Live Speech UI)   │                    │   │    + Sarvam STT (saaras:v4) │   │   │
│   └─────────────────────┘                    │   └──────────────┬──────────────┘   │   │
│                                              │                  │ Transcripts      │   │
│   ┌─────────────────────┐   REST Polling     │                  ▼                  │   │
│   │  InsightsViewModel  │◄───────────────────┼───► GET /omi/api/summaries          │   │
│   │ (Decisions & Digest)│                    │   ► GET /omi/api/decisions/today    │   │
│   └─────────────────────┘                    │   ► POST /omi/api/summarize         │   │
│                                              │                  │                  │   │
│                                              │                  ▼ Reverse Tunnel   │   │
│                                              │   ┌─────────────────────────────┐   │   │
│                                              │   │    Mac Mini: Ollama Qwen    │   │   │
│                                              │   └─────────────────────────────┘   │   │
│                                              └─────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### 5.1 Real-Time Live Speech Streaming Pipeline

#### WebSocket Client Specification:
* **Endpoint**: `wss://aadeshai.xyz/dream-ai/ws/stream` (or `wss://<host>/ws/stream`)
* **Transport**: Native `URLSessionWebSocketTask`
* **Heartbeat & Reconnect**:
  * Pings every 25 seconds to keep connection alive through Caddy proxy.
  * Exponential backoff reconnection (1s, 2s, 4s, 8s, up to 30s) if connection drops.
* **Message Format**:
  ```json
  {
    "type": "transcript",
    "data": {
      "time": "14:32:05",
      "timestamp": "2026-10-18T14:32:05.123456",
      "speaker": "Speaker",
      "text": "We need to ensure the decisions block updates automatically.",
      "source": "omi_app",
      "uid": "iphone_user"
    }
  }
  ```
* **Fallback Mode**: If WebSocket is unreachable due to cellular network firewalls, the app automatically falls back to lightweight polling on `GET /dream-ai/api/transcripts?limit=15` every 2.5 seconds.

---

### 5.2 "The Verdict" - Decisions Aggregation Engine

#### Server Endpoint Specification:
To avoid parsing through dozens of separate summary records on the mobile phone, a dedicated aggregation endpoint is added to the server:

* **Route**: `GET /omi/api/decisions/today`
* **Query Parameters**: `timezone=Asia/Kolkata` (or client local timezone)
* **Response Schema**:
  ```json
  {
    "date": "2026-10-18",
    "total_decisions": 4,
    "decisions": [
      {
        "id": "dec_1792183191_1",
        "time": "20:39:51",
        "title": "Data Loading Strategy",
        "decision": "Agreed to implement resilient element-by-element JSON decoding",
        "context_summary": "Resolved issue where older archive records without date caused decode failure.",
        "category": "technical",
        "status": "pending_action"
      },
      {
        "id": "dec_1792182449_1",
        "time": "20:27:29",
        "title": "Personalization Alignment",
        "decision": "Decided to personalize the AI summary directly for Anup in the second person",
        "context_summary": "Updated Qwen prompt to address Anup directly with high-signal briefings.",
        "category": "product",
        "status": "completed"
      }
    ]
  }
  ```

#### Local Offline Caching:
* Decisions are cached locally in `Application Support/Cache/decisions_today.json`.
* Tapping a decision allows Anup to mark it as acknowledged or completed, persisting the state locally.

---

## 6. Implementation Roadmap & Execution Checklist

### Phase 1: Foundation, Theming & Model Updates
- [x] Implement `ThemeManager` in Swift supporting System / Light / Dark modes.
- [x] Define semantic color tokens (`AppColors`) and typography styles (`AppTypography`).
- [x] Add `GET /omi/api/decisions/today` endpoint to `omi_server.py`.
- [x] Deploy updated server to droplet and verify endpoint with curl.

### Phase 2: Real-Time Live Speech Engine
- [x] Create `LiveSpeechService.swift` using `URLSessionWebSocketTask`.
- [x] Build `WaveformVisualizerView.swift` for animated audio level visualization.
- [x] Implement `LiveSpeechCard.swift` with real-time text streaming and auto-scroll.
- [x] Add full-screen transcript modal sheet.

### Phase 3: "The Verdict" (Decisions Ledger) Block
- [ ] Create `DecisionsView.swift` and `DecisionCard.swift` with emerald checkmark styling.
- [ ] Add interactive acknowledgement toggle and local persistence.
- [ ] Integrate decisions block into the primary "Today" screen.

### Phase 4: Product-Oriented "Today" Home Dashboard
- [ ] Refactor root navigation into a clean modern `TabView`:
  - Tab 1: **Today** (`TodayView` with Live Speech, Decisions, Day Briefing, Actions).
  - Tab 2: **Timeline** (`TimelineView` grouped by conversation session).
  - Tab 3: **Device** (`GatewayView` containing 100% of preserved engineering features).
- [ ] Add dynamic time-based greeting for Anup.
- [ ] Implement pull-to-refresh across all tabs.

### Phase 5: Polish, Haptics & Verification
- [ ] Add haptic feedback for user interactions (`UIImpactFeedbackGenerator`).
- [ ] Test end-to-end on iOS Simulator and physical iPhone.
- [ ] Validate zero regression on BLE packet capture, local chunk storage, and live streaming.
- [ ] Run full test suites (`swift test`, `validate.sh`, `pytest`).

---

## 7. Guidelines for Autonomous Agents Implementing this Plan
1. **Never break the BLE capture loop or ChunkStore**: The raw 16 kHz audio recording and local chunk archival are mission-critical. Do not modify `ChunkStore.swift` or `PendantReceiver.swift` packet ingestion logic.
2. **Never use the em dash**: Use a plain dash `-` instead, as specified in global instructions.
3. **Keep GatewayView fully accessible**: The user explicitly requested that all existing diagnostic, chunk inspection, and logging screens remain intact. Place them in the dedicated "Device" tab or settings sheet.
4. **Resilient Network Code**: All network decoders must be resilient to optional or missing fields from historical data. Never let a single corrupted record crash the entire feed.
5. **Always test in an E2E environment**: Verify live curl responses from the server before finalizing iOS network client code.
