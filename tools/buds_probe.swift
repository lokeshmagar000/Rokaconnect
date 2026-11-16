import Foundation
import IOBluetooth

// READ-ONLY probe: opens the Buds' RFCOMM serial channel and prints whatever the earbuds send. Sends nothing.
func crc16(_ d: [UInt8]) -> UInt16 {
    var c: UInt16 = 0
    for b in d { c ^= UInt16(b) << 8; for _ in 0..<8 { c = (c & 0x8000) != 0 ? (c << 1) ^ 0x1021 : c << 1 } }
    return c
}
final class Probe: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var buf: [UInt8] = []
    func rfcommChannelData(_ c: IOBluetoothRFCOMMChannel!, data p: UnsafeMutableRawPointer!, length l: Int) {
        buf += Array(Data(bytes: p, count: l))
        while let s = buf.firstIndex(of: 0xfd), let e = buf[s...].firstIndex(of: 0xdd), e - s >= 5 {
            let f = Array(buf[s...e]); buf.removeSubrange(0...e)
            let hdr = Int(f[1]) | Int(f[2]) << 8, size = hdr & 0x3ff
            let body = Array(f[3..<(f.count - 1)])                // id + payload + crc
            guard body.count == size, size >= 3 else { print("odd frame", f.count, size); continue }
            let id = body[0], payload = Array(body[1..<(body.count - 2)])
            let crcOK = crc16(Array(body[0..<(body.count - 2)])) == (UInt16(body[body.count - 1]) << 8 | UInt16(body[body.count - 2]))
            let t = String(format: "%.1f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
            print(t, String(format: "id=0x%02x", id), "flags=", String(hdr >> 10, radix: 2), "crc", crcOK ? "ok" : "BAD", "payload[\(payload.count)]:",
                  payload.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " "))
            fflush(stdout)
        }
    }
    func rfcommChannelClosed(_ c: IOBluetoothRFCOMMChannel!) { print("closed"); exit(0) }
}

let addr = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "54:10:4F:38:97:CA"
guard let dev = IOBluetoothDevice(addressString: addr) else { print("no device"); exit(1) }
print("name:", dev.name ?? "?", "connected:", dev.isConnected())
guard dev.isConnected() else { print("Buds are not connected to this Mac. Connect them first."); exit(2) }
dev.performSDPQuery(nil)
RunLoop.current.run(until: Date().addingTimeInterval(3))
var uuidBytes: [UInt8] = [0x2e,0x73,0xa4,0xad,0x33,0x2d,0x41,0xfc,0x90,0xe2,0x16,0xbe,0xf0,0x65,0x23,0xf2]
let uuid = IOBluetoothSDPUUID(bytes: &uuidBytes, length: 16)
print("services:", (dev.services as? [IOBluetoothSDPServiceRecord])?.map { $0.getServiceName() ?? "?" } ?? [])
guard let rec = dev.getServiceRecord(for: uuid) else { print("Samsung serial service not found"); exit(3) }
var ch: BluetoothRFCOMMChannelID = 0
rec.getRFCOMMChannelID(&ch)
print("rfcomm channel", ch)
let probe = Probe()
var chan: IOBluetoothRFCOMMChannel?
let r = dev.openRFCOMMChannelSync(&chan, withChannelID: ch, delegate: probe)
print("open result:", r == kIOReturnSuccess ? "ok" : String(format: "0x%x", r))
func frame(_ id: UInt8, _ payload: [UInt8]) -> Data {
    let body = [id] + payload
    let c = crc16(body)
    var f: [UInt8] = [0xfd, UInt8((body.count + 2) & 0xff), UInt8(((body.count + 2) >> 8) & 0xff)]
    f += body; f += [UInt8(c & 0xff), UInt8(c >> 8), 0xdd]
    return Data(f)
}
RunLoop.current.run(until: Date().addingTimeInterval(3))
if let cmds = ProcessInfo.processInfo.environment["BUDS_SEND"] ?? UserDefaults.standard.string(forKey: "send") {
    for cmd in cmds.split(separator: ",") {
        let parts = cmd.split(separator: ":"); let id = UInt8(parts[0], radix: 16)!
        let pl = parts.count > 1 ? stride(from: 0, to: parts[1].count, by: 2).map { i -> UInt8 in
            let a = parts[1].index(parts[1].startIndex, offsetBy: i); return UInt8(parts[1][a..<parts[1].index(a, offsetBy: 2)], radix: 16)! } : []
        var d = frame(id, pl)
        print("TX", d.map { String(format: "%02x", $0) }.joined(separator: " ")); fflush(stdout)
        d.withUnsafeMutableBytes { _ = chan?.writeSync($0.baseAddress, length: UInt16($0.count)) }
        RunLoop.current.run(until: Date().addingTimeInterval(6))
    }
}
RunLoop.current.run(until: Date().addingTimeInterval(8))
chan?.close()
