import Foundation

struct BTDevice: Equatable { var name: String; var left: Int?; var right: Int?; var caseLevel: Int?; var single: Int? }

final class AirPods: ObservableObject {
    @Published var device: BTDevice?
    @Published var justConnected = false
    private var timer: Timer?
    private var external: BTDevice?
    func setExternal(_ d: BTDevice?) {
        external = d
        if d != nil, device == nil { justConnected = true; DispatchQueue.main.asyncAfter(deadline: .now() + Settings.shared.overlayDuration) { self.justConnected = false } }
        device = d ?? device.flatMap { _ in nil }
    }
    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
    }
    private func pct(_ v: Any?) -> Int? { Int((v as? String)?.replacingOccurrences(of: "%", with: "") ?? "") }
    func refresh() {
        DispatchQueue.global().async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            var found: BTDevice?
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let top = (j["SPBluetoothDataType"] as? [[String: Any]])?.first,
               let list = top["device_connected"] as? [[String: Any]] {
                for entry in list {
                    for (name, v) in entry {
                        guard let d = v as? [String: Any] else { continue }
                        let l = self.pct(d["device_batteryLevelLeft"]), r = self.pct(d["device_batteryLevelRight"])
                        let c = self.pct(d["device_batteryLevelCase"]), m = self.pct(d["device_batteryLevelMain"])
                        if l != nil || r != nil || c != nil || m != nil {
                            found = BTDevice(name: name, left: l, right: r, caseLevel: c, single: m)
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                if self.external != nil { return }
                if self.device == nil, found != nil {
                    self.justConnected = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + Settings.shared.overlayDuration) { self.justConnected = false }
                }
                if self.device != found { self.device = found }
            }
        }
    }
}
