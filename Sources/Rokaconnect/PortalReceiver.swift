import Foundation
import Network
import AppKit
import AVFoundation
import SwiftUI
import CryptoKit

final class PortalReceiver: ObservableObject {
    @Published var status = "Starting…"
    @Published var code: String
    @Published var lastReceived = ""
    private var listener: NWListener?
    private var key: SymmetricKey
    private let landing = PortalLanding()
    static let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Rokaconnect", isDirectory: true)

    init() {
        let c = UserDefaults.standard.string(forKey: "portalCode") ?? Portal.newCode()
        UserDefaults.standard.set(c, forKey: "portalCode")
        code = c; key = Portal.key(for: c)
    }

    func start() {
        listener?.cancel()
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Portal.port)!)
            l.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: Portal.service)
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.stateUpdateHandler = { [weak self] s in
                DispatchQueue.main.async {
                    switch s {
                    case .ready: self?.status = "Ready — waiting for your iPhone"
                    case .failed(let e): self?.status = "Portal unavailable: \(e.localizedDescription)"
                    default: break
                    }
                }
            }
            l.start(queue: .global()); listener = l
        } catch { status = "Portal unavailable: \(error.localizedDescription)" }
    }

    func regenerate() {
        let c = Portal.newCode()
        UserDefaults.standard.set(c, forKey: "portalCode")
        code = c; key = Portal.key(for: c)
    }

    private func handle(_ conn: NWConnection) {
        let key = self.key
        Task.detached {
            defer { conn.cancel() }
            do {
                try await conn.startAndWait()
                let hdr = try JSONDecoder().decode(PortalHeader.self, from: try await conn.recvFrame(key))
                guard abs(Date().timeIntervalSince1970 - hdr.ts) < 120 else { throw PortalError.expired }
                if hdr.kind == "list" || hdr.kind == "get" { try await Self.serveOutbox(hdr, conn, key); return }
                if hdr.kind == "clipget" { try await Self.serveClipboard(hdr, conn, key); return }
                var text = Data(); var dest: URL?; var writer: FrameWriter?
                var hid: UUID?
                if hdr.kind == "file" {
                    try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                    dest = Self.unique(hdr.name); FileManager.default.createFile(atPath: dest!.path, contents: nil)
                    writer = FrameWriter(try FileHandle(forWritingTo: dest!), key: key)
                    // show it on the island while it arrives (↓ and a percentage)
                    let channel: TransferHub.Channel = hdr.platform == "android" ? .android : .iphone
                    let name = dest!.lastPathComponent, peer = hdr.from.isEmpty ? channel.rawValue : hdr.from
                    hid = await MainActor.run { TransferHub.shared.begin(.incoming, channel, peer: peer, title: name, file: dest) }
                } else { guard hdr.size <= 5_000_000 else { throw PortalError.badFrame } }
                var got: Int64 = 0, shown = 0.0
                do {
                    while got < hdr.size {
                        let body = try await conn.recvSealed()
                        got += Int64(body.count - 28)
                        if got > hdr.size { throw PortalError.badFrame }
                        if let writer { try writer.add(body) } else { text.append(try Portal.open(body, key)) }
                        let p = Double(got) / Double(max(hdr.size, 1))
                        if let hid, p - shown >= 0.01 || got == hdr.size { shown = p; await MainActor.run { TransferHub.shared.progress(hid, p) } }
                    }
                    try writer?.finish()
                } catch {
                    writer?.cancel()
                    if let dest { try? FileManager.default.removeItem(at: dest) }        // no half files left behind
                    if let hid { await MainActor.run { TransferHub.shared.finish(hid, error: "Interrupted") } }
                    throw error
                }
                try await conn.sendFrame(Data("OK".utf8), key)
                await MainActor.run { self.received(hdr, file: dest, text: text, transfer: hid) }
            } catch { /* wrong code, expired or dropped connection: ignore */ }
        }
    }

    /// Phone asks what the Mac offers ("list") or downloads one item ("get", name = index).
    /// Reply for get: JSON {name,size} frame, then the file in chunks.
    private static func serveOutbox(_ hdr: PortalHeader, _ conn: NWConnection, _ key: SymmetricKey) async throws {
        let phone = hdr.from.isEmpty ? "Phone" : hdr.from
        let offered: [(id: Int, url: URL, to: String?)] = await MainActor.run {
            let hub = TransferHub.shared
            hub.phoneCheckedIn(phone, platform: hdr.platform ?? "ios")
            return hub.outbox.compactMap { u in
                guard let id = hub.outboxIDs[u] else { return nil }
                let to = hub.outboxTargets[u]
                return (to == nil || to == phone) ? (id, u, to) : nil
            }
        }
        if hdr.kind == "list" {
            let items = offered.map { ["id": $0.id, "name": $0.url.lastPathComponent, "size": TransferHub.size($0.url), "direct": $0.to != nil] as [String: Any] }
            // a clipboard the Mac sent to the phone (menu bar → Send Clipboard to Phone) rides along
            var reply: [String: Any] = ["mac": Host.current().localizedName ?? "Mac", "files": items]
            if let clip = await MainActor.run(body: { TransferHub.shared.takePendingClip() }) { reply["clip"] = clip }
            try await conn.sendFrame(try JSONSerialization.data(withJSONObject: reply), key)
            return
        }
        guard let want = Int(hdr.name), let item = offered.first(where: { $0.id == want }),
              let fh = try? FileHandle(forReadingFrom: item.url) else {
            try await conn.sendFrame(Data("{\"error\":\"gone\"}".utf8), key); return
        }
        defer { try? fh.close() }
        let file = item.url, size = TransferHub.size(file)
        try await conn.sendFrame(try JSONSerialization.data(withJSONObject: ["name": file.lastPathComponent, "size": size]), key)
        let channel: TransferHub.Channel = hdr.platform == "android" ? .android : .iphone
        let peer = hdr.from.isEmpty ? channel.rawValue : hdr.from
        let hid = await MainActor.run { TransferHub.shared.begin(.outgoing, channel, peer: peer, title: file.lastPathComponent, file: file) }
        do {
            var shown = 0.0
            try await conn.streamFile(fh, key: key) { sent in
                let p = size > 0 ? Double(sent) / Double(size) : 1
                if p - shown >= 0.01 || p >= 1 { shown = p; DispatchQueue.main.async { TransferHub.shared.progress(hid, p) } }
            }
            _ = try? await conn.recvFrame(key)   // phone's "OK"
            await MainActor.run {
                TransferHub.shared.update(hid) { $0.state = .done; $0.progress = 1 }
                if item.to != nil { TransferHub.shared.removeFromOutbox(file) }   // direct sends are delivered once
            }
        } catch {
            await MainActor.run { TransferHub.shared.finish(hid, error: "Download interrupted") }
            throw error
        }
    }

    /// Phone asks for the Mac's clipboard (island → "From Mac"): reply with the text.
    private static func serveClipboard(_ hdr: PortalHeader, _ conn: NWConnection, _ key: SymmetricKey) async throws {
        let text: String = await MainActor.run {
            TransferHub.shared.phoneCheckedIn(hdr.from.isEmpty ? "Phone" : hdr.from, platform: hdr.platform ?? "ios")
            let t = NSPasteboard.general.string(forType: .string) ?? ""
            let id = TransferHub.shared.begin(.outgoing, hdr.platform == "android" ? .android : .iphone, peer: hdr.from.isEmpty ? "Phone" : hdr.from, title: "Clipboard")
            TransferHub.shared.update(id) { $0.state = .done; $0.progress = 1 }
            return t
        }
        try await conn.sendFrame(Data(String(text.prefix(1_000_000)).utf8), key)
    }

    private static func unique(_ name: String) -> URL {
        let safe = (name as NSString).lastPathComponent.isEmpty ? "file" : (name as NSString).lastPathComponent
        var url = folder.appendingPathComponent(safe); var i = 1
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"); i += 1
        }
        return url
    }

    static func landingStyle(_ fromPhone: String) -> String {
        Settings.shared.portalEffects ? Settings.shared.portalStyle : "fade"
    }

    @MainActor private func received(_ h: PortalHeader, file: URL?, text: Data, transfer: UUID? = nil) {
        // automatic clipboard sync from the phone: just set the clipboard, quietly
        if file == nil, h.name == "auto-clipboard" {
            let s = String(decoding: text, as: UTF8.self)
            TransferHub.shared.lastFromPhone = s
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
            return
        }
        // a manual send also must not bounce back to the phone
        if file == nil { TransferHub.shared.lastFromPhone = String(decoding: text, as: UTF8.self) }
        if let transfer, let file { TransferHub.shared.finish(transfer, files: [file]) }     // the hub plays the arrival animation
        else {
            TransferHub.shared.recordReceived(h.platform == "android" ? .android : .iphone,
                                              peer: h.from.isEmpty ? (h.platform == "android" ? "Android" : "iPhone") : h.from,
                                              title: file?.lastPathComponent ?? "Clipboard", file: file)
        }
        if let file {
            lastReceived = file.lastPathComponent
            if transfer == nil { landing.land(file: file, style: Self.landingStyle(h.transition), label: file.lastPathComponent, from: h.from) }
        } else {
            let s = String(decoding: text, as: UTF8.self)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
            lastReceived = "Clipboard"
            landing.land(file: nil, style: Self.landingStyle(h.transition), label: "Clipboard copied", from: h.from)
        }
    }
}

/// Decrypts and saves incoming frames on its own thread, so the network never waits for the disk.
final class FrameWriter {
    private let fh: FileHandle, key: SymmetricKey
    private let queue = DispatchQueue(label: "rokaconnect.portal.write", qos: .userInitiated)
    private let window = DispatchSemaphore(value: 8)            // at most 8 MB waiting in memory
    private let lock = NSLock(); private var failure: Error?
    init(_ fh: FileHandle, key: SymmetricKey) { self.fh = fh; self.key = key }
    private func failed() -> Error? { lock.lock(); defer { lock.unlock() }; return failure }
    func add(_ body: Data) throws {
        if let e = failed() { throw e }
        window.wait()
        queue.async { [self] in
            defer { window.signal() }
            guard failed() == nil else { return }
            do { try fh.write(contentsOf: try Portal.open(body, key)) }
            catch { lock.lock(); failure = error; lock.unlock() }
        }
    }
    func finish() throws { queue.sync {}; try? fh.close(); if let e = failed() { throw e } }
    func cancel() { queue.sync {}; try? fh.close() }
}

// MARK: landing animation

struct FlightView: View, Animatable {
    var t: Double
    var style: String
    var image: NSImage
    var label: String
    var start: CGPoint, ctrl: CGPoint, end: CGPoint
    var animatableData: Double { get { t } set { t = newValue } }

    func pt(_ u: Double) -> CGPoint {
        let a = (1 - u) * (1 - u), b = 2 * (1 - u) * u, c = u * u
        return CGPoint(x: a * start.x + b * ctrl.x + c * end.x, y: a * start.y + b * ctrl.y + c * end.y)
    }
    var body: some View {
        let p = pt(t)
        ZStack {
            if style == "rainbow" {
                Path { path in
                    path.move(to: start)
                    var u = 0.0; while u <= t { path.addLine(to: pt(u)); u += 0.02 }
                    path.addLine(to: p)
                }
                .stroke(LinearGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
                .opacity(1 - max(0, (t - 0.8) * 4))
            }
            if style == "volcano" {
                ForEach(0..<28, id: \.self) { i in
                    let ang = Double(i) / 28 * 2 * .pi, r = (40 + Double(i % 5) * 28) * t
                    Circle().fill([Color.red, .orange, .yellow][i % 3])
                        .frame(width: 10 + CGFloat(i % 4) * 4)
                        .position(x: p.x + cos(ang) * r, y: p.y + sin(ang) * r - 30 * t)
                        .opacity(max(0, 1 - t) * 0.9)
                }
            }
            if style == "plane" && t < 0.8 {
                Image(systemName: "paperplane.fill").font(.system(size: 54)).foregroundStyle(.white)
                    .shadow(radius: 8).rotationEffect(.degrees(-20 + 50 * t)).position(p)
            } else {
                VStack(spacing: 6) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 150, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 22)).shadow(radius: 16)
                    Text(label).font(.caption.bold()).foregroundStyle(.white).shadow(radius: 4).lineLimit(1).frame(maxWidth: 170)
                }
                .scaleEffect(style == "plane" ? min(1, 0.5 + (t - 0.8) * 5) : 0.6 + 0.4 * t)
                .position(p)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: portal arrival (files coming in)

/// Receiving: a portal spins open just under the notch, the file grows out of it and drops towards you,
/// then the portal closes and the card fades. Timeline (2.2 s): 0–18% open · 18–60% file out · 62–80% close · 85–100% fade.
struct PortalArrivalView: View, Animatable {
    var t: Double
    let image: NSImage, label: String
    let center: CGPoint, landY: CGFloat
    var animatableData: Double { get { t } set { t = newValue } }

    static func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { min(max((t - a) / (b - a), 0), 1) }
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func back(_ x: Double) -> Double { let c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2) }  // overshoots, then settles

    var body: some View {
        let open = Self.back(Self.seg(t, 0, 0.18)) * (1 - Self.easeOut(Self.seg(t, 0.62, 0.8)))
        let out = Self.back(Self.seg(t, 0.18, 0.6))
        let fade = 1 - Self.seg(t, 0.85, 1)
        ZStack {
            PortalRing(spin: t * 540)
                .frame(width: 260, height: 260)
                .scaleEffect(max(0.001, open)).opacity(min(1, max(0, open)))
                .position(center)
            VStack(spacing: 8) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Brand.gradient, lineWidth: 1.5))
                    .shadow(color: Brand.coral.opacity(0.45), radius: 22)
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1).frame(maxWidth: 190)
                    .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(Color.black.opacity(0.55)))
                    .opacity(Self.seg(t, 0.5, 0.62))
            }
            .scaleEffect(0.05 + 0.95 * out)
            .rotationEffect(.degrees(-25 * (1 - out)))
            .position(x: center.x, y: center.y + (landY - center.y) * out)
            .opacity(t < 0.18 ? 0 : fade)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The portal itself: soft glow, a spinning orange→pink ring, two inner rings turning the other way, orbiting sparks.
struct PortalRing: View {
    let spin: Double
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) / 2
            func circle(_ rr: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)) }
            let ringColors = Gradient(colors: [Brand.orange, Brand.coral, Brand.pink, Brand.coral, Brand.orange])
            ctx.fill(circle(r), with: .radialGradient(Gradient(colors: [Brand.coral.opacity(0.45), .clear]), center: c, startRadius: 0, endRadius: r))
            ctx.fill(circle(r * 0.62), with: .color(Color(red: 0.045, green: 0.03, blue: 0.025)))
            ctx.fill(circle(r * 0.6), with: .radialGradient(Gradient(colors: [Brand.pink.opacity(0.35), .clear]), center: c, startRadius: 0, endRadius: r * 0.6))
            func turned(_ deg: Double, _ draw: (inout GraphicsContext) -> Void) {
                var g = ctx; g.translateBy(x: c.x, y: c.y); g.rotate(by: .degrees(deg)); g.translateBy(x: -c.x, y: -c.y); draw(&g)
            }
            turned(spin) { $0.stroke(circle(r * 0.66), with: .conicGradient(ringColors, center: c), lineWidth: r * 0.09) }
            turned(-spin * 1.4) { g in
                var a = Path(); a.addArc(center: c, radius: r * 0.5, startAngle: .degrees(20), endAngle: .degrees(270), clockwise: false)
                g.stroke(a, with: .conicGradient(ringColors, center: c), style: StrokeStyle(lineWidth: r * 0.035, lineCap: .round))
            }
            turned(spin * 2) { g in
                var a = Path(); a.addArc(center: c, radius: r * 0.34, startAngle: .degrees(200), endAngle: .degrees(40), clockwise: false)
                g.opacity = 0.55
                g.stroke(a, with: .conicGradient(ringColors, center: c), style: StrokeStyle(lineWidth: r * 0.025, lineCap: .round))
            }
            for i in 0..<12 {                                            // sparks
                let ang = (spin * 1.2 + Double(i) * 30) * .pi / 180
                let rr = r * (0.78 + 0.08 * sin(Double(i) * 1.7 + spin / 40))
                let dot: Color = i % 3 == 0 ? Brand.cream : (i % 2 == 0 ? Brand.orange : Brand.pink)
                let sz = r * (0.018 + 0.012 * CGFloat(i % 3))
                let p = CGPoint(x: c.x + rr * cos(ang), y: c.y + rr * sin(ang))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - sz, y: p.y - sz, width: sz * 2, height: sz * 2)),
                         with: .color(dot.opacity(0.5 + 0.5 * abs(sin(Double(i) + spin / 60)))))
            }
        }
    }
}

struct PortalArrivalRoot: View {
    let image: NSImage, label: String, center: CGPoint, landY: CGFloat
    @State private var t = 0.0
    var body: some View {
        PortalArrivalView(t: t, image: image, label: label, center: center, landY: landY)
            .onAppear {
                withAnimation(.linear(duration: 2.2)) { t = 1 }
                // a soft tap on the trackpad as the file lands
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
            }
    }
}

struct LandingRoot: View {
    let style: String, image: NSImage, label: String
    let start: CGPoint, ctrl: CGPoint, end: CGPoint
    @State private var t = 0.0
    @State private var fade = 1.0
    var body: some View {
        FlightView(t: t, style: style, image: image, label: label, start: start, ctrl: ctrl, end: end)
            .opacity(fade)
            .onAppear {
                withAnimation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 1.2)) { t = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { withAnimation(.easeOut(duration: 0.5)) { fade = 0 } }
            }
    }
}

struct LaunchRoot: View {
    let image: NSImage, label: String
    let start: CGPoint, ctrl: CGPoint, end: CGPoint
    @State private var t = 0.0
    var body: some View {
        LaunchFlight(t: t, image: image, label: label, start: start, ctrl: ctrl, end: end)
            .onAppear { withAnimation(.timingCurve(0.5, 0, 0.75, 0.3, duration: 0.9)) { t = 1 } }
    }
}

/// Sending: the item lifts off, arcs up and shrinks into the notch.
struct LaunchFlight: View, Animatable {
    var t: Double
    let image: NSImage, label: String
    let start: CGPoint, ctrl: CGPoint, end: CGPoint
    var animatableData: Double { get { t } set { t = newValue } }
    var body: some View {
        let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
        let p = CGPoint(x: a * start.x + b * ctrl.x + c * end.x, y: a * start.y + b * ctrl.y + c * end.y)
        VStack(spacing: 6) {
            Image(nsImage: image).resizable().scaledToFill().frame(width: 130, height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 22)).shadow(radius: 14)
            Text(label).font(.caption.bold()).foregroundStyle(.white).shadow(radius: 4).lineLimit(1).frame(maxWidth: 160)
                .opacity(max(0, 1 - t * 2))
        }
        .scaleEffect(max(0.05, 1 - 0.95 * t))
        .opacity(t > 0.9 ? (1 - t) * 10 : 1)
        .position(p)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

final class PortalLanding {
    private var panel: NSPanel?

    /// Outgoing transfer: the file flies from the pointer up into the notch.
    func launch(file: URL?, label: String) {
        let mouse = NSEvent.mouseLocation
        let sc = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        let start = CGPoint(x: min(max(mouse.x - sc.frame.minX, 120), sc.frame.width - 120),
                            y: min(max(sc.frame.maxY - mouse.y, 200), sc.frame.height - 160))
        let end = CGPoint(x: sc.frame.width / 2, y: 14)
        let ctrl = CGPoint(x: (start.x + end.x) / 2, y: max(start.y, 260) + 40)
        thumbnail(file) { img in
            DispatchQueue.main.async {
                self.panel?.orderOut(nil)
                let p = NSPanel(contentRect: sc.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
                p.ignoresMouseEvents = true; p.level = .screenSaver
                p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
                p.contentView = NSHostingView(rootView: LaunchRoot(image: img, label: label, start: start, ctrl: ctrl, end: end))
                p.setFrame(sc.frame, display: true); p.orderFrontRegardless()
                self.panel = p
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if self.panel === p { p.orderOut(nil) } }
            }
        }
    }
    func land(file: URL?, style: String, label: String, from: String) {
        let mouse = NSEvent.mouseLocation
        let sc = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        let end = CGPoint(x: min(max(mouse.x - sc.frame.minX, 160), sc.frame.width - 160),
                          y: min(max(sc.frame.maxY - mouse.y, 160), sc.frame.height - 160))
        let (start, ctrl): (CGPoint, CGPoint) = style == "fade" ? (end, end) : style == "volcano"
            ? (CGPoint(x: end.x, y: sc.frame.height + 120), CGPoint(x: end.x - 120, y: end.y + 200))
            : (CGPoint(x: -120, y: end.y + 160), CGPoint(x: end.x * 0.4, y: end.y - 280))
        thumbnail(file) { img in
            DispatchQueue.main.async {
                self.panel?.orderOut(nil)
                let p = NSPanel(contentRect: sc.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
                p.ignoresMouseEvents = true; p.level = .screenSaver
                p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
                if style == "portal" {
                    // the portal opens under the notch of the screen the island is on
                    let main = NSScreen.main ?? sc
                    p.setFrame(main.frame, display: false)
                    p.contentView = NSHostingView(rootView: PortalArrivalRoot(image: img, label: label,
                        center: CGPoint(x: main.frame.width / 2, y: 175), landY: main.frame.height * 0.46))
                    p.orderFrontRegardless(); self.panel = p
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { if self.panel === p { p.orderOut(nil) } }
                    return
                }
                p.contentView = NSHostingView(rootView: LandingRoot(style: style, image: img, label: label, start: start, ctrl: ctrl, end: end))
                p.setFrame(sc.frame, display: true); p.orderFrontRegardless()
                self.panel = p
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if self.panel === p { p.orderOut(nil) } }
            }
        }
    }

    private func thumbnail(_ file: URL?, _ done: @escaping (NSImage) -> Void) {
        guard let file else { done(NSImage(systemSymbolName: "doc.on.clipboard.fill", accessibilityDescription: nil) ?? NSImage()); return }
        if let img = NSImage(contentsOf: file), img.isValid, ["jpg","jpeg","png","heic","gif","tiff","webp"].contains(file.pathExtension.lowercased()) { done(img); return }
        if ["mov","mp4","m4v"].contains(file.pathExtension.lowercased()) {
            DispatchQueue.global().async {
                let g = AVAssetImageGenerator(asset: AVURLAsset(url: file)); g.appliesPreferredTrackTransform = true
                if let cg = try? g.copyCGImage(at: .zero, actualTime: nil) { done(NSImage(cgImage: cg, size: .zero)) }
                else { done(NSWorkspace.shared.icon(forFile: file.path)) }
            }
            return
        }
        done(NSWorkspace.shared.icon(forFile: file.path))
    }
}

struct PortalSection: View {
    @ObservedObject var p: PortalReceiver
    @ObservedObject var s = Settings.shared
    /// rokaconnect://pair?c=CODE&h=IP&p=PORT&n=NAME — the phone app pairs and remembers where the Mac is.
    static func pairingQR(_ code: String) -> NSImage? {
        var c = URLComponents(); c.scheme = "rokaconnect"; c.host = "pair"
        c.queryItems = [URLQueryItem(name: "c", value: code), URLQueryItem(name: "p", value: String(Portal.port)),
                        URLQueryItem(name: "n", value: Host.current().localizedName ?? "Mac")]
        if let ip = WebShare.lanIPv4() { c.queryItems?.append(URLQueryItem(name: "h", value: ip)) }
        return c.url.flatMap { WebShare.qrImage($0.absoluteString) }
    }

    static let effects: [(id: String, name: String, sub: String, icon: String, colors: [Color])] = [
        ("portal", "Portal", "Opens under the notch", "circle.dashed", [Brand.orange, Brand.pink]),
        ("rainbow", "Rainbow", "A band of light", "rainbow", [.red, .orange, .yellow, .green, .blue, .purple]),
        ("plane", "Paper Plane", "Folded and flown", "paperplane.fill", [Color(white: 0.85), Color(white: 0.55)]),
        ("volcano", "Volcano", "Into the fire", "flame.fill", [.orange, .red]),
        ("classic", "Classic", "A simple glide", "arrow.right", [Color(red: 0.4, green: 0.6, blue: 1), Color(red: 0.6, green: 0.4, blue: 1)]),
    ]
    var body: some View {
        ShareHubSection()
        SectionLabel("iPhone — Portal app")
        Card {
            HStack(alignment: .top, spacing: 14) {
                if let qr = Self.pairingQR(p.code) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 112, height: 112)
                        .padding(7).background(RoundedRectangle(cornerRadius: 12).fill(.white))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pairing code").font(.system(size: 12.5, weight: .medium))
                    Text(Portal.pretty(p.code)).font(.system(size: 20, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    Text("Scan with the Rokaconnect phone app (or the phone camera) to pair instantly, or type the code.")
                        .font(.system(size: 10.5)).opacity(0.6).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("New code") { p.regenerate() }.buttonStyle(.plain).foregroundStyle(Brand.accent)
                Spacer()
                Button("Open received files") {
                    try? FileManager.default.createDirectory(at: PortalReceiver.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(PortalReceiver.folder)
                }.buttonStyle(.plain).foregroundStyle(Brand.accent)
            }
        }
        Caption(p.status + (p.lastReceived.isEmpty ? "" : " · Last received: \(p.lastReceived)"))
        SectionLabel("Effect")
        Card { ToggleRow(title: "Effects", on: $s.portalEffects) }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(Self.effects, id: \.id) { e in
                Button { s.portalStyle = e.id } label: {
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color(white: 0.08), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
                        Image(systemName: e.icon).font(.system(size: 34))
                            .foregroundStyle(LinearGradient(colors: e.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.name).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            Text(e.sub).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                        }.padding(10)
                        if s.portalStyle == e.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Brand.accent).font(.system(size: 16))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(8)
                        }
                    }
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(s.portalStyle == e.id ? Brand.accent : Color.white.opacity(0.08), lineWidth: s.portalStyle == e.id ? 2 : 1))
                    .opacity(s.portalEffects ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!s.portalEffects)
            }
        }
        Caption("How files from your phone arrive on this Mac. With Effects off, they simply fade in.")
        TransferHistory()
    }
}
