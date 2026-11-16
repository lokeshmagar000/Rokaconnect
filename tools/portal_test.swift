import Foundation
import Network

@main struct T {
    static func main() async {
        let a = CommandLine.arguments   // code kind path-or-text transition
        let code = a[1], kind = a[2], payload = a[3], tr = a.count > 4 ? a[4] : "classic"
        let ep = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Portal.port)!)
        do {
            if kind == "file" {
                let url = URL(fileURLWithPath: payload)
                let size = (try FileManager.default.attributesOfItem(atPath: payload)[.size] as! NSNumber).int64Value
                let h = PortalHeader(kind: "file", name: url.lastPathComponent, size: size, transition: tr, ts: Date().timeIntervalSince1970, from: "test")
                try await Portal.send(to: ep, code: code, header: h, fileURL: url)
            } else {
                let d = Data(payload.utf8)
                let h = PortalHeader(kind: "text", name: "clipboard", size: Int64(d.count), transition: tr, ts: Date().timeIntervalSince1970, from: "test")
                try await Portal.send(to: ep, code: code, header: h, text: d)
            }
            print("SENT OK")
        } catch { print("FAILED:", error) }
    }
}
