import XCTest
@testable import RawGatewayCore

final class TransportDiagnosticsTests: XCTestCase {
    func snapshot(flags: UInt32 = 1) -> Data {
        var data = Data("KTP1".utf8)
        for number in [flags] + (0..<14).map({ UInt32($0) }) {
            var little = number.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testLiveAndRetainedCountersAndSignedError() throws {
        var data = snapshot()
        // Firmware uses signed errno in the little-endian 32-bit field at byte 24.
        data.replaceSubrange(24..<28, with: [0xf4, 0xff, 0xff, 0xff]) // -ENOMEM = -12
        let decoded = try XCTUnwrap(TransportDiagnostics(data))
        XCTAssertEqual(decoded.values.count, 14)
        XCTAssertTrue(decoded.summary.contains("last send error=-12"))
        XCTAssertTrue(decoded.summary.contains("last completion=13 ms"))
        XCTAssertTrue(decoded.summary.contains("queue=11/8, peak=10"))
        XCTAssertTrue(try XCTUnwrap(TransportDiagnostics(snapshot(flags: 2))).summary.contains("previous boot"))
        XCTAssertTrue(try XCTUnwrap(TransportDiagnostics(snapshot(flags: 0))).summary.contains("No retained"))
    }

    func testRejectTruncatedUnknownAndWrongVersion() {
        XCTAssertNil(TransportDiagnostics(snapshot().dropLast()))
        XCTAssertNil(TransportDiagnostics(snapshot(flags: 3)))
        var wrong = snapshot(); wrong[3] = 50
        XCTAssertNil(TransportDiagnostics(wrong))
    }
}
