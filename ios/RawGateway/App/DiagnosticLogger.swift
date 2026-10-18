import Foundation

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
    func generateReport(receiverStatus: String, deviceName: String, streamDesc: String, stats: PacketStats, storageMB: Double, pendingChunks: Int, uploaderStatus: String) -> String {
        let header = """
        === KEEPSAKE DIAGNOSTIC REPORT ===
        Generated: \(Self.timestamp(Date()))
        Device: \(deviceName)
        Connection: \(receiverStatus)
        Audio Format: \(streamDesc)
        Packets Received: \(stats.packets)
        Bytes Received: \(stats.bytes)
        Sequence Gaps: \(stats.gaps)
        Malformed / Out of Order: \(stats.malformed + stats.reordered)
        Local Storage: \(String(format: "%.2f MB", storageMB))
        Upload Queue: \(pendingChunks) chunks
        Uploader State: \(uploaderStatus)
        ==================================
        """
        info("User triggered diagnostic report: \(stats.packets) pkts, \(stats.gaps) gaps, \(pendingChunks) pending", category: "report")
        return header + "\n\n" + exportAllFiles()
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
