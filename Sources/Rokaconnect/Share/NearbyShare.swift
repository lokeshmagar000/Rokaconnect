import Foundation
import Network
import AppKit
import UniformTypeIdentifiers
import os

// Share with Android: an independent implementation of the Nearby Connections + Nearby Sharing wire protocol
// (Android's built-in "Quick Share"), written from Google's Apache-2.0 sources (github.com/google/nearby).
// Works over the local Wi-Fi network (mDNS + TCP).

private let shareLogger = Logger(subsystem: "com.rokaconnect.app", category: "ShareAndroid")
func qsLog(_ s: String) { shareLogger.notice("\(s, privacy: .public)") }

enum NearbyShareError: LocalizedError {
    case protocolError(String), rejected, declined, cancelled, closed
    var errorDescription: String? {
        switch self {
        case .protocolError(let s): "Communication error (\(s))"
        case .rejected: "The other device refused the connection"
        case .declined: "Declined"
        case .cancelled: "Cancelled"
        case .closed: "Connection closed"
        }
    }
}

// MARK: - Frames

enum NearbyFrames {
    static func offline(_ type: Int, field: Int, _ inner: PBWriter) -> Data {
        let v1 = PBWriter.build { $0.int(1, type); $0.message(field, inner) }
        return PBWriter.build { $0.int(1, 1); $0.message(2, v1) }.data
    }
    static func connectionRequest(endpointID: String, name: String, info: Data) -> Data {
        offline(1, field: 2, PBWriter.build {
            $0.string(1, endpointID); $0.string(2, name); $0.int(4, Int64(Int32.random(in: 1...Int32.max))); $0.bytes(6, info)
        })
    }
    static func connectionResponse(accept: Bool) -> Data {
        offline(2, field: 3, PBWriter.build {
            $0.int(1, accept ? 0 : 1); $0.int(3, accept ? 1 : 2); $0.message(4, PBWriter.build { $0.int(1, 4) })  // OsInfo APPLE
        })
    }
    static func keepAlive() -> Data { offline(5, field: 6, PBWriter.build { $0.bool(1, false) }) }
    static func disconnection() -> Data { offline(6, field: 7, PBWriter()) }
    static func payload(id: Int64, type: Int, total: Int64, offset: Int64, body: Data, last: Bool) -> Data {
        offline(3, field: 4, PBWriter.build {
            $0.int(1, 1)   // DATA
            $0.message(2, PBWriter.build { $0.int(1, id); $0.int(2, type); $0.int(3, total); $0.bool(4, false) })
            $0.message(3, PBWriter.build { $0.int(1, last ? 1 : 0); $0.int(2, offset); if !body.isEmpty { $0.bytes(3, body) } })
        })
    }
    /// nearby.sharing.service.Frame (V1)
    static func sharing(_ type: Int, field: Int, _ inner: PBWriter) -> Data {
        let v1 = PBWriter.build { $0.int(1, type); $0.message(field, inner) }
        return PBWriter.build { $0.int(1, 1); $0.message(2, v1) }.data
    }
    static func pairedKeyEncryption() -> Data {
        sharing(3, field: 4, PBWriter.build { $0.bytes(1, Data.random(72)); $0.bytes(2, Data.random(6)) })
    }
    static func pairedKeyResult() -> Data { sharing(4, field: 5, PBWriter.build { $0.int(1, 3) }) }   // UNABLE
    static func response(accept: Bool) -> Data { sharing(2, field: 3, PBWriter.build { $0.int(1, accept ? 1 : 2) }) }

    /// Endpoint info: [version|visibility|deviceType|reserved] + 16 random bytes + name length + name.
    static func endpointInfo(name: String) -> Data {
        var d = Data([UInt8(3 << 1)])       // device type: laptop, visible to everyone
        d.append(Data.random(16))
        let n = Data(name.utf8.prefix(255))
        d.append(UInt8(n.count)); d.append(n)
        return d
    }
    static func name(fromEndpointInfo d: Data?) -> String? {
        guard let d, d.count > 17 else { return nil }
        let b = [UInt8](d)
        guard b[0] & 0x10 == 0 else { return nil }
        let len = Int(b[17])
        guard b.count >= 18 + len else { return nil }
        return String(decoding: b[18..<18 + len], as: UTF8.self)
    }
}

// MARK: - Session

actor NearbySession {
    private let conn: NWConnection
    private let hub = TransferHub.shared
    private var channel: D2DChannel?
    private var peerName = "Android device"
    private var hubID: UUID?
    private var finished = false
    private var keepAliveTask: Task<Void, Never>?

    // incoming state
    private var byteBuffers: [Int64: Data] = [:]
    private var textPayloads: [Int64: Int64] = [:]               // payload id -> TextMetadata.Type
    private var files: [Int64: (url: URL, handle: FileHandle, size: Int64)] = [:]
    private var expected: Int64 = 0, received: Int64 = 0
    private var pendingPayloads = Set<Int64>()
    private var savedFiles: [URL] = []

    // outgoing state
    private var outgoing: [(url: URL, id: Int64, size: Int64)] = []
    private var sentAll = false

    init(_ conn: NWConnection) { self.conn = conn }

    // MARK: transport

    private func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var done = false
            conn.stateUpdateHandler = { s in
                guard !done else { return }
                switch s {
                case .ready: done = true; c.resume()
                case .failed(let e), .waiting(let e): done = true; c.resume(throwing: e)
                case .cancelled: done = true; c.resume(throwing: NearbyShareError.closed)
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }
    /// Enqueues synchronously on the actor, so frames always go out in sequence-number order.
    private func sendRaw(_ d: Data) async throws {
        var len = UInt32(d.count).bigEndian
        var out = Data(bytes: &len, count: 4); out.append(d)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: out, completion: .contentProcessed { e in if let e { c.resume(throwing: e) } else { c.resume() } })
        }
    }
    private func recvRaw() async throws -> Data {
        let h = try await conn.recvExact(4)
        let n = Int(h.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard n > 0, n <= 8_000_000 else { throw NearbyShareError.protocolError("frame size \(n)") }
        return try await conn.recvExact(n)
    }
    private func sendSecure(_ offline: Data) async throws {
        guard let channel else { throw NearbyShareError.closed }
        try await sendRaw(try channel.seal(offline))
    }
    /// Returns the decrypted OfflineFrame's V1Frame.
    private func recvSecure() async throws -> PBMessage {
        guard let channel else { throw NearbyShareError.closed }
        let raw = try await recvRaw()
        let plain = try channel.open(raw)
        guard let v1 = try PBMessage(plain).message(2) else { throw NearbyShareError.protocolError("empty frame") }
        return v1
    }
    private func sendSharing(_ frame: Data) async throws {
        let id = Int64.random(in: 1...Int64.max)
        let total = Int64(frame.count)
        try await sendSecure(NearbyFrames.payload(id: id, type: 1, total: total, offset: 0, body: frame, last: false))
        try await sendSecure(NearbyFrames.payload(id: id, type: 1, total: total, offset: total, body: Data(), last: true))
    }
    private func startKeepAlive() {
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled else { return }
                try? await self.sendSecure(NearbyFrames.keepAlive())
            }
        }
    }
    private func close() async {
        keepAliveTask?.cancel()
        if channel != nil { try? await sendSecure(NearbyFrames.disconnection()) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        conn.cancel()
    }

    private func onMain(_ f: @escaping (TransferHub) -> Void) { let h = hub; DispatchQueue.main.async { f(h) } }

    private func end(_ error: Error?) {
        guard !finished else { return }
        finished = true
        for f in files.values { try? f.handle.close() }
        if error != nil { for f in files.values { try? FileManager.default.removeItem(at: f.url) } }
        if let id = hubID {
            let saved = savedFiles
            let msg: String? = error.map { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription }
            onMain { hub in
                if case .declined? = error as? NearbyShareError { hub.update(id) { $0.state = .declined } }
                else { hub.finish(id, files: saved, error: msg) }
            }
        }
        qsLog(error.map { "session ended with error: \($0)" } ?? "session finished OK")
    }

    // MARK: receiving (Android -> Mac)

    func runInbound() async {
        do {
            try await start()
            guard let req = try PBMessage(try await recvRaw()).message(2), req.int(1) == 1, let cr = req.message(2) else {
                throw NearbyShareError.protocolError("connection request")
            }
            peerName = NearbyFrames.name(fromEndpointInfo: cr.data(6)) ?? cr.string(2) ?? peerName
            qsLog("incoming connection from \(peerName)")
            let ukey = Ukey2()
            let (serverInit, finishHandshake) = try ukey.respond(toClientInit: try await recvRaw())
            try await sendRaw(serverInit)
            channel = try finishHandshake(try await recvRaw())
            qsLog("handshake done, PIN \(channel?.pin ?? "")")
            try await sendRaw(NearbyFrames.connectionResponse(accept: true))
            guard let theirs = try PBMessage(try await recvRaw()).message(2), theirs.int(1) == 2 else {
                throw NearbyShareError.protocolError("connection response")
            }
            if theirs.message(3)?.int(3) == 2 { throw NearbyShareError.rejected }
            startKeepAlive()
            try await loop()
            end(nil)
        } catch { end(error) }
        await close()
    }

    private func loop() async throws {
        while !finished {
            let v1 = try await recvSecure()
            switch v1.int(1) {
            case 3: if let p = v1.message(4) { try await handlePayload(p) }
            case 6:   // DISCONNECTION
                if sentAll || done { return }
                throw NearbyShareError.closed
            default: break   // keep-alive, bandwidth upgrade etc.
            }
            if done { return }
        }
    }

    private var done = false

    private func handlePayload(_ p: PBMessage) async throws {
        if p.int(1) == 2, p.message(4)?.int(1) == 2 { throw NearbyShareError.cancelled }   // CONTROL: PAYLOAD_CANCELED
        guard let header = p.message(2), let chunk = p.message(3), let id = header.int(1) else { return }
        let body = chunk.data(3) ?? Data()
        let last = (chunk.int(1) ?? 0) & 1 == 1
        if header.int(2) == 2 {   // FILE
            guard let f = files[id] else { return }
            if !body.isEmpty {
                // never write outside the size the sender announced (no huge sparse files, no overruns)
                let offset = chunk.int(2) ?? 0
                guard offset >= 0, offset + Int64(body.count) <= f.size else { throw NearbyShareError.protocolError("data beyond the announced size") }
                try f.handle.seek(toOffset: UInt64(offset))
                try f.handle.write(contentsOf: body)
                received += Int64(body.count)
                if let hid = hubID { let p = expected > 0 ? Double(received) / Double(expected) : 0; onMain { $0.progress(hid, p) } }
            }
            if last {
                try? f.handle.close(); files.removeValue(forKey: id)
                Safety.quarantine(f.url, from: peerName)          // Gatekeeper checks it before anything in it can run
                savedFiles.append(f.url); pendingPayloads.remove(id)
                if pendingPayloads.isEmpty { done = true }
            }
            return
        }
        byteBuffers[id, default: Data()].append(body)
        if (byteBuffers[id]?.count ?? 0) > Safety.maxQuickShareText { throw NearbyShareError.protocolError("text too large") }
        guard last, let data = byteBuffers.removeValue(forKey: id) else { return }
        if let type = textPayloads[id] {
            handleText(data, type: type); pendingPayloads.remove(id)
            if pendingPayloads.isEmpty { done = true }
            return
        }
        guard let frame = try? PBMessage(data), let v1 = frame.message(2) else { return }
        try await handleSharing(v1)
    }

    private func handleText(_ d: Data, type: Int64) {
        let s = String(decoding: d, as: UTF8.self)
        DispatchQueue.main.async {
            // copied for you to paste — links are never opened automatically (a nearby sender could open any page)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
            _ = type
        }
    }

    private func handleSharing(_ v1: PBMessage) async throws {
        switch v1.int(1) {
        // Receiver: PKE -> reply PKE, PKR -> reply PKR.  Sender (already sent PKE): PKE -> send PKR, PKR -> send Introduction.
        case 3:                                                                     // PAIRED_KEY_ENCRYPTION
            try await sendSharing(outgoing.isEmpty ? NearbyFrames.pairedKeyEncryption() : NearbyFrames.pairedKeyResult())
        case 4:                                                                     // PAIRED_KEY_RESULT
            if outgoing.isEmpty { try await sendSharing(NearbyFrames.pairedKeyResult()) }
            else { try await sendIntroduction() }
        case 1: if let intro = v1.message(2) { try await handleIntroduction(intro) }  // INTRODUCTION
        case 2:                                                                     // RESPONSE (we are sending)
            let status = v1.message(3)?.int(1) ?? 0
            guard status == 1 else { throw NearbyShareError.declined }
            try await streamFiles()
        case 6: throw NearbyShareError.cancelled                                     // CANCEL
        default: break
        }
    }

    private func handleIntroduction(_ intro: PBMessage) async throws {
        let fileMeta = intro.messages(1)
        qsLog("introduction: \(intro.messages(1).count) files, \(intro.messages(2).count) texts")
        let textMeta = intro.messages(2)
        guard !fileMeta.isEmpty || !textMeta.isEmpty else {
            try await sendSharing(NearbyFrames.response(accept: false))
            throw NearbyShareError.protocolError("unsupported attachment (only files, text and links are supported)")
        }
        let title: String
        if let t = textMeta.first, fileMeta.isEmpty { title = t.string(2) ?? "Text" }
        else if fileMeta.count == 1 { title = fileMeta[0].string(1) ?? "1 file" }
        else { title = "\(fileMeta.count) files" + (textMeta.isEmpty ? "" : " and text") }
        let pin = channel?.pin ?? ""
        let peer = peerName
        let hid: UUID = await withCheckedContinuation { c in
            DispatchQueue.main.async { c.resume(returning: TransferHub.shared.begin(.incoming, .android, peer: peer, title: title, state: .waiting)) }
        }
        hubID = hid
        // ask in the island unless the user turned on "Accept without asking" (off by default: anyone nearby could send)
        let direct = NearbyShare.autoAccept || (UserDefaults.standard.object(forKey: "autoAcceptShares") as? Bool ?? false)
        // refuse oversized offers outright
        let offered = fileMeta.reduce(Int64(0)) { $0 + ($1.int(4) ?? 0) }
        if offered < 0 || offered > Safety.maxQuickShareBytes {
            try await sendSharing(NearbyFrames.response(accept: false))
            throw NearbyShareError.protocolError("offer too large")
        }
        let accept: Bool = direct ? true : await withCheckedContinuation { c in
            DispatchQueue.main.async { TransferHub.shared.askConsent(peer: peer, title: title, pin: pin) { c.resume(returning: $0) } }
        }
        try await sendSharing(NearbyFrames.response(accept: accept))
        guard accept else { throw NearbyShareError.declined }
        onMain { $0.progress(hid, 0) }
        for f in fileMeta {
            guard let pid = f.int(3) else { continue }
            let url = TransferHub.uniqueDestination(f.string(1) ?? "file")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let h = try FileHandle(forWritingTo: url)
            let size = f.int(4) ?? 0
            files[pid] = (url, h, size); expected += size; pendingPayloads.insert(pid)
        }
        for t in textMeta {
            guard let pid = t.int(4) else { continue }
            textPayloads[pid] = t.int(3) ?? 1; pendingPayloads.insert(pid)
        }
        if pendingPayloads.isEmpty { done = true }
    }

    // MARK: sending (Mac -> Android)

    func runOutbound(urls: [URL], peer: String, endpointID: String, name: String) async {
        peerName = peer
        outgoing = urls.map { ($0, Int64.random(in: 1...Int64.max), TransferHub.size($0)) }
        let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        hubID = await withCheckedContinuation { c in
            DispatchQueue.main.async { c.resume(returning: TransferHub.shared.begin(.outgoing, .android, peer: peer, title: title, state: .waiting, file: urls.first)) }
        }
        do {
            try await start()
            try await sendRaw(NearbyFrames.connectionRequest(endpointID: endpointID, name: name, info: NearbyFrames.endpointInfo(name: name)))
            let ukey = Ukey2()
            let (clientInit, clientFinish) = ukey.clientMessages()
            try await sendRaw(clientInit)
            channel = try ukey.channel(clientInit: clientInit, serverInit: try await recvRaw())
            try await sendRaw(clientFinish)
            qsLog("outgoing handshake done with \(peer), PIN \(channel?.pin ?? "")")
            try await sendRaw(NearbyFrames.connectionResponse(accept: true))
            guard let theirs = try PBMessage(try await recvRaw()).message(2), theirs.int(1) == 2 else {
                throw NearbyShareError.protocolError("connection response")
            }
            if theirs.message(3)?.int(3) == 2 { throw NearbyShareError.rejected }
            if let hid = hubID, let pin = channel?.pin { onMain { $0.update(hid) { $0.title = "\(title) · PIN \(pin)" } } }
            startKeepAlive()
            try await sendSharing(NearbyFrames.pairedKeyEncryption())
            try await loop()
            end(nil)
        } catch { end(error) }
        await close()
    }

    private func sendIntroduction() async throws {
        let intro = PBWriter.build { w in
            for f in outgoing {
                let mime = UTType(filenameExtension: f.url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let type: Int = mime.hasPrefix("image/") ? 1 : mime.hasPrefix("video/") ? 2 : mime.hasPrefix("audio/") ? 4 : 5
                w.message(1, PBWriter.build {
                    $0.string(1, f.url.lastPathComponent); $0.int(2, type); $0.int(3, f.id); $0.int(4, f.size)
                    $0.string(5, mime); $0.int(6, Int64.random(in: 1...Int64.max))
                })
            }
        }
        try await sendSharing(NearbyFrames.sharing(1, field: 2, intro))
    }

    private func streamFiles() async throws {
        let total = max(1, outgoing.reduce(0) { $0 + $1.size })
        var sent: Int64 = 0
        let chunkSize = 512 * 1024
        for f in outgoing {
            let h = try FileHandle(forReadingFrom: f.url)
            defer { try? h.close() }
            var offset: Int64 = 0
            while true {
                let body = try h.read(upToCount: chunkSize) ?? Data()
                if body.isEmpty { break }
                try await sendSecure(NearbyFrames.payload(id: f.id, type: 2, total: f.size, offset: offset, body: body, last: false))
                offset += Int64(body.count); sent += Int64(body.count)
                if let hid = hubID { let p = Double(sent) / Double(total); onMain { $0.progress(hid, p) } }
            }
            try await sendSecure(NearbyFrames.payload(id: f.id, type: 2, total: f.size, offset: offset, body: Data(), last: true))
        }
        sentAll = true
        // Give the phone a moment to confirm (it disconnects when done); don't wait forever.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await self?.timeoutAfterSend()
        }
    }

    private func timeoutAfterSend() { if !finished { end(nil); conn.cancel() } }
}

// MARK: - Service (advertise + discover)

final class NearbyShare {
    static let shared = NearbyShare()
    static var autoAccept = false   // self-test only
    static let serviceType = "_FC9F5ED42C8A._tcp"

    let endpointID: String = String((0..<4).map { _ in "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".randomElement()! })
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var found: [String: NWBrowser.Result] = [:]
    private(set) var port: UInt16 = 0
    private var name: String { Host.current().localizedName ?? "Mac" }

    var isRunning: Bool { listener != nil }

    func setEnabled(_ on: Bool) { on ? start() : stop() }

    func start() {
        guard listener == nil else { return }
        do {
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let l = try NWListener(using: NWParameters(tls: nil, tcp: tcp))
            // mDNS instance name: PCP 0x23 | endpoint id | SHA256("NearbySharing")[0..<3] | 2 zero bytes
            var nameBytes = Data([0x23]); nameBytes.append(Data(endpointID.utf8)); nameBytes.append(contentsOf: [0xFC, 0x9F, 0x5E, 0, 0])
            var txt = NWTXTRecord()
            txt["n"] = NearbyFrames.endpointInfo(name: name).base64URL()
            l.service = NWListener.Service(name: nameBytes.base64URL(), type: Self.serviceType, domain: nil, txtRecord: txt)
            l.newConnectionHandler = { conn in Task { await NearbySession(conn).runInbound() } }
            l.stateUpdateHandler = { [weak self] s in
                if case .ready = s, let p = l.port?.rawValue { self?.port = p; qsLog("visible to Android on port \(p)") }
                if case .failed(let e) = s { qsLog("listener failed: \(e)") }
            }
            l.start(queue: .main)
            listener = l
        } catch { qsLog("could not start: \(error)") }
        startBrowsing()
    }

    func stop() {
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        found = [:]
        DispatchQueue.main.async { TransferHub.shared.androidPeers = [] }
    }

    private func startBrowsing() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.refresh(results) }
        b.start(queue: .main)
        browser = b
    }

    private func refresh(_ results: Set<NWBrowser.Result>) {
        var peers: [TransferHub.AndroidPeer] = []
        found = [:]
        for r in results {
            guard case let .service(svcName, _, _, _) = r.endpoint, let raw = Data(base64URL: svcName), raw.count >= 8,
                  raw.first == 0x23 else { continue }
            let id = String(decoding: raw.subdata(in: 1..<5), as: UTF8.self)
            guard id != endpointID else { continue }   // ourselves
            var display = "Android device"
            if case let .bonjour(txt) = r.metadata, let n = txt["n"], let info = Data(base64URL: n),
               let decoded = NearbyFrames.name(fromEndpointInfo: info) { display = decoded }
            found[id] = r
            peers.append(.init(id: id, name: display))
        }
        TransferHub.shared.androidPeers = peers.sorted { $0.name < $1.name }
    }

    func send(_ urls: [URL], to peer: TransferHub.AndroidPeer) {
        guard let r = found[peer.id] else { return }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let conn = NWConnection(to: r.endpoint, using: NWParameters(tls: nil, tcp: tcp))
        let (eid, n) = (endpointID, name)
        Task { await NearbySession(conn).runOutbound(urls: urls, peer: peer.name, endpointID: eid, name: n) }
    }

    /// Debug: sends a file to this Mac's own listener over loopback, exercising both directions of the protocol.
    func selfTest() {
        guard port != 0 else { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.selfTest() }; return }
        Self.autoAccept = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rokaconnect-selftest.bin")
        try? Data.random(1_500_000).write(to: url)
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let (eid, n) = ("TEST", name)
        Task { await NearbySession(conn).runOutbound(urls: [url], peer: "Self test", endpointID: eid, name: n) }
    }
}
