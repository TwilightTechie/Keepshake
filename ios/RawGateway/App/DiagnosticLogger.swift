import Foundation
import Combine

struct VADSnapshot: Decodable {
    struct GateSettings: Decodable {
        let speechProbabilityThreshold: Double
        let minimumSpeechMs: Int
        let silencePeakRMS: Int
        let noiseReduction: String
        enum CodingKeys: String, CodingKey {
            case speechProbabilityThreshold = "speech_probability_threshold"
            case minimumSpeechMs = "minimum_speech_ms"
            case silencePeakRMS = "silence_peak_100ms_rms_pcm16"
            case noiseReduction = "noise_reduction"
        }
    }
    struct Counts: Decodable {
        let evaluated: Int
        let passed: Int
        let droppedSilence: Int
        let droppedNoSpeech: Int
        let errors: Int
        let noiseReduced: Int
        enum CodingKeys: String, CodingKey {
            case evaluated, passed, errors
            case droppedSilence = "dropped_silence"
            case droppedNoSpeech = "dropped_no_speech"
            case noiseReduced = "noise_reduced"
        }
    }
    struct Event: Decodable {
        let timestamp: String
        let path: String
        let decision: String
        let reason: String
        let durationMs: Int
        let speechMs: Int
        let noiseReduced: Bool
        let peakProbability: Double
        enum CodingKeys: String, CodingKey {
            case timestamp, path, decision, reason
            case durationMs = "duration_ms"
            case speechMs = "speech_ms"
            case noiseReduced = "noise_reduced"
            case peakProbability = "peak_probability"
        }
    }
    let model: String
    let ready: Bool
    let startedAt: String?
    let error: String?
    let counters: Counts?
    let byPath: [String: Counts]?
    let settings: GateSettings?
    let recent: [Event]
    enum CodingKeys: String, CodingKey {
        case model, ready, error, counters, recent, settings
        case startedAt = "started_at"
        case byPath = "by_path"
    }
}

@MainActor
final class ServerVADDiagnostics: ObservableObject {
    @Published private(set) var snapshot: VADSnapshot?
    @Published private(set) var status = "Not fetched"
    @Published private(set) var lastUpdated: Date?

    func refresh(settings: Settings) async {
        guard let webhook = URLComponents(string: settings.dreamAIWebhook),
              webhook.scheme?.lowercased() == "https", webhook.host != nil,
              var endpoint = URLComponents(string: settings.dreamAIWebhook) else {
            status = "Configure an HTTPS Dream AI server"
            return
        }
        endpoint.path = "/dream-ai/api/vad/diagnostics"
        endpoint.query = nil
        endpoint.fragment = nil
        guard let url = endpoint.url else {
            status = "Invalid server URL"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        if !settings.webhookToken.isEmpty {
            request.setValue("Bearer \(settings.webhookToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                status = code == 401 ? "Server rejected the webhook token" : "Server returned HTTP \(code)"
                return
            }
            let value = try JSONDecoder().decode(VADSnapshot.self, from: data)
            snapshot = value
            lastUpdated = Date()
            status = value.ready ? "Running" : "Unavailable: \(value.error ?? "unknown error")"
        } catch {
            status = "Could not fetch VAD: \(error.localizedDescription)"
        }
    }

    var reportText: String {
        guard let snapshot else { return "VAD: \(status)" }
        var lines = ["VAD: \(status)", "VAD Model: \(snapshot.model)",
                     "VAD Server Started: \(snapshot.startedAt ?? "unknown")"]
        if let counters = snapshot.counters {
            lines.append("VAD Total: \(counters.evaluated) evaluated, \(counters.passed) passed, " +
                         "\(counters.droppedSilence) silence drops, \(counters.droppedNoSpeech) no-speech drops, " +
                         "\(counters.errors) errors, \(counters.noiseReduced) noise reduced")
        }
        if let settings = snapshot.settings {
            lines.append("VAD Thresholds: probability \(settings.speechProbabilityThreshold), " +
                         "minimum speech \(settings.minimumSpeechMs)ms, silence RMS \(settings.silencePeakRMS), " +
                         "noise reduction \(settings.noiseReduction)")
        }
        for path in ["live", "checkpoint"] {
            if let counts = snapshot.byPath?[path] {
                lines.append("VAD \(path): \(counts.passed) passed / \(counts.evaluated) evaluated; " +
                             "\(counts.droppedSilence + counts.droppedNoSpeech) dropped")
            }
        }
        for event in snapshot.recent.prefix(10) {
            lines.append("VAD Event: \(event.timestamp) \(event.path) \(event.decision) " +
                         "\(event.reason) speech=\(event.speechMs)ms/\(event.durationMs)ms " +
                         "peak=\(event.peakProbability) noise=\(event.noiseReduced)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Thread-safe, file-based diagnostic logger.
/// Writes timestamped JSONL entries to Application Support / Diagnostics.
/// Auto-purges entries and files older than 3 days.
final class DiagnosticLogger: ObservableObject {
    @Published var entries: [LogEntry] = []
    @Published var logFileSize: Int64 = 0

    private let directory: URL
    private let maxAgeDays = 3
    private var handle: FileHandle?
    private var currentFile: URL?
    private let queue = DispatchQueue(label: "DiagnosticLogger", qos: .utility)
    private let encoder = JSONEncoder()

    struct LogEntry: Identifiable, Codable {
        var id: String { "\(timestamp)-\(category)-\(message.prefix(40))" }
        let timestamp: String
        let category: String
        let message: String
        let level: String  // info, warning, error

        enum CodingKeys: String, CodingKey {
            case timestamp, category, message, level
        }
    }

    init() {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        directory = (base ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        purgeOldFiles()
        openCurrentFile()
        loadRecentEntries()
    }

    // MARK: - Public API

    func log(_ message: String, category: String = "general", level: String = "info") {
        let entry = LogEntry(
            timestamp: Self.timestamp(Date()),
            category: category,
            message: message,
            level: level
        )
        queue.async { [weak self] in
            self?.write(entry)
        }
        DispatchQueue.main.async { [weak self] in
            self?.entries.append(entry)
            // Keep only last 200 entries in memory
            if let count = self?.entries.count, count > 200 {
                self?.entries.removeFirst(count - 200)
            }
        }
    }

    func info(_ message: String, category: String = "general") {
        log(message, category: category, level: "info")
    }

    func warning(_ message: String, category: String = "general") {
        log(message, category: category, level: "warning")
    }

    func error(_ message: String, category: String = "general") {
        log(message, category: category, level: "error")
    }

    /// Returns all log text suitable for copying to clipboard.
    func exportLogs() -> String {
        entries.map { "[\($0.timestamp)] [\($0.level.uppercased())] [\($0.category)] \($0.message)" }
            .joined(separator: "\n")
    }

    /// Reads all log files and returns combined text (for full export).
    func exportAllFiles() -> String {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.creationDateKey])
            .filter({ $0.pathExtension == "jsonl" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return "" }
        var lines: [String] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: "\n") where !line.isEmpty {
                if let entry = try? JSONDecoder().decode(LogEntry.self, from: Data(line.utf8)) {
                    lines.append("[\(entry.timestamp)] [\(entry.level.uppercased())] [\(entry.category)] \(entry.message)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Generates a diagnostic system snapshot, logs it, and returns a formatted report.
    @discardableResult
    func generateReport(receiverStatus: String, deviceName: String, streamDesc: String,
                        bootID: UInt32?, rssi: Int?, batteryMillivolts: Int?,
                        firmwareDiagnostics: String, linkDiagnostics: String, resetTrace: String,
        transportDiagnostics: String, previousTransportDiagnostics: String,
                        stats: PacketStats, storageMB: Double, pendingChunks: Int,
                        uploaderStatus: String, vadDiagnostics: String = "VAD: Not fetched") -> String {
        let header = """
        === KEEPSAKE DIAGNOSTIC REPORT ===
        Generated: \(Self.timestamp(Date()))
        Diagnostics Version: BLE transport 3
        Device: \(deviceName)
        Connection: \(receiverStatus)
        Audio Format: \(streamDesc)
        Firmware Boot ID: \(bootID.map { String(format: "0x%08x", $0) } ?? "unknown")
        RSSI: \(rssi.map { "\($0) dBm" } ?? "unknown")
        Battery Voltage: \(batteryMillivolts.map { "\($0) mV" } ?? "unknown")
        Firmware Counters: \(firmwareDiagnostics)
        Link Events: \(linkDiagnostics)
        Reset Trace: \(resetTrace)
        Transport: \(transportDiagnostics)
        Previous Transport: \(previousTransportDiagnostics)
        Packets Received: \(stats.packets)
        Bytes Received: \(stats.bytes)
        Sequence Gaps: \(stats.gaps)
        Malformed / Out of Order: \(stats.malformed + stats.reordered)
        Local Storage: \(String(format: "%.2f MB", storageMB))
        Upload Queue: \(pendingChunks) chunks
        Uploader State: \(uploaderStatus)
        \(vadDiagnostics)
        ==================================
        """
        info("User triggered diagnostic report: \(stats.packets) pkts, \(stats.gaps) gaps, \(pendingChunks) pending", category: "report")
        return header + "\n\n" + exportAllFiles()
    }

    /// Generates a diagnostic report and saves it to a timestamped file for direct sharing.
    func generateReportFile(
        receiverStatus: String, deviceName: String, streamDesc: String,
        bootID: UInt32?, rssi: Int?, batteryMillivolts: Int?,
        firmwareDiagnostics: String, linkDiagnostics: String, resetTrace: String,
        transportDiagnostics: String, previousTransportDiagnostics: String,
        stats: PacketStats, storageMB: Double, pendingChunks: Int,
        uploaderStatus: String, vadDiagnostics: String = "VAD: Not fetched"
    ) -> URL? {
        let report = generateReport(
            receiverStatus: receiverStatus, deviceName: deviceName, streamDesc: streamDesc,
            bootID: bootID, rssi: rssi, batteryMillivolts: batteryMillivolts,
            firmwareDiagnostics: firmwareDiagnostics, linkDiagnostics: linkDiagnostics,
            resetTrace: resetTrace,
            transportDiagnostics: transportDiagnostics, previousTransportDiagnostics: previousTransportDiagnostics,
            stats: stats, storageMB: storageMB, pendingChunks: pendingChunks,
            uploaderStatus: uploaderStatus, vadDiagnostics: vadDiagnostics
        )
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "keepsake-diag-report-\(formatter.string(from: Date())).txt"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try report.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            self.error("Failed to write report file: \(error.localizedDescription)", category: "report")
            return nil
        }
    }

    func refreshFileSize() {
        queue.async { [weak self] in
            guard let self else { return }
            let size = (try? FileManager.default.contentsOfDirectory(at: self.directory,
                includingPropertiesForKeys: [.fileSizeKey])
                .reduce(Int64(0)) { try $0 + Int64($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }) ?? 0
            DispatchQueue.main.async { self.logFileSize = size }
        }
    }

    // MARK: - Private

    private func openCurrentFile() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let name = "diag-\(dateFormatter.string(from: Date())).jsonl"
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
        currentFile = url
    }

    private func write(_ entry: LogEntry) {
        guard let data = try? encoder.encode(entry) else { return }
        var line = data
        line.append(0x0a)
        try? handle?.write(contentsOf: line)
        // Sync every write for diagnostic reliability
        try? handle?.synchronize()
    }

    private func loadRecentEntries() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "jsonl" })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) else { return }
        var loaded: [LogEntry] = []
        for file in files.prefix(2) {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            for line in lines.suffix(100) {
                if let entry = try? JSONDecoder().decode(LogEntry.self, from: Data(line.utf8)) {
                    loaded.append(entry)
                }
            }
        }
        loaded.sort { $0.timestamp < $1.timestamp }
        entries = Array(loaded.suffix(200))
    }

    private func purgeOldFiles() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) ?? Date()
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.creationDateKey]) else { return }
        for file in files {
            guard let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate),
                  created < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    deinit {
        try? handle?.close()
    }
}
