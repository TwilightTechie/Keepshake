import XCTest
@testable import RawGatewayCore

final class ChunkStoreTests: XCTestCase {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func packets(_ url: URL) throws -> [Data] {
        try Data(contentsOf: url).split(separator: 10).dropFirst().map {
            let record = try JSONDecoder().decode(PacketRecord.self, from: Data($0))
            return try XCTUnwrap(Data(base64Encoded: record.packet_b64))
        }
    }

    func testThirtySecondBoundaryPreservesEveryPacketIncludingOddLengths() throws {
        let store = try ChunkStore(directory: directory())
        let raw = [Data([0,0,0,0,0,0xff]), Data([1,0,0,0,0,0x80,0,0x7f]), Data([2,0,0,0,0,1])]
        for (packet, time) in zip(raw, [100.0, 129.9, 130.0]) {
            try store.append(packet, deviceID: "device", sessionID: "session", sampleRate: 8000, checkpoint: 30, uptime: time)
        }
        let first = try XCTUnwrap(store.pending().first)
        XCTAssertEqual(try packets(first), Array(raw.prefix(2)))
        try store.checkpointNow()
        let second = try XCTUnwrap(store.pending().first { $0 != first })
        XCTAssertEqual(try packets(second), [raw[2]])
    }

    func testCrashRecoveryKeepsCompletePacketsAndQuarantinesTornTail() throws {
        let folder = try directory()
        var store: ChunkStore? = try ChunkStore(directory: folder)
        let raw = Data([0,0,0,0,0,42])
        try store?.append(raw, deviceID: "device", sessionID: "session", sampleRate: 16000, checkpoint: 30, uptime: 0)
        store = nil
        let open = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let file = try FileHandle(forWritingTo: open)
        try file.seekToEnd(); try file.write(contentsOf: Data("{torn".utf8)); try file.close()
        let recovered = try ChunkStore(directory: folder)
        let pending = try XCTUnwrap(recovered.pending().first)
        XCTAssertEqual(try packets(pending), [raw])
        let hash = try ChunkStore.checksum(pending)
        let reopened = try ChunkStore(directory: folder)
        XCTAssertEqual(try reopened.pending(), [pending])
        XCTAssertEqual(try ChunkStore.checksum(pending), hash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: open.appendingPathExtension("partial").path))
    }

    func testDiagnosticsDoNotRemoveDuplicateOrMalformedPackets() throws {
        let store = try ChunkStore(directory: directory())
        let raw = [Data([255,255,255,255,0,1]), Data([0,0,0,0,0,2]), Data([0,0,0,0,0,2]), Data([2,0,0,0,0,3]), Data([9])]
        var stats = PacketStats()
        for packet in raw {
            stats.observe(packet)
            try store.append(packet, deviceID: "d", sessionID: "s", sampleRate: 8000, checkpoint: 30)
        }
        try store.checkpointNow()
        XCTAssertEqual(stats.gaps, 1)
        XCTAssertEqual(stats.reordered, 1)
        XCTAssertEqual(stats.malformed, 1)
        XCTAssertEqual(try packets(XCTUnwrap(store.pending().first)), raw)
    }

    func testAckRequiresMatchingIDChecksumAndDurableFlag() {
        XCTAssertTrue(UploadAck.validates(Data(#"{"chunk_id":"a","sha256":"b","stored":true}"#.utf8), id: "a", checksum: "b"))
        for body in [#"{"chunk_id":"a","sha256":"wrong","stored":true}"#, #"{"chunk_id":"other","sha256":"b","stored":true}"#, #"{"chunk_id":"a","sha256":"b","stored":false}"#, "OK"] {
            XCTAssertFalse(UploadAck.validates(Data(body.utf8), id: "a", checksum: "b"))
        }
    }

    func testRetrySurvivesSerializationAndCapsDelay() throws {
        var state = RetryState()
        let now = Date(timeIntervalSince1970: 100)
        state.failed(now: now)
        XCTAssertEqual(state.nextAttempt.timeIntervalSince(now), 2)
        for _ in 0..<30 { state.failed(now: now) }
        XCTAssertLessThanOrEqual(state.nextAttempt.timeIntervalSince(now), 300)
        let restored = try JSONDecoder().decode(RetryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.attempts, state.attempts)
        XCTAssertEqual(restored.nextAttempt, state.nextAttempt)
    }
}

final class StreamDescriptorTests: XCTestCase {
    func testNativeFirmwareContractAndRejectedLegacyGuess() throws {
        let bytes = Data([0x4b,0x53,0x52,0x31,0x80,0x3e,0,0,100,0,1,16,5,1,0,0,0x78,0x56,0x34,0x12])
        let descriptor = try StreamDescriptor(bytes)
        XCTAssertEqual(descriptor.sampleRate, 16000)
        XCTAssertEqual(descriptor.bootID, 0x12345678)
        XCTAssertEqual(descriptor.raw, bytes)
        XCTAssertThrowsError(try StreamDescriptor(Data()))
        for position in [0,4,8,10,11,12,13,14,15] {
            var bad = bytes; bad[position] ^= 0xff
            XCTAssertThrowsError(try StreamDescriptor(bad))
        }
    }
}
