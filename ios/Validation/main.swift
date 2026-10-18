import Foundation

// Run with Apple's command-line tools; no XCTest or iOS SDK required.
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw GatewayError.message("FAIL: " + message) }
}
func packets(_ url: URL) throws -> [Data] {
    try Data(contentsOf: url).split(separator: 10).dropFirst().map {
        let record = try JSONDecoder().decode(PacketRecord.self, from: Data($0))
        guard let data = Data(base64Encoded: record.packet_b64) else { throw GatewayError.message("Bad base64") }
        return data
    }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("raw-gateway-validation-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let store = try ChunkStore(directory: root.appendingPathComponent("boundaries"))
let source = [Data([255,255,255,255,0,255]), Data([0,0,0,0,0,128,127]), Data([0,0,0,0,0,128,127]), Data([2,0,0,0,0,7]), Data([3])]
for (data, time) in zip(source, [100.0, 100.1, 110, 129.99, 130]) {
    try store.append(data, deviceID: "device", sessionID: "session", sampleRate: 8000, checkpoint: 30, uptime: time)
}
let first = try store.pending()[0]
try check(packets(first) == Array(source.prefix(4)), "30-second boundary and exact byte preservation")
try store.checkpointNow()
let second = try store.pending().first { $0 != first }!
try check(packets(second) == [source[4]], "packet at boundary belongs to next chunk")
var stats = PacketStats()
source.forEach { stats.observe($0) }
try check(stats.gaps == 1 && stats.reordered == 1 && stats.malformed == 1, "sequence wrap, gaps, duplicates, short packet")
let recoveryFolder = root.appendingPathComponent("recovery")
var writer: ChunkStore? = try ChunkStore(directory: recoveryFolder)
try writer?.append(source[0], deviceID: "d", sessionID: "s", sampleRate: 16000, checkpoint: 30, uptime: 0)
writer = nil
let open = try FileManager.default.contentsOfDirectory(at: recoveryFolder, includingPropertiesForKeys: nil)[0]
let file = try FileHandle(forWritingTo: open)
try file.seekToEnd(); try file.write(contentsOf: Data("{torn".utf8)); try file.close()
let recovered = try ChunkStore(directory: recoveryFolder)
let recoveredFile = try recovered.pending()[0]
try check(packets(recoveredFile) == [source[0]], "crash recovery keeps complete packet")
try check(FileManager.default.fileExists(atPath: open.appendingPathExtension("partial").path), "torn tail retained for diagnostics")
let originalHash = try ChunkStore.checksum(recoveredFile)
let reopened = try ChunkStore(directory: recoveryFolder)
try check(reopened.pending() == [recoveredFile], "stable chunk ID across restart")
try check(ChunkStore.checksum(recoveredFile) == originalHash, "stable bytes across restart")
try check(UploadAck.validates(Data(#"{"chunk_id":"a","sha256":"b","stored":true}"#.utf8), id: "a", checksum: "b"), "valid durable acknowledgment")
for bad in [#"{"chunk_id":"a","sha256":"other","stored":true}"#, #"{"chunk_id":"other","sha256":"b","stored":true}"#, #"{"chunk_id":"a","sha256":"b","stored":false}"#, "OK"] {
    try check(!UploadAck.validates(Data(bad.utf8), id: "a", checksum: "b"), "reject unconfirmed uploads")
}
var retry = RetryState()
let now = Date(timeIntervalSince1970: 100)
retry.failed(now: now)
try check(retry.nextAttempt.timeIntervalSince(now) == 2, "initial backoff")
for _ in 0..<30 { retry.failed(now: now) }
let restored = try JSONDecoder().decode(RetryState.self, from: JSONEncoder().encode(retry))
try check(restored.attempts == 31 && restored.nextAttempt == retry.nextAttempt && restored.nextAttempt.timeIntervalSince(now) <= 300, "persisted capped backoff")
// Optional cross-language fixture for the backend contract test.
if let output = ProcessInfo.processInfo.environment["RAW_GATEWAY_FIXTURE"] {
    let fixtureStore = try ChunkStore(directory: root.appendingPathComponent("fixture"))
    try fixtureStore.append(source[0], deviceID: "fixture-device", sessionID: UUID().uuidString.lowercased(), sampleRate: 8000, checkpoint: 30)
    try fixtureStore.checkpointNow()
    try Data(contentsOf: fixtureStore.pending()[0]).write(to: URL(fileURLWithPath: output))
}
print("PASS: byte preservation, 30-second boundaries, sequence diagnostics, crash recovery, stable IDs/checksums, acknowledgment validation, persisted retry backoff")
let descriptorBytes = Data([0x4b,0x53,0x52,0x31,0x80,0x3e,0,0,100,0,1,16,5,1,0,0,0x78,0x56,0x34,0x12])
let descriptor = try StreamDescriptor(descriptorBytes)
try check(descriptor.sampleRate == 16000 && descriptor.blockMilliseconds == 100 && descriptor.bootID == 0x12345678, "firmware descriptor decoded exactly")
for position in [0,4,8,10,11,12,13,14,15] {
    var bad = descriptorBytes; bad[position] ^= 0xff
    var rejected = false
    do { _ = try StreamDescriptor(bad) } catch { rejected = true }
    try check(rejected, "unsupported descriptor field rejected")
}
let formatStore = try ChunkStore(directory: root.appendingPathComponent("format"))
try formatStore.append(source[0], deviceID: "d", sessionID: UUID().uuidString.lowercased(), sampleRate: descriptor.sampleRate, checkpoint: 30, streamInfo: descriptor.raw)
try formatStore.checkpointNow()
let encodedFormat = try Data(contentsOf: formatStore.pending()[0]).split(separator: 10)[0]
let savedHeader = try JSONDecoder().decode(ChunkHeader.self, from: Data(encodedFormat))
try check(savedHeader.sample_rate_hz == 16000 && savedHeader.stream_info_b64 == descriptorBytes.base64EncodedString(), "verified firmware descriptor archived unchanged")
print("PASS: firmware format validation and descriptor preservation in chunk metadata")
