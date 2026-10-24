import Foundation

/// Optional firmware KTP1 characteristic; all counters belong to one boot.
struct TransportDiagnostics {
    let flags: UInt32
    let values: [UInt32]

    init?(_ data: Data) {
        let bytes = Array(data)
        guard bytes.count == 64, Array(bytes.prefix(4)) == Array("KTP1".utf8) else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        flags = u32(4)
        guard flags <= 2 else { return nil }
        values = stride(from: 8, to: 64, by: 4).map(u32)
    }

    var summary: String {
        guard flags != 0 else { return "KTP1: No retained transport snapshot for this boot" }
        let v = values
        return "KTP1 \(flags == 2 ? "previous boot" : "current boot"): captured=\(v[0]) blocks; submitted=\(v[1]), completed=\(v[2]) notifications (host TX, not app ACK); backpressure=\(v[3]); last send error=\(Int32(bitPattern: v[4])); max send call=\(v[5]) µs; queue drops=\(v[6]) blocks; TX drops=\(v[7]) packets; expired=\(v[8]) blocks; mic read errors=\(v[9]); queue=\(v[11])/8, peak=\(v[10]); pool=\(v[12])/10; last completion=\(v[13]) ms uptime"
    }
}
