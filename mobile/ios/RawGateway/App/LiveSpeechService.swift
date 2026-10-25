import Foundation
import Combine

// MARK: - Transcript Entry Model

struct TranscriptEntry: Identifiable, Codable, Equatable {
    let id: String
    let time: String
    let timestamp: String?
    let speaker: String
    let text: String
    let language: String?
    let source: String?
    let duration_sec: Double?

    init(
        id: String? = nil,
        time: String = "",
        timestamp: String? = nil,
        speaker: String = "Speaker",
        text: String = "",
        language: String? = nil,
        source: String? = nil,
        duration_sec: Double? = nil
    ) {
        let baseId = id ?? UUID().uuidString
        self.id = baseId
        self.time = time
        self.timestamp = timestamp
        self.speaker = speaker
        self.text = text
        self.language = language
        self.source = source
        self.duration_sec = duration_sec
    }

    enum CodingKeys: String, CodingKey {
        case id
        case time
        case timestamp
        case speaker
        case text
        case transcript
        case language
        case source
        case duration_sec
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let t = (try? container.decode(String.self, forKey: .text))
            ?? (try? container.decode(String.self, forKey: .transcript))
            ?? ""
        self.text = t

        self.time = (try? container.decode(String.self, forKey: .time)) ?? ""
        self.timestamp = try? container.decode(String.self, forKey: .timestamp)
        self.speaker = (try? container.decode(String.self, forKey: .speaker)) ?? "Speaker"
        self.language = try? container.decode(String.self, forKey: .language)
        self.source = try? container.decode(String.self, forKey: .source)
        self.duration_sec = try? container.decode(Double.self, forKey: .duration_sec)

        if let explicitId = try? container.decode(String.self, forKey: .id) {
            self.id = explicitId
        } else {
            let key = (self.timestamp ?? self.time) + self.text
            self.id = key.isEmpty ? UUID().uuidString : String(key.hashValue)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(time, forKey: .time)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encode(speaker, forKey: .speaker)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(duration_sec, forKey: .duration_sec)
    }

    var isCheckpoint: Bool {
        source == "sarvam_checkpoint"
    }

    var displaySource: String {
        if isCheckpoint { return "30s Checkpoint" }
        if source == "sarvam" { return "Sarvam Saaras" }
        return "Ambient"
    }
}

// MARK: - WebSocket Message Payloads

private struct WSInitPayload: Decodable {
    let type: String
    let status: String?
    let model: String?
}

private struct WSTranscriptPayload: Decodable {
    let type: String
    let data: TranscriptEntry?
}

// MARK: - Live Speech Service

final class LiveSpeechService: ObservableObject {
    @Published var transcripts: [TranscriptEntry] = []
    @Published var isConnected = false
    @Published var connectionStatus = "Connecting..."
    @Published var isReceivingAudio = false
    @Published var latestUtterance = ""
    @Published var lastSpeechTime: Date? = nil

    private let settings: Settings
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession
    private var pingTimer: Timer?
    private var pollTimer: Timer?
    private var reconnectAttempt = 0
    private var isIntentionalDisconnect = false
    private var seenKeys = Set<String>()

    init(settings: Settings) {
        self.settings = settings
        self.session = URLSession(configuration: .default)
        DispatchQueue.main.async { [weak self] in
            self?.start()
        }
    }

    deinit {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        pingTimer?.invalidate()
        pollTimer?.invalidate()
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    // MARK: - Lifecycle

    func start() {
        runOnMain {
            self.isIntentionalDisconnect = false
            self.reconnectAttempt = 0
            self.connectWebSocket()
            self.loadInitialHistory()
            self.startPingTimer()
            self.startFallbackPollTimer()
        }
    }

    func stop() {
        runOnMain {
            self.isIntentionalDisconnect = true
            self.pingTimer?.invalidate()
            self.pingTimer = nil
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            self.webSocketTask?.cancel(with: .normalClosure, reason: nil)
            self.webSocketTask = nil
            self.isConnected = false
            self.connectionStatus = "Disconnected"
        }
    }

    func clearTranscripts() {
        runOnMain {
            self.transcripts.removeAll()
            self.seenKeys.removeAll()
            self.latestUtterance = ""
        }
    }

    // MARK: - URL Derivation

    private var wsURL: URL? {
        guard let httpURL = URL(string: settings.dreamAIWebhook.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = httpURL.host else {
            return URL(string: "wss://aadeshai.xyz/dream-ai/ws/stream")
        }
        var comp = URLComponents()
        comp.scheme = httpURL.scheme == "http" ? "ws" : "wss"
        comp.host = host
        comp.port = httpURL.port
        comp.path = "/dream-ai/ws/stream"
        return comp.url
    }

    private var restBaseURL: String {
        if let url = URL(string: settings.dreamAIWebhook.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = url.scheme,
           let host = url.host {
            let portStr = url.port != nil ? ":\(url.port!)" : ""
            return "\(scheme)://\(host)\(portStr)"
        }
        return "https://aadeshai.xyz"
    }

    // MARK: - Initial History

    func loadInitialHistory() {
        Task {
            guard let url = URL(string: "\(restBaseURL)/dream-ai/api/transcripts?limit=40") else { return }
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 8.0
                let (data, resp) = try await session.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
                let items = try JSONDecoder().decode([TranscriptEntry].self, from: data)
                let chronological = Array(items.reversed())
                runOnMain {
                    for item in chronological {
                        self.appendEntry(item)
                    }
                }
            } catch {
                // Initial history load is non-fatal; WebSocket continues
            }
        }
    }

    // MARK: - WebSocket Management

    private func connectWebSocket() {
        guard !isIntentionalDisconnect else { return }
        guard let url = wsURL else {
            connectionStatus = "Invalid WS URL"
            return
        }

        connectionStatus = "Connecting..."
        webSocketTask?.cancel(with: .goingAway, reason: nil)

        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        listenForMessages(on: task)
    }

    private func listenForMessages(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self = self, let task = task else { return }
            self.runOnMain {
                guard self.webSocketTask === task else { return }
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    self.listenForMessages(on: task)
                case .failure(let error):
                    self.handleDisconnect(error)
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let rawData: Data?
        switch message {
        case .string(let text):
            rawData = text.data(using: .utf8)
        case .data(let data):
            rawData = data
        @unknown default:
            rawData = nil
        }

        guard let data = rawData else { return }

        // Check for init message
        if let initMsg = try? JSONDecoder().decode(WSInitPayload.self, from: data), initMsg.type == "init" {
            isConnected = true
            connectionStatus = "Live (WebSocket)"
            reconnectAttempt = 0
            return
        }

        // Check for transcript message
        if let payload = try? JSONDecoder().decode(WSTranscriptPayload.self, from: data),
           payload.type == "transcript",
           let entry = payload.data {
            isConnected = true
            connectionStatus = "Live (WebSocket)"
            appendEntry(entry)
            isReceivingAudio = true
            lastSpeechTime = Date()
            latestUtterance = entry.text
            reconnectAttempt = 0

            // Pulse receiving state for 2 seconds
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.runOnMain {
                    if let last = self.lastSpeechTime, Date().timeIntervalSince(last) >= 2.0 {
                        self.isReceivingAudio = false
                    }
                }
            }
        }
    }

    private func appendEntry(_ entry: TranscriptEntry) {
        let key = (entry.timestamp ?? entry.time) + entry.text
        guard !key.isEmpty, !seenKeys.contains(key) else { return }
        seenKeys.insert(key)
        transcripts.append(entry)
        if transcripts.count > 150 {
            let countToRemove = 30
            let removed = Array(transcripts.prefix(countToRemove))
            transcripts.removeFirst(countToRemove)
            for r in removed { seenKeys.remove((r.timestamp ?? r.time) + r.text) }
        }
    }

    private func handleDisconnect(_ error: Error) {
        guard !isIntentionalDisconnect else { return }
        isConnected = false
        connectionStatus = "Reconnecting..."
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 5))))
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.runOnMain {
                guard !self.isIntentionalDisconnect, !self.isConnected else { return }
                self.connectWebSocket()
            }
        }
    }

    // MARK: - Timers

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isConnected, let task = self.webSocketTask else { return }
            task.sendPing { [weak self] error in
                if let error = error {
                    self?.runOnMain {
                        self?.handleDisconnect(error)
                    }
                }
            }
        }
    }

    private func startFallbackPollTimer() {
        pollTimer?.invalidate()
        // If WebSocket is disconnected for > 6 seconds, fetch recent transcripts over HTTP
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { [weak self] _ in
            guard let self = self, !self.isConnected, !self.isIntentionalDisconnect else { return }
            self.pollFallbackTranscripts()
        }
    }

    private func pollFallbackTranscripts() {
        Task {
            guard let url = URL(string: "\(restBaseURL)/dream-ai/api/transcripts?limit=10") else { return }
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 3.0
                let (data, resp) = try await session.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
                let items = try JSONDecoder().decode([TranscriptEntry].self, from: data)
                let chronological = Array(items.reversed())
                self.runOnMain {
                    for item in chronological {
                        self.appendEntry(item)
                    }
                }
            } catch {
                // Fallback poll failure is non-fatal
            }
        }
    }
}
