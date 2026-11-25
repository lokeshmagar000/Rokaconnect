import Foundation
import IOKit
import IOUSBHost

// ─────────────────────────────────────────────────────────────────────────────
// USB cable mode WITHOUT USB debugging — Android Open Accessory (AOA), Google's standard for USB accessories.
//
//  1. A phone is plugged in → this Mac asks it to become an "accessory" (AOA control requests 51/52/53).
//  2. The phone shows "Open Rokaconnect for this USB accessory?" once → the app opens the accessory.
//  3. Both sides now share one raw USB bulk channel. Many connections ride on it (multiplexing), so the
//     phone app can reach this Mac's Portal at 127.0.0.1 exactly like the adb cable mode — nothing else changes.
//
// Wire format on the USB channel (both directions): [stream id: UInt32][type: UInt8][length: UInt32][payload]
//   type 1 = open (phone opened a new connection) · 2 = data · 3 = close · 4 = padding (ignored)
//   type 5 = hello (the phone app has opened the accessory — the link counts as connected from here)
// ─────────────────────────────────────────────────────────────────────────────

enum AOAFrame {
    static let open: UInt8 = 1, data: UInt8 = 2, close: UInt8 = 3, pad: UInt8 = 4, hello: UInt8 = 5
    static let header = 9

    static func make(_ id: UInt32, _ type: UInt8, _ payload: UnsafeRawBufferPointer? = nil) -> Data {
        var d = Data(capacity: header + (payload?.count ?? 0))
        var be = id.bigEndian; withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        d.append(type)
        var len = UInt32(payload?.count ?? 0).bigEndian; withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
        if let payload { d.append(contentsOf: payload) }
        return d
    }
}

/// Finds Android phones on USB, switches them to accessory mode, and runs the link.
final class AOALink: ObservableObject {
    static let shared = AOALink()

    /// True while the phone app is talking through the accessory link.
    @Published private(set) var connected = false

    /// USB vendor IDs of Android phone makers (only these are ever asked to switch — never keyboards, disks…).
    private let androidVendors: Set<Int> = [0x04E8, 0x18D1, 0x2717, 0x2A70, 0x22D9, 0x22B8, 0x12D1, 0x0FCE, 0x1004,
                                            0x0BB4, 0x2D95, 0x0B05, 0x17EF, 0x2B4C, 0x1949, 0x0E8D]
    private let queue = DispatchQueue(label: "rokaconnect.aoa", qos: .utility)
    private var asked = Set<UInt64>()           // USB devices already asked to switch (each plug-in is a new one)
    private var session: AOASession?
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.queue.async { self?.scan() } }
        queue.async { self.scan() }
    }

    /// Only switch phones once an Android phone with the Rokaconnect app has been seen (so a friend's phone
    /// charging on this Mac isn't turned into an accessory with nothing to talk to).
    private var knowsAndroidPhone: Bool { UserDefaults.standard.bool(forKey: "knowsAndroidPhone") }

    private func scan() {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let svc = IOIteratorNext(it), svc != 0 {
            defer { IOObjectRelease(svc) }
            let vid = Self.intProp(svc, "idVendor"), pid = Self.intProp(svc, "idProduct")
            var entry: UInt64 = 0; IORegistryEntryGetRegistryEntryID(svc, &entry)
            if vid == 0x18D1, (0x2D00...0x2D05).contains(pid) {
                // already an accessory → open the link (once)
                if session == nil {
                    session = AOASession(service: svc, onConnected: { [weak self] in DispatchQueue.main.async { self?.connected = true } },
                                         onEnd: { [weak self] in
                                             self?.queue.async { self?.session = nil }
                                             DispatchQueue.main.async { self?.connected = false }
                                         })
                }
            } else if androidVendors.contains(vid), knowsAndroidPhone, !asked.contains(entry) {
                asked.insert(entry)
                Self.switchToAccessory(svc)
            }
        }
    }

    /// AOA: "which protocol do you support?" (51), send our identity strings (52), "start accessory mode" (53).
    /// The phone then disconnects and comes back as a Google accessory device (18D1:2D00 or 2D01 with adb).
    private static func switchToAccessory(_ svc: io_service_t) {
        guard let dev = try? IOUSBHostDevice(__ioService: svc, options: [], queue: nil, interestHandler: nil) else { return }
        defer { dev.destroy() }
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0xC0; req.bRequest = 51; req.wLength = 2
        let ver = NSMutableData(length: 2)!
        var got = 0
        guard (try? dev.__send(req, data: ver, bytesTransferred: &got, completionTimeout: 2)) != nil,
              ver.bytes.load(as: UInt8.self) >= 1 else { return }
        // must match the phone app's accessory_filter.xml (manufacturer + model)
        let strings = ["Rokaconnect", "Rokaconnect Mac", "Rokaconnect USB link", "1.0",
                       "https://github.com/lokeshmagar000/Rokaconnect", "rokaconnect-mac"]
        for (i, s) in strings.enumerated() {
            let bytes = NSMutableData(data: Data(s.utf8) + [0])
            var r = IOUSBDeviceRequest()
            r.bmRequestType = 0x40; r.bRequest = 52; r.wIndex = UInt16(i); r.wLength = UInt16(bytes.length)
            _ = try? dev.__send(r, data: bytes, bytesTransferred: &got, completionTimeout: 2)
        }
        var startReq = IOUSBDeviceRequest()
        startReq.bmRequestType = 0x40; startReq.bRequest = 53
        _ = try? dev.__send(startReq, data: nil, bytesTransferred: &got, completionTimeout: 2)
    }

    static func intProp(_ svc: io_service_t, _ key: String) -> Int {
        (IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int) ?? -1
    }
}

/// One plugged-in accessory phone: two bulk pipes, and the connections multiplexed over them.
final class AOASession {
    private let device: IOUSBHostDevice
    private let interface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe
    private let writeLock = NSLock()
    private let lock = NSLock()
    private var sockets: [UInt32: Int32] = [:]       // stream id → local socket to this Mac's Portal
    private var ended = false
    private var sawPhone = false
    private let onConnected: () -> Void
    private let onEnd: () -> Void

    init?(service: io_service_t, onConnected: @escaping () -> Void, onEnd: @escaping () -> Void) {
        self.onConnected = onConnected; self.onEnd = onEnd
        guard let dev = try? IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil) else { return nil }
        // the accessory interface (number 0); configure the device first if macOS hasn't
        var intfService = Self.findInterface(of: service)
        if intfService == 0 {
            _ = try? dev.__configure(withValue: 1, matchInterfaces: true)
            for _ in 0..<20 where intfService == 0 { usleep(50_000); intfService = Self.findInterface(of: service) }
        }
        guard intfService != 0, let intf = try? IOUSBHostInterface(__ioService: intfService, options: [], queue: nil, interestHandler: nil) else {
            IOObjectRelease(intfService); dev.destroy(); return nil
        }
        IOObjectRelease(intfService)
        let inP = (0x81...0x8F).lazy.compactMap { try? intf.copyPipe(withAddress: $0) }.first
        let outP = (0x01...0x0F).lazy.compactMap { try? intf.copyPipe(withAddress: $0) }.first
        guard let inP, let outP else { intf.destroy(); dev.destroy(); return nil }
        device = dev; interface = intf; inPipe = inP; outPipe = outP
        Thread { [self] in readLoop() }.start()
    }

    private static func findInterface(of device: io_service_t) -> io_service_t {
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &it) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(it) }
        while case let child = IOIteratorNext(it), child != 0 {
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0, AOALink.intProp(child, "bInterfaceNumber") == 0 { return child }
            IOObjectRelease(child)
        }
        return 0
    }

    // MARK: USB → sockets

    private func readLoop() {
        let buf = NSMutableData(length: 256 * 1024)!
        var acc = Data()
        while !isEnded {
            var n = 0
            do { try inPipe.__sendIORequest(with: buf, bytesTransferred: &n, completionTimeout: 0) }
            catch { end(); return }
            guard n > 0 else { continue }
            acc.append(buf.bytes.assumingMemoryBound(to: UInt8.self), count: n)
            // take out every complete frame
            var off = 0
            while acc.count - off >= AOAFrame.header {
                let id = acc.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: off, as: UInt32.self)) }
                let type = acc[acc.startIndex + off + 4]
                let len = Int(acc.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: off + 5, as: UInt32.self)) })
                guard acc.count - off - AOAFrame.header >= len else { break }
                let start = acc.startIndex + off + AOAFrame.header
                handle(id, type, acc[start..<start + len])
                off += AOAFrame.header + len
            }
            if off > 0 { acc.removeSubrange(acc.startIndex..<acc.startIndex + off) }
        }
    }

    private func handle(_ id: UInt32, _ type: UInt8, _ payload: Data) {
        switch type {
        case AOAFrame.hello:
            if !sawPhone { sawPhone = true; onConnected() }
        case AOAFrame.open:
            if !sawPhone { sawPhone = true; onConnected() }
            guard let fd = Self.connectToPortal() else { send(AOAFrame.make(id, AOAFrame.close)); return }
            lock.lock(); sockets[id] = fd; lock.unlock()
            Thread { [self] in pumpSocket(id, fd) }.start()
        case AOAFrame.data:
            lock.lock(); let fd = sockets[id]; lock.unlock()
            guard let fd else { return }
            payload.withUnsafeBytes { raw in
                var p = raw.baseAddress!, left = raw.count
                while left > 0 { let w = Darwin.write(fd, p, left); if w <= 0 { break }; p += w; left -= w }
            }
        case AOAFrame.close:
            lock.lock(); let fd = sockets[id]; lock.unlock()
            if let fd { shutdown(fd, SHUT_WR) }           // the phone is done sending; the Portal may still answer
        default: break                                     // padding
        }
    }

    // MARK: sockets → USB

    private func pumpSocket(_ id: UInt32, _ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            buf.withUnsafeBytes { send(AOAFrame.make(id, AOAFrame.data, UnsafeRawBufferPointer(rebasing: $0[0..<n]))) }
        }
        send(AOAFrame.make(id, AOAFrame.close))
        lock.lock(); sockets[id] = nil; lock.unlock()
        close(fd)
    }

    /// Writes frames to the phone. If the write would be an exact multiple of the USB packet size, a small
    /// padding frame is added, so the phone's read always ends with a short packet and never waits for more.
    private func send(_ frame: Data) {
        var out = frame
        if out.count % 512 == 0 { out.append(AOAFrame.make(0, AOAFrame.pad)) }
        writeLock.lock(); defer { writeLock.unlock() }
        guard !isEnded else { return }
        // keep up to 6 writes queued on the cable, so it never sits idle waiting for the last one to finish
        // (writes on one pipe always arrive in order)
        flightLock.lock()
        while inFlight >= 6 { flightLock.unlock(); flightDone.wait(); flightLock.lock() }
        inFlight += 1
        flightLock.unlock()
        do {
            try outPipe.enqueueIORequest(with: NSMutableData(data: out), completionTimeout: 0) { [weak self] status, _ in
                guard let self else { return }
                self.flightLock.lock(); self.inFlight -= 1; self.flightLock.unlock()
                self.flightDone.signal()
                if status != kIOReturnSuccess { DispatchQueue.global().async { self.end() } }
            }
        } catch {
            flightLock.lock(); inFlight -= 1; flightLock.unlock(); flightDone.signal()
            DispatchQueue.global().async { self.end() }
        }
    }
    private let flightLock = NSLock()
    private let flightDone = DispatchSemaphore(value: 0)     // starts at 0, so it can never be freed "below its start"
    private var inFlight = 0

    private static func connectToPortal() -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_port = Portal.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if ok != 0 { close(fd); return nil }
        var one: Int32 = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    // MARK: teardown (cable unplugged / phone left accessory mode)

    private var isEnded: Bool { lock.lock(); defer { lock.unlock() }; return ended }

    private func end() {
        lock.lock()
        if ended { lock.unlock(); return }
        ended = true
        let all = sockets.values; sockets.removeAll()
        lock.unlock()
        all.forEach { shutdown($0, SHUT_RDWR) }
        try? inPipe.__abort(with: .synchronous); try? outPipe.__abort(with: .synchronous)
        interface.destroy(); device.destroy()
        onEnd()
    }
}
