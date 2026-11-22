import Foundation
import AppKit
import CoreImage.CIFilterBuiltins

/// Small helpers for the pairing QR code (Settings → Portal → Pair your phone).
enum Pairing {
    /// This Mac's address on the local network (Wi-Fi first), put in the QR so the phone finds the Mac at once.
    static func lanIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var best: (String, Int)?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), a.ifa_flags & UInt32(IFF_UP) != 0,
                  a.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: a.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            let rank = name == "en0" ? 0 : name.hasPrefix("en") ? 1 : name.hasPrefix("bridge") ? 2 : 3
            if ip.hasPrefix("169.254") { continue }
            if best == nil || rank < best!.1 { best = (ip, rank) }
        }
        return best?.0
    }

    /// A crisp QR code picture for `s`.
    static func qrImage(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8); f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        return img
    }
}
