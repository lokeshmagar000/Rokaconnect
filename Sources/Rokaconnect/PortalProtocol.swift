import Foundation
import CryptoKit
import Network

/// Portal wire protocol (shared by the Mac app, the Android app and the test client).
/// One connection per transfer. Every frame is: 4-byte big-endian length + AES-256-GCM sealed box.
/// The key is derived from a pairing code shown on the Mac, so only a paired phone can send.
struct PortalHeader: Codable {
    var kind: String        // "file" | "text"
    var name: String
    var size: Int64
    var transition: String  // classic | plane | rainbow | volcano
    var ts: Double
    var from: String
    var platform: String? = nil   // "android" from the Android app; nil from the iPhone app
}

enum PortalError: Error { case closed, badFrame, expired, rejected }

enum Portal {
    static let service = "_rokaportal._tcp"
    static let port: UInt16 = 52341
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let chunk = 1 << 20

    static func newCode() -> String { String((0..<12).map { _ in alphabet.randomElement()! }) }
    static func pretty(_ c: String) -> String {
        stride(from: 0, to: c.count, by: 4).map { String(Array(c)[$0..<min($0 + 4, c.count)]) }.joined(separator: "-")
    }
    static func normalize(_ c: String) -> String { String(c.uppercased().filter { alphabet.contains($0) }) }

    static func open(_ body: Data, _ key: SymmetricKey) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: body), using: key)
    }

    static func key(for code: String) -> SymmetricKey {
        var d = Data(("rokaconnect.portal.v1:" + normalize(code)).utf8)
        for _ in 0..<50_000 { d = Data(SHA256.hash(data: d)) }   // makes offline guessing costly
        return SymmetricKey(data: d)
    }

    /// Sends a file (fileURL) or text (text) to a paired Mac.
    static func send(to endpoint: NWEndpoint, code: String, header: PortalHeader,
                     fileURL: URL? = nil, text: Data? = nil, progress: ((Double) -> Void)? = nil) async throws {
        let key = key(for: code)
        let conn = NWConnection(to: endpoint, using: .tcp)
        try await conn.startAndWait()
        defer { conn.cancel() }
        try await conn.sendFrame(JSONEncoder().encode(header), key)
        var sent: Int64 = 0
        if let text {
            var i = 0
            while i < text.count { let e = min(i + chunk, text.count); try await conn.sendFrame(text[i..<e], key); i = e }
        } else if let fileURL {
            let fh = try FileHandle(forReadingFrom: fileURL)
            defer { try? fh.close() }
            try await conn.streamFile(fh, key: key) { n in sent = n; progress?(Double(n) / Double(max(header.size, 1))) }
        }
        let ack = try await conn.recvFrame(key)
        guard String(data: ack, encoding: .utf8) == "OK" else { throw PortalError.rejected }
    }
}

extension NWConnection {
    func startAndWait() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var done = false
            stateUpdateHandler = { s in
                guard !done else { return }
                switch s {
                case .ready: done = true; c.resume()
                case .failed(let e): done = true; c.resume(throwing: e)
                case .cancelled: done = true; c.resume(throwing: PortalError.closed)
                default: break
                }
            }
            start(queue: .global())
        }
    }
    func sendData(_ d: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            send(content: d, completion: .contentProcessed { e in if let e { c.resume(throwing: e) } else { c.resume() } })
        }
    }
    func recvExact(_ n: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            receive(minimumIncompleteLength: n, maximumLength: n) { d, _, _, e in
                if let e { c.resume(throwing: e) }
                else if let d, d.count == n { c.resume(returning: d) }
                else { c.resume(throwing: PortalError.closed) }
            }
        }
    }
    func sendFrame(_ plain: Data, _ key: SymmetricKey) async throws {
        let sealed = try AES.GCM.seal(plain, using: key).combined!
        var len = UInt32(sealed.count).bigEndian
        var out = Data(bytes: &len, count: 4); out.append(sealed)
        try await sendData(out)
    }
    func recvFrame(_ key: SymmetricKey) async throws -> Data {
        try Portal.open(try await recvSealed(), key)
    }
    /// Reads one frame without decrypting it, so decrypting can happen on another thread.
    func recvSealed() async throws -> Data {
        let h = try await recvExact(4)
        let n = Int(h.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard n > 28, n <= Portal.chunk + 64 else { throw PortalError.badFrame }
        return try await recvExact(n)
    }

    /// Sends a whole file as sealed frames, fast: reading + encrypting run ahead on their own thread and
    /// up to 8 frames are in flight at once (instead of waiting for each one). `progress` gets bytes sent.
    func streamFile(_ fh: FileHandle, key: SymmetricKey, progress: @escaping (Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // our own counter + a semaphore that starts at 0 (a semaphore must never be freed below its start value)
                let wake = DispatchSemaphore(value: 0)
                let lock = NSLock(); var failure: Error?; var inFlight = 0
                func failed() -> Error? { lock.lock(); defer { lock.unlock() }; return failure }
                func waitUntil(atMost n: Int) {
                    lock.lock()
                    while inFlight > n { lock.unlock(); wake.wait(); lock.lock() }
                    lock.unlock()
                }
                var sent: Int64 = 0
                do {
                    while let d = try fh.read(upToCount: Portal.chunk), !d.isEmpty {
                        let sealed = try AES.GCM.seal(d, using: key).combined!
                        var len = UInt32(sealed.count).bigEndian
                        var out = Data(bytes: &len, count: 4); out.append(sealed)
                        waitUntil(atMost: 7)                              // up to 8 frames on the way
                        if let e = failed() { throw e }
                        lock.lock(); inFlight += 1; lock.unlock()
                        self.send(content: out, completion: .contentProcessed { e in
                            lock.lock(); inFlight -= 1; if let e { failure = e }; lock.unlock()
                            wake.signal()
                        })
                        sent += Int64(d.count); progress(sent)
                    }
                    waitUntil(atMost: 0)                                  // everything has gone out
                    if let e = failed() { throw e }
                    c.resume()
                } catch { c.resume(throwing: error) }
            }
        }
    }
}
