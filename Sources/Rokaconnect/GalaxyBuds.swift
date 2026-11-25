import Foundation
import IOBluetooth
import SwiftUI

/// Talks to Samsung Galaxy Buds over their Bluetooth serial channel (unofficial protocol, verified on Buds2 Pro:
/// frames are 0xFD | size(2, LE) | id | payload | CRC16-CCITT(id+payload, LE) | 0xDD).
final class GalaxyBuds: NSObject, ObservableObject, IOBluetoothRFCOMMChannelDelegate {
    @Published var name: String?
    @Published var noiseMode: Int?          // as last set from here: 0 off, 1 ANC, 2 ambient
    private weak var airpods: AirPods?
    private var chan: IOBluetoothRFCOMMChannel?
    private var buf: [UInt8] = []
    private var timer: Timer?
    private var device: IOBluetoothDevice?

    init(airpods: AirPods) {
        self.airpods = airpods
        super.init()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    private static func crc16(_ d: [UInt8]) -> UInt16 {
        var c: UInt16 = 0
        for b in d { c ^= UInt16(b) << 8; for _ in 0..<8 { c = (c & 0x8000) != 0 ? (c << 1) ^ 0x1021 : c << 1 } }
        return c
    }

    private var opening = false

    /// Connected Buds per macOS's own device list (IOBluetooth's isConnected() proved unreliable here).
    private static func connectedBudsAddress() -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let top = (j["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let list = top["device_connected"] as? [[String: Any]] else { return nil }
        for e in list { for (name, v) in e where name.localizedCaseInsensitiveContains("buds") {
            if let a = (v as? [String: Any])?["device_address"] as? String { return a }
        } }
        return nil
    }

    private func tick() {
        guard chan == nil, !opening else { return }
        opening = true
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            guard let addr = Self.connectedBudsAddress(), let dev = IOBluetoothDevice(addressString: addr) else {
                DispatchQueue.main.async {
                    self.opening = false
                    if self.name != nil { self.name = nil; self.airpods?.setExternal(nil) }
                }
                return
            }
            dev.performSDPQuery(nil)
            Thread.sleep(forTimeInterval: 2)
            var u: [UInt8] = [0x2e,0x73,0xa4,0xad,0x33,0x2d,0x41,0xfc,0x90,0xe2,0x16,0xbe,0xf0,0x65,0x23,0xf2]
            let rec = dev.getServiceRecord(for: IOBluetoothSDPUUID(bytes: &u, length: 16))
            var ch: BluetoothRFCOMMChannelID = 0
            rec?.getRFCOMMChannelID(&ch)
            DispatchQueue.main.async {
                defer { self.opening = false }
                guard rec != nil else { return }
                var c: IOBluetoothRFCOMMChannel?
                let r = dev.openRFCOMMChannelAsync(&c, withChannelID: ch, delegate: self)
                if r == kIOReturnSuccess { self.chan = c; self.device = dev; self.name = dev.name }
            }
        }
    }

    func rfcommChannelData(_ c: IOBluetoothRFCOMMChannel!, data p: UnsafeMutableRawPointer!, length l: Int) {
        buf += Array(Data(bytes: p, count: l))
        while let s = buf.firstIndex(of: 0xfd), let e = buf[s...].firstIndex(of: 0xdd), e - s >= 5 {
            let f = Array(buf[s...e]); buf.removeSubrange(0...e)
            let size = (Int(f[1]) | Int(f[2]) << 8) & 0x3ff
            let body = Array(f[3..<(f.count - 1)])
            guard body.count == size, size >= 3,
                  Self.crc16(Array(body[0..<(body.count - 2)])) == (UInt16(body[body.count - 1]) << 8 | UInt16(body[body.count - 2])) else { continue }
            if body[0] == 0x61 { status(Array(body[1..<(body.count - 2)])) }
            // 0x77: the buds report a noise-control change (e.g. you touched and held the earbud)
            if body[0] == 0x77, body.count > 3 { let m = Int(body[1]); if (0...2).contains(m) { DispatchQueue.main.async { self.noiseMode = m } } }
        }
    }

    /// Extended status: [2]=left %, [3]=right %, [6]=placement, [7]=case %
    private func status(_ p: [UInt8]) {
        guard p.count > 7 else { return }
        let l = Int(p[2]), r = Int(p[3]), cse = Int(p[7])
        let dev = BTDevice(name: name ?? "Galaxy Buds", left: (1...100).contains(l) ? l : nil,
                           right: (1...100).contains(r) ? r : nil, caseLevel: (1...100).contains(cse) ? cse : nil, single: nil)
        DispatchQueue.main.async { self.airpods?.setExternal(dev) }
    }

    func rfcommChannelClosed(_ c: IOBluetoothRFCOMMChannel!) {
        chan = nil; DispatchQueue.main.async { self.name = nil; self.airpods?.setExternal(nil) }
    }

    private func send(_ id: UInt8, _ payload: [UInt8]) {
        guard let chan else { return }
        let body = [id] + payload
        let c = Self.crc16(body)
        var f: [UInt8] = [0xfd, UInt8(body.count + 2), 0] + body + [UInt8(c & 0xff), UInt8(c >> 8), 0xdd]
        f.withUnsafeMutableBytes { _ = chan.writeSync($0.baseAddress, length: UInt16($0.count)) }
    }

    /// 0 = off, 1 = noise cancelling, 2 = ambient (message 0x78; confirmed on Buds2 Pro).
    func setNoise(_ mode: Int) { send(0x78, [UInt8(mode)]); noiseMode = mode }

    static let eqPresets = ["Normal", "Bass boost", "Soft", "Dynamic", "Clear", "Treble boost"]
    @Published var eqPreset: Int?
    /// EQ preset (message 0x86; the Buds acknowledge with 0x42). Normal and Bass boost confirmed on Buds2 Pro.
    func setEQ(_ preset: Int) { send(0x86, [UInt8(preset)]); eqPreset = preset }
}

struct BudsSection: View {
    @ObservedObject var b: GalaxyBuds
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Galaxy Buds").font(.headline)
            if let n = b.name {
                Text("Connected: \(n)").font(.caption)
                Picker("Noise control", selection: Binding(get: { b.noiseMode ?? -1 }, set: { if $0 >= 0 { b.setNoise($0) } })) {
                    Text("—").tag(-1); Text("Off").tag(0); Text("Noise cancelling").tag(1); Text("Ambient").tag(2)
                }
                Picker("Equalizer", selection: Binding(get: { b.eqPreset ?? -1 }, set: { if $0 >= 0 { b.setEQ($0) } })) {
                    Text("—").tag(-1)
                    ForEach(0..<GalaxyBuds.eqPresets.count, id: \.self) { Text(GalaxyBuds.eqPresets[$0]).tag($0) }
                }
                Text("Unofficial Samsung protocol. Battery, noise control and EQ were tested on Buds2 Pro.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Connect your Galaxy Buds to this Mac in System Settings → Bluetooth.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

