import Foundation

// Minimal Protocol Buffers wire-format reader/writer — just enough for the Nearby Share messages.
// Field numbers come from Google's Apache-2.0 .proto files (google/nearby, google/ukey2).

struct PBWriter {
    private(set) var data = Data()

    mutating func varint(_ v: UInt64) {
        var v = v
        while v >= 0x80 { data.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }
    private mutating func key(_ field: Int, _ wire: Int) { varint(UInt64(field << 3 | wire)) }

    mutating func int(_ field: Int, _ v: Int64?) {
        guard let v else { return }
        key(field, 0); varint(UInt64(bitPattern: v))
    }
    mutating func int(_ field: Int, _ v: Int) { int(field, Int64(v)) }
    mutating func bool(_ field: Int, _ v: Bool) { key(field, 0); varint(v ? 1 : 0) }
    mutating func bytes(_ field: Int, _ v: Data?) {
        guard let v else { return }
        key(field, 2); varint(UInt64(v.count)); data.append(v)
    }
    mutating func string(_ field: Int, _ v: String?) { bytes(field, v.map { Data($0.utf8) }) }
    mutating func message(_ field: Int, _ m: PBWriter?) { bytes(field, m?.data) }

    static func build(_ f: (inout PBWriter) -> Void) -> PBWriter { var w = PBWriter(); f(&w); return w }
}

enum PBError: Error { case truncated, badWireType }

struct PBMessage {
    enum Value { case varint(UInt64), bytes(Data), fixed32(UInt32), fixed64(UInt64) }
    private(set) var fields: [Int: [Value]] = [:]

    init(_ data: Data) throws {
        let b = [UInt8](data)
        var i = 0
        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard i < b.count, shift < 64 else { throw PBError.truncated }
                let byte = b[i]; i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }
        while i < b.count {
            let k = try readVarint()
            let field = Int(k >> 3), wire = Int(k & 7)
            let value: Value
            switch wire {
            case 0: value = .varint(try readVarint())
            case 1:
                guard i + 8 <= b.count else { throw PBError.truncated }
                var v: UInt64 = 0; for j in 0..<8 { v |= UInt64(b[i + j]) << (8 * UInt64(j)) }; i += 8
                value = .fixed64(v)
            case 2:
                let n = Int(try readVarint())
                guard n >= 0, i + n <= b.count else { throw PBError.truncated }
                value = .bytes(Data(b[i..<i + n])); i += n
            case 5:
                guard i + 4 <= b.count else { throw PBError.truncated }
                var v: UInt32 = 0; for j in 0..<4 { v |= UInt32(b[i + j]) << (8 * UInt32(j)) }; i += 4
                value = .fixed32(v)
            default: throw PBError.badWireType
            }
            fields[field, default: []].append(value)
        }
    }

    func int(_ f: Int) -> Int64? {
        guard let v = fields[f]?.last else { return nil }
        switch v {
        case .varint(let x): return Int64(bitPattern: x)
        case .fixed64(let x): return Int64(bitPattern: x)
        case .fixed32(let x): return Int64(Int32(bitPattern: x))
        case .bytes: return nil
        }
    }
    func bool(_ f: Int) -> Bool { (int(f) ?? 0) != 0 }
    func data(_ f: Int) -> Data? {
        if case .bytes(let d)? = fields[f]?.last { return d }
        return nil
    }
    func string(_ f: Int) -> String? { data(f).map { String(decoding: $0, as: UTF8.self) } }
    func message(_ f: Int) -> PBMessage? { data(f).flatMap { try? PBMessage($0) } }
    func messages(_ f: Int) -> [PBMessage] {
        (fields[f] ?? []).compactMap { if case .bytes(let d) = $0 { return try? PBMessage(d) }; return nil }
    }
}

extension Data {
    func base64URL() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    init?(base64URL s: String) {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        self.init(base64Encoded: t)
    }
    static func random(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }
}
