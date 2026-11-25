import Foundation
import AppKit
import SwiftUI

/// Portal hub: one place for everything sent or received with the Rokaconnect phone app and Android Quick Share.
final class TransferHub: ObservableObject {
    static let shared = TransferHub()

    enum Channel: String { case android = "Android", iphone = "iPhone", web = "Browser" }
    enum Direction { case incoming, outgoing }
    enum State: Equatable { case waiting, active, done, failed(String), declined }

    struct Transfer: Identifiable {
        let id = UUID()
        let direction: Direction
        let channel: Channel
        var peer: String
        var title: String
        var progress: Double = 0
        var state: State = .active
        var files: [URL] = []
        let date = Date()
        var icon: String {
            switch channel { case .android: "candybarphone"; case .iphone: "iphone"; case .web: "qrcode" }
        }
    }

    struct Consent: Identifiable {
        let id: UUID
        let peer: String
        let title: String
        let pin: String
    }

    struct AndroidPeer: Identifiable, Hashable { let id: String; let name: String }
    /// A phone running the Rokaconnect app (it checks in every few seconds).
    struct AppPeer: Identifiable, Hashable {
        var id: String { name }; let name: String; let platform: String; var lastSeen: Date
        var battery: Int? = nil; var charging = false          // reported by the phone on each check-in
    }

    @Published private(set) var transfers: [Transfer] = [] {
        didSet {
            // a transfer just finished → the island shows ✓ Sent / Saved for a moment
            let wasDone = Set(oldValue.filter { $0.state == .done }.map(\.id))
            let oldIDs = Set(oldValue.map(\.id))
            if let t = transfers.first(where: { $0.state == .done && !wasDone.contains($0.id) && oldIDs.contains($0.id) }) {
                justFinished = t
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in if self?.justFinished?.id == t.id { self?.justFinished = nil } }
            }
        }
    }
    @Published var justFinished: Transfer?
    @Published private(set) var consent: Consent?
    @Published var androidPeers: [AndroidPeer] = []
    /// Files this Mac offers to phones (browser page + phone app).
    @Published var outbox: [URL] = []
    /// Stable id per offered file, and which phone it's meant for (nil = any phone).
    private(set) var outboxIDs: [URL: Int] = [:]
    private(set) var outboxTargets: [URL: String] = [:]
    private var nextOutboxID = Int(Date().timeIntervalSince1970) % 1_000_000 * 1000
    @Published var appPeers: [AppPeer] = []
    /// Phones that checked in recently — shown as send targets.
    var onlinePhones: [AppPeer] { appPeers.filter { Date().timeIntervalSince($0.lastSeen) < 20 } }

    // ── automatic clipboard sync ─────────────────────────────────────────────
    private var clipWatch: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    /// The last text that arrived FROM the phone — never sent back (no ping-pong).
    var lastFromPhone: String?

    /// Checks the Mac clipboard twice a second; new text is queued for the phone (silently).
    func startClipboardWatch() {
        clipWatch?.invalidate()
        clipWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let pb = NSPasteboard.general
            guard pb.changeCount != self.lastChangeCount else { return }
            self.lastChangeCount = pb.changeCount
            // passwords and one-time codes from password managers are never sent to the phone
            guard Settings.shared.autoClipboard, !Safety.clipboardIsPrivate(pb), let text = pb.string(forType: .string), !text.isEmpty,
                  text != self.lastFromPhone, text.utf8.count <= 1_000_000 else { return }
            self.pendingClip = (text, Date())          // no history entry: automatic copies stay quiet
        }
    }

    /// Clipboard text waiting to be delivered to the next phone that checks in (Mac → phone).
    private var pendingClip: (text: String, at: Date)?

    private var pendingClipRecord: UUID?

    /// Hands the waiting clipboard to the phone that just checked in (once; expires after 2 minutes).
    func takePendingClip() -> String? {
        guard let p = pendingClip else { return nil }
        pendingClip = nil
        if let id = pendingClipRecord { pendingClipRecord = nil; update(id) { $0.state = Date().timeIntervalSince(p.at) < 120 ? .done : .failed("Phone didn't connect"); $0.progress = 1 } }
        return Date().timeIntervalSince(p.at) < 120 ? p.text : nil
    }

    func phoneCheckedIn(_ name: String, platform: String, battery: Int? = nil, charging: Bool? = nil) {
        // lets the USB accessory mode switch plugged-in Android phones (only once a phone with the app is known)
        if platform == "android", !UserDefaults.standard.bool(forKey: "knowsAndroidPhone") { UserDefaults.standard.set(true, forKey: "knowsAndroidPhone") }
        if let i = appPeers.firstIndex(where: { $0.name == name }) {
            appPeers[i].lastSeen = Date()
            if let battery { appPeers[i].battery = battery; appPeers[i].charging = charging ?? false }
        } else { appPeers.append(AppPeer(name: name, platform: platform, lastSeen: Date(), battery: battery, charging: charging ?? false)) }
    }

    /// Island → Devices → "Ring phone": the phone rings loudly on its next check-in (a few seconds; instantly-ish by cable).
    @Published private(set) var ringRequested: Set<String> = []
    func ring(_ phone: AppPeer) { ringRequested.insert(phone.name) }
    /// Called when that phone checks in: true once, then the request is cleared.
    func takeRing(_ phone: String) -> Bool { ringRequested.remove(phone) != nil }

    /// Sends straight to a phone running the app: it picks the files up on its next check-in and saves them automatically.
    func sendToPhone(_ urls: [URL], _ phone: AppPeer) { addToOutbox(urls, to: phone.name) }

    func removeFromOutbox(_ u: URL) { outbox.removeAll { $0 == u }; outboxIDs[u] = nil; outboxTargets[u] = nil }
    /// Files dropped on the island, waiting for the user to pick where they go.
    @Published var staged: [URL] = []

    private var consentWaiters: [UUID: (Bool) -> Void] = [:]
    private var consentQueue: [Consent] = []
    private let landing = PortalLanding()

    private var ticker: Timer?
    init() {
        // phones drop off the list when they stop checking in
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, !self.appPeers.isEmpty else { return }
            self.appPeers.removeAll { Date().timeIntervalSince($0.lastSeen) > 600 }
            self.objectWillChange.send()
        }
    }

    var active: Transfer? { transfers.first { $0.state == .active || $0.state == .waiting } }

    // MARK: records (always call on main)

    @discardableResult
    func begin(_ dir: Direction, _ channel: Channel, peer: String, title: String, state: State = .active, file: URL? = nil) -> UUID {
        let t = Transfer(direction: dir, channel: channel, peer: peer, title: title, state: state)
        if dir == .outgoing { landing.launch(file: file, label: title) }
        transfers.insert(t, at: 0)
        if transfers.count > 50 { transfers.removeLast(transfers.count - 50) }
        return t.id
    }

    func update(_ id: UUID, _ change: (inout Transfer) -> Void) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[i])
    }

    func progress(_ id: UUID, _ p: Double) { update(id) { $0.progress = p; if $0.state == .waiting { $0.state = .active } } }

    func finish(_ id: UUID, files: [URL] = [], error: String? = nil) {
        update(id) {
            $0.files += files
            if case .declined = $0.state { return }
            $0.state = error.map { .failed($0) } ?? .done
            if error == nil { $0.progress = 1 }
        }
        guard error == nil, let t = transfers.first(where: { $0.id == id }), t.direction == .incoming else { return }
        let first = files.first ?? t.files.first
        landing.land(file: first, style: PortalReceiver.landingStyle(""), label: first?.lastPathComponent ?? t.title, from: t.peer)
    }

    /// Records a transfer that already completed.
    func recordReceived(_ channel: Channel, peer: String, title: String, file: URL?) {
        let id = begin(.incoming, channel, peer: peer, title: title)
        update(id) { $0.state = .done; $0.progress = 1; if let file { $0.files = [file] } }
    }

    // MARK: consent

    /// Asks the user (in the island) whether to accept an incoming transfer. Times out as "decline" after 60 s.
    func askConsent(peer: String, title: String, pin: String, _ reply: @escaping (Bool) -> Void) {
        let c = Consent(id: UUID(), peer: peer, title: title, pin: pin)
        consentWaiters[c.id] = reply
        if consent == nil { consent = c } else { consentQueue.append(c) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.answer(c.id, false) }
    }

    func answer(_ id: UUID, _ accept: Bool) {
        guard let reply = consentWaiters.removeValue(forKey: id) else { return }
        consentQueue.removeAll { $0.id == id }
        if consent?.id == id { consent = consentQueue.isEmpty ? nil : consentQueue.removeFirst() }
        reply(accept)
    }

    // MARK: outbox / staging

    func addToOutbox(_ urls: [URL], to phone: String? = nil) {
        for u in urls {
            if !outbox.contains(u) { outbox.append(u) }
            nextOutboxID += 1; outboxIDs[u] = nextOutboxID     // a fresh id makes phones fetch it again
            outboxTargets[u] = phone
        }
    }

    func pickFiles(_ done: @escaping ([URL]) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true; p.canChooseDirectories = false; p.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        p.begin { r in if r == .OK { done(p.urls) } }
    }

    static func size(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    static func uniqueDestination(_ name: String) -> URL {
        let folder = PortalReceiver.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = (name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-")
        let clean = safe.isEmpty || safe.hasPrefix(".") ? "file" + safe : safe
        var url = folder.appendingPathComponent(clean); var i = 1
        let base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"); i += 1
        }
        return url
    }
}
