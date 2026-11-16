import Foundation
import Network
import AppKit
import CoreImage.CIFilterBuiltins

/// Browser share: a small HTTP server on the local network. Any phone scans the QR code and can send files/text
/// to this Mac or download files the Mac offers. Every request must carry the random token from the QR code.
final class WebShare: ObservableObject {
    static let shared = WebShare()
    @Published private(set) var url: URL?
    @Published private(set) var qr: NSImage?
    @Published private(set) var status = "Off"
    private(set) var token = WebShare.newToken()
    private var listener: NWListener?

    static func newToken() -> String { String((0..<20).map { _ in "abcdefghijkmnpqrstuvwxyz23456789".randomElement()! }) }

    func setEnabled(_ on: Bool) { on ? start() : stop() }

    func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: 8765) ?? .any)
            l.newConnectionHandler = { c in Task { await WebConnection(c).run() } }
            l.stateUpdateHandler = { [weak self] s in
                guard let self else { return }
                switch s {
                case .ready: self.refreshURL(port: l.port?.rawValue ?? 8765)
                case .failed(let e):
                    self.status = "Unavailable: \(e.localizedDescription)"
                    // port taken: retry on any port
                    if self.listener === l { self.listener = nil; l.cancel(); self.startAnyPort() }
                default: break
                }
            }
            l.start(queue: .main)
            listener = l
        } catch { startAnyPort() }
    }

    private func startAnyPort() {
        guard let l = try? NWListener(using: .tcp) else { status = "Unavailable"; return }
        l.newConnectionHandler = { c in Task { await WebConnection(c).run() } }
        l.stateUpdateHandler = { [weak self] s in if case .ready = s { self?.refreshURL(port: l.port?.rawValue ?? 0) } }
        l.start(queue: .main)
        listener = l
    }

    func stop() {
        listener?.cancel(); listener = nil
        url = nil; qr = nil; status = "Off"
    }

    func newLink() {
        token = Self.newToken()
        if let p = url?.port { refreshURL(port: UInt16(p)) }
    }

    private func refreshURL(port: UInt16) {
        guard let ip = Self.lanIPv4() else { status = "Connect this Mac to Wi-Fi"; url = nil; qr = nil; return }
        let u = URL(string: "http://\(ip):\(port)/?t=\(token)")!
        url = u; qr = Self.qrImage(u.absoluteString); status = "Scan with any phone on the same Wi-Fi"
    }

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

    static func qrImage(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8); f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        return img
    }
}

// MARK: - one HTTP connection

private actor WebConnection {
    let conn: NWConnection
    init(_ c: NWConnection) { conn = c }

    struct Request { var method: String; var path: String; var query: [String: String]; var headers: [String: String]; var leftover: Data }

    func run() async {
        defer { conn.cancel() }
        do {
            try await conn.startAndWait()
            guard let req = try await readHeader() else { return }
            let token = await MainActor.run { WebShare.shared.token }
            guard req.query["t"] == token else {
                try await respond(403, "text/html; charset=utf-8", Data(WebPage.expired.utf8)); return
            }
            switch (req.method, req.path) {
            case ("GET", "/"): try await respond(200, "text/html; charset=utf-8", Data(WebPage.html(token: token).utf8))
            case ("GET", "/list"): try await respond(200, "application/json", await listJSON())
            case ("GET", "/dl"): try await download(req)
            case ("POST", "/upload"): try await upload(req)
            case ("POST", "/text"): try await text(req)
            default: try await respond(404, "text/plain", Data("Not found".utf8))
            }
        } catch { /* client went away */ }
    }

    private func recvSome() async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, complete, e in
                if let e { c.resume(throwing: e) }
                else if let d, !d.isEmpty { c.resume(returning: d) }
                else if complete { c.resume(throwing: NearbyShareError.closed) }
                else { c.resume(returning: Data()) }
            }
        }
    }

    private func readHeader() async throws -> Request? {
        var buf = Data()
        let sep = Data("\r\n\r\n".utf8)
        while buf.range(of: sep) == nil {
            buf.append(try await recvSome())
            if buf.count > 32_768 { return nil }
        }
        let r = buf.range(of: sep)!
        let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let comps = URLComponents(string: "http://x" + String(parts[1]))
        var q: [String: String] = [:]
        for item in comps?.queryItems ?? [] { q[item.name] = item.value ?? "" }
        return Request(method: String(parts[0]), path: comps?.path ?? "/", query: q, headers: headers, leftover: Data(buf[r.upperBound...]))
    }

    private func send(_ d: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: d, completion: .contentProcessed { e in if let e { c.resume(throwing: e) } else { c.resume() } })
        }
    }

    private func respond(_ code: Int, _ type: String, _ body: Data, extra: String = "") async throws {
        let reason = [200: "OK", 403: "Forbidden", 404: "Not Found", 400: "Bad Request"][code] ?? "OK"
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\n\(extra)Connection: close\r\n\r\n"
        try await send(Data(head.utf8) + body)
    }

    private func device(_ req: Request) -> String {
        let ua = req.headers["user-agent"] ?? ""
        if ua.contains("iPhone") { return "iPhone" }
        if ua.contains("iPad") { return "iPad" }
        if ua.contains("Android") { return "Android phone" }
        return "Phone"
    }

    private func listJSON() async -> Data {
        let items: [[String: Any]] = await MainActor.run {
            TransferHub.shared.outbox.enumerated().map { i, u in ["id": i, "name": u.lastPathComponent, "size": TransferHub.size(u)] }
        }
        return (try? JSONSerialization.data(withJSONObject: ["mac": Host.current().localizedName ?? "Mac", "files": items])) ?? Data("{}".utf8)
    }

    private func download(_ req: Request) async throws {
        let idx = Int(req.query["id"] ?? "") ?? -1
        let file: URL? = await MainActor.run { TransferHub.shared.outbox.indices.contains(idx) ? TransferHub.shared.outbox[idx] : nil }
        guard let file, let h = try? FileHandle(forReadingFrom: file) else { try await respond(404, "text/plain", Data("Gone".utf8)); return }
        defer { try? h.close() }
        let size = TransferHub.size(file)
        let name = file.lastPathComponent
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"
        let peer = device(req)
        let hid = await MainActor.run { TransferHub.shared.begin(.outgoing, .web, peer: peer, title: name, file: file) }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(size)\r\n" +
            "Content-Disposition: attachment; filename*=UTF-8''\(encoded)\r\nConnection: close\r\n\r\n"
        try await send(Data(head.utf8))
        var sent: Int64 = 0
        do {
            while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
                try await send(chunk); sent += Int64(chunk.count)
                let p = size > 0 ? Double(sent) / Double(size) : 1
                await MainActor.run { TransferHub.shared.progress(hid, p) }
            }
            await MainActor.run { TransferHub.shared.update(hid) { $0.state = .done; $0.progress = 1 } }
        } catch {
            await MainActor.run { TransferHub.shared.finish(hid, error: "Download interrupted") }
            throw error
        }
    }

    private func upload(_ req: Request) async throws {
        guard let len = Int64(req.headers["content-length"] ?? ""), len >= 0 else {
            try await respond(400, "text/plain", Data("Length required".utf8)); return
        }
        let name = (req.query["name"] ?? "").isEmpty ? "file" : req.query["name"]!
        let dest = TransferHub.uniqueDestination(name)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let h = try FileHandle(forWritingTo: dest)
        let peer = device(req)
        let hid = await MainActor.run { TransferHub.shared.begin(.incoming, .web, peer: peer, title: dest.lastPathComponent) }
        var got: Int64 = 0
        do {
            var chunk = req.leftover
            while true {
                if !chunk.isEmpty {
                    let take = chunk.prefix(Int(min(Int64(chunk.count), len - got)))
                    try h.write(contentsOf: take); got += Int64(take.count)
                    let p = len > 0 ? Double(got) / Double(len) : 1
                    await MainActor.run { TransferHub.shared.progress(hid, p) }
                }
                if got >= len { break }
                chunk = try await recvSome()
            }
            try h.close()
            await MainActor.run { TransferHub.shared.finish(hid, files: [dest]) }
            try await respond(200, "application/json", Data("{\"ok\":true}".utf8))
        } catch {
            try? h.close(); try? FileManager.default.removeItem(at: dest)
            await MainActor.run { TransferHub.shared.finish(hid, error: "Upload interrupted") }
        }
    }

    private func text(_ req: Request) async throws {
        let len = Int(req.headers["content-length"] ?? "") ?? 0
        guard len <= 1_000_000 else { try await respond(400, "text/plain", Data("Too long".utf8)); return }
        var body = req.leftover
        while body.count < len { body.append(try await recvSome()) }
        let s = String(decoding: body.prefix(len), as: UTF8.self)
        let peer = device(req)
        await MainActor.run {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
            let id = TransferHub.shared.begin(.incoming, .web, peer: peer, title: "Text copied to clipboard")
            TransferHub.shared.finish(id)
        }
        try await respond(200, "application/json", Data("{\"ok\":true}".utf8))
    }
}

// MARK: - page

enum WebPage {
    static let expired = """
    <!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><body style="font:16px -apple-system,system-ui,sans-serif;background:#111;color:#eee;display:grid;place-items:center;height:90vh;text-align:center">
    <div><h2>Link expired</h2><p>Scan the QR code on your Mac again.</p></div></body>
    """

    static func html(token: String) -> String {
        """
        <!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>Rokaconnect</title><meta name=theme-color content="#0b0b12">
        <style>
        :root{color-scheme:dark}
        *{box-sizing:border-box}
        body{margin:0;min-height:100vh;font:16px -apple-system,system-ui,Roboto,sans-serif;color:#f4f4f8;
          background:radial-gradient(1200px 600px at 10% -10%,#5b3cc4 0,transparent 60%),radial-gradient(900px 600px at 110% 20%,#c43c8f 0,transparent 55%),radial-gradient(900px 700px at 50% 120%,#1e7bd8 0,transparent 60%),#0b0b12;
          padding:max(20px,env(safe-area-inset-top)) 16px 40px}
        .wrap{max-width:520px;margin:0 auto;display:grid;gap:16px}
        h1{font-size:22px;margin:8px 4px 0}.sub{opacity:.65;margin:0 4px 6px;font-size:14px}
        .glass{background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.18);border-radius:24px;padding:18px;
          backdrop-filter:blur(30px) saturate(180%);-webkit-backdrop-filter:blur(30px) saturate(180%);box-shadow:inset 0 1px 0 rgba(255,255,255,.25),0 10px 30px rgba(0,0,0,.25)}
        h2{font-size:15px;margin:0 0 12px;opacity:.85}
        .btn{display:block;width:100%;padding:14px;border-radius:999px;border:1px solid rgba(255,255,255,.3);background:rgba(255,255,255,.14);
          color:#fff;font-weight:600;font-size:16px;text-align:center;cursor:pointer}
        .btn:active{transform:scale(.98)}
        textarea{width:100%;min-height:80px;border-radius:16px;border:1px solid rgba(255,255,255,.2);background:rgba(0,0,0,.25);color:#fff;padding:12px;font:inherit;margin-bottom:10px}
        .row{display:flex;align-items:center;gap:10px;padding:10px 0;border-top:1px solid rgba(255,255,255,.08)}
        .row:first-child{border-top:0}.name{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .size{opacity:.55;font-size:13px}
        a.dl{color:#fff;text-decoration:none;padding:8px 14px;border-radius:999px;background:rgba(255,255,255,.16);font-size:14px;font-weight:600}
        .bar{height:4px;border-radius:4px;background:rgba(255,255,255,.15);overflow:hidden;margin-top:6px}.bar i{display:block;height:100%;width:0;background:#fff}
        .empty{opacity:.5;font-size:14px}
        </style></head><body><div class=wrap>
        <h1 id=mac>Rokaconnect</h1><p class=sub>Connected over your Wi-Fi. Files go straight to the Mac.</p>
        <div class=glass><h2>Send to Mac</h2>
          <input id=f type=file multiple hidden><label class=btn for=f>Choose photos or files</label>
          <div id=up></div></div>
        <div class=glass><h2>Send text or a link</h2>
          <textarea id=t placeholder="Paste text or a link — it lands on the Mac's clipboard"></textarea>
          <button class=btn id=ts>Send text</button></div>
        <div class=glass><h2>From Mac</h2><div id=list><p class=empty>Nothing shared yet.</p></div></div>
        </div><script>
        const T=\(jsString(token));
        const q=p=>p+(p.includes('?')?'&':'?')+'t='+T;
        const fmt=n=>n<1024?n+' B':n<1048576?(n/1024).toFixed(0)+' KB':n<1073741824?(n/1048576).toFixed(1)+' MB':(n/1073741824).toFixed(2)+' GB';
        const esc=s=>s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
        document.getElementById('f').onchange=e=>{[...e.target.files].forEach(send);e.target.value=''};
        function send(file){
          const row=document.createElement('div');row.className='row';
          row.innerHTML='<div class=name>'+esc(file.name)+'<div class=bar><i></i></div></div><span class=size>'+fmt(file.size)+'</span>';
          document.getElementById('up').appendChild(row);
          const x=new XMLHttpRequest();x.open('POST',q('/upload?name='+encodeURIComponent(file.name)));
          x.upload.onprogress=e=>{if(e.lengthComputable)row.querySelector('i').style.width=(100*e.loaded/e.total)+'%'};
          x.onload=()=>{row.querySelector('.size').textContent=x.status==200?'Sent ✓':'Failed'};
          x.onerror=()=>{row.querySelector('.size').textContent='Failed'};
          x.send(file);
        }
        document.getElementById('ts').onclick=async()=>{
          const v=document.getElementById('t').value;if(!v.trim())return;
          const r=await fetch(q('/text'),{method:'POST',body:v});
          document.getElementById('ts').textContent=r.ok?'Copied on Mac ✓':'Failed';
          setTimeout(()=>document.getElementById('ts').textContent='Send text',2000);
        };
        async function refresh(){
          try{const r=await fetch(q('/list'));if(!r.ok)return;const j=await r.json();
            document.getElementById('mac').textContent=j.mac;
            const l=document.getElementById('list');
            l.innerHTML=j.files.length?j.files.map(f=>'<div class=row><span class=name>'+esc(f.name)+'</span><span class=size>'+fmt(f.size)+'</span><a class=dl href="'+q('/dl?id='+f.id)+'">Save</a></div>').join(''):'<p class=empty>Nothing shared yet.</p>';
          }catch(e){}
        }
        refresh();setInterval(refresh,3000);
        </script></body></html>
        """
    }

    private static func jsString(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
    }
}
