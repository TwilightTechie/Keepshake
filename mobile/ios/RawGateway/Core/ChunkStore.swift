import Foundation
import CryptoKit

public struct ChunkHeader: Codable {
    public var version = 1
    public let chunk_id: String
    public let session_id: String
    public let device_id: String
    public let started_at: String
    public let sample_rate_hz: Int
    public var channels = 1
    public var bits_per_sample = 16
    public var encoding = "pcm_s16le"
    public var packet_format = "keepsake-p0"
    public let checkpoint_seconds: Int
    public var stream_info_b64: String? = nil
    public var delivery_mode: String? = nil
}

public struct PacketRecord: Codable {
    public let received_at: String
    public let elapsed_seconds: Double
    public let packet_b64: String
}

public enum GatewayError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

public struct PacketStats {
    public private(set) var packets = 0
    public private(set) var bytes = 0
    public private(set) var gaps: UInt64 = 0
    public private(set) var reordered = 0
    public private(set) var malformed = 0
    private var expected: UInt32?

    public init() {}
    // Diagnostic only: never filter, modify, or discard received bytes.
    public mutating func observe(_ data: Data) {
        packets += 1
        bytes += data.count
        guard data.count > 5 else { malformed += 1; return }
        let b = Array(data.prefix(4))
        let seq = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        if let expected {
            let delta = seq &- expected
            if delta >= 0x80000000 { reordered += 1; return }
            gaps += UInt64(delta)
        }
        expected = seq &+ 1
    }
}

/// All access is serialized by the app's main queue. No audio decoding happens here.
public final class ChunkStore {
    public let directory: URL
    private var handle: FileHandle?
    private var activeURL: URL?
    private var openedAt: TimeInterval = 0
    private var syncedAt: TimeInterval = 0
    private var packetCount = 0
    private var interval = 30
    private let encoder = JSONEncoder()

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var location = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        try recover()
    }

    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0a)
        return data
    }

    public func append(_ packet: Data, deviceID: String, sessionID: String,
                       sampleRate: Int, checkpoint: Int, streamInfo: Data? = nil,
                       deliveryMode: String? = nil, now: Date = Date(),
                       uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        if handle != nil && uptime - openedAt >= Double(interval) { try checkpointNow() }
        if handle == nil {
            let id = UUID().uuidString.lowercased()
            let url = directory.appendingPathComponent(id + ".open")
            var header = ChunkHeader(chunk_id: id, session_id: sessionID, device_id: deviceID,
                                     started_at: Self.timestamp(now), sample_rate_hz: sampleRate,
                                     checkpoint_seconds: checkpoint, stream_info_b64: streamInfo?.base64EncodedString())
            header.delivery_mode = deliveryMode
            try line(header).write(to: url, options: .atomic)
            handle = try FileHandle(forWritingTo: url)
            try handle?.seekToEnd()
            activeURL = url
            openedAt = uptime
            syncedAt = uptime
            interval = checkpoint
            packetCount = 0
        }
        let record = PacketRecord(received_at: Self.timestamp(now),
                                  elapsed_seconds: max(0, uptime - openedAt),
                                  packet_b64: packet.base64EncodedString())
        do {
            try handle?.write(contentsOf: line(record))
        } catch {
            // A failed write may leave a torn final line. Keep this file as .open
            // for recovery; never submit it as a complete upload.
            try? handle?.close()
            handle = nil
            activeURL = nil
            throw error
        }
        packetCount += 1
        // Bound unsynced data to approximately one second, without fsync per BLE packet.
        if uptime - syncedAt >= 1 { try handle?.synchronize(); syncedAt = uptime }
    }

    public func checkpointIfDue(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        if handle != nil && uptime - openedAt >= Double(interval) { try checkpointNow() }
    }

    public func checkpointNow() throws {
        guard let url = activeURL else { return }
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        if packetCount > 0 {
            try FileManager.default.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("jsonl"))
        } else { try FileManager.default.removeItem(at: url) }
        activeURL = nil
    }

    public func pending() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.pathExtension == "jsonl" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
            }
    }

    public func storageBytes() throws -> Int64 {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { try $0 + Int64($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }

    /// Recover only complete JSONL records after an interrupted write. A torn final record
    /// cannot be reconstructed; keep it separately for diagnostics, never invent PCM.
    private func recover() throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.pathExtension == "open" {
            let data = try Data(contentsOf: url)
            guard let end = data.lastIndex(of: 0x0a) else {
                throw GatewayError.message("Unrecoverable capture file: \(url.lastPathComponent)")
            }
            let complete = Data(data[...end])
            if end + 1 < data.count {
                try Data(data[(end + 1)...]).write(to: url.appendingPathExtension("partial"), options: .atomic)
            }
            let lines = complete.split(separator: 0x0a)
            guard let first = lines.first else { continue }
            _ = try JSONDecoder().decode(ChunkHeader.self, from: Data(first))
            for row in lines.dropFirst() { _ = try JSONDecoder().decode(PacketRecord.self, from: Data(row)) }
            if lines.count > 1 {
                try complete.write(to: url.deletingPathExtension().appendingPathExtension("jsonl"), options: .atomic)
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    public static func checksum(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    public static func deliveryMode(_ file: URL) throws -> String? {
        let source = try FileHandle(forReadingFrom: file)
        defer { try? source.close() }
        guard let data = try source.read(upToCount: 2048), let end = data.firstIndex(of: 0x0a) else {
            throw GatewayError.message("Checkpoint header is incomplete")
        }
        return try JSONDecoder().decode(ChunkHeader.self, from: data[..<end]).delivery_mode
    }

    public func prune(archiveOnly: Bool = false) throws -> Int {
        let files = try pending()
        var deleted = 0
        for file in files {
            if archiveOnly {
                let mode = try? Self.deliveryMode(file)
                if mode == "checkpoint" { continue }
            }
            try? FileManager.default.removeItem(at: file)
            let retry = file.deletingPathExtension().appendingPathExtension("retry")
            try? FileManager.default.removeItem(at: retry)
            deleted += 1
        }
        return deleted
    }

    deinit { try? handle?.close() }
}

public struct UploadAck: Decodable {
    public let chunk_id: String
    public let sha256: String
    public let stored: Bool
    public static func validates(_ data: Data, id: String, checksum: String) -> Bool {
        guard let ack = try? JSONDecoder().decode(Self.self, from: data) else { return false }
        return ack.stored && ack.chunk_id == id && ack.sha256 == checksum
    }
}

public struct RetryState: Codable {
    public var attempts = 0
    public var nextAttempt = Date.distantPast
    public init() {}
    public mutating func failed(now: Date = Date()) {
        attempts += 1
        nextAttempt = now.addingTimeInterval(min(300, pow(2, Double(min(attempts, 8)))))
    }
}

/// Firmware's 20-byte read-only descriptor. No guessing about sample rate.
public struct StreamDescriptor {
    public let sampleRate: Int
    public let blockMilliseconds: Int
    public let bootID: UInt32
    public let raw: Data
    public init(_ data: Data) throws {
        let b = Array(data)
        guard b.count == 20, Array(b[0..<4]) == Array("KSR1".utf8),
              b[10] == 1, b[11] == 16, b[12] == 5, b[13] == 1,
              b[14] == 0, b[15] == 0 else {
            throw GatewayError.message("Unsupported firmware stream descriptor. Use the matching Keepsake raw firmware.")
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(b[offset]) | UInt32(b[offset+1]) << 8 | UInt32(b[offset+2]) << 16 | UInt32(b[offset+3]) << 24
        }
        sampleRate = Int(u32(4))
        blockMilliseconds = Int(b[8]) | Int(b[9]) << 8
        guard sampleRate == 16000, blockMilliseconds == 100 else {
            throw GatewayError.message("Unsupported firmware audio rate/block size; update the app and firmware together.")
        }
        bootID = u32(16)
        raw = data
    }
}
