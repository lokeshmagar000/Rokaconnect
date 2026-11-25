import Foundation
import SwiftUI

/// USB cable mode — the fastest way to move files between this Mac and an Android phone.
///
/// When a phone is plugged in with USB debugging on, this runs `adb reverse tcp:52341 tcp:52341`.
/// The phone app then reaches this Mac at 127.0.0.1:52341 through the cable instead of Wi-Fi, so every
/// Portal feature (send, receive, auto-receive, clipboard) simply runs over USB. Nothing else changes:
/// same encrypted protocol, same pairing. Unplug the cable and the phone goes back to Wi-Fi by itself.
///
/// It needs Google's `adb` tool (Android SDK platform-tools); Rokaconnect only uses it if it's installed.
final class USBLink: ObservableObject {
    static let shared = USBLink()

    struct Phone: Identifiable, Equatable { let id: String; let model: String }   // id = adb serial

    /// Phones plugged in and ready (USB debugging allowed), with the cable link set up.
    @Published private(set) var phones: [Phone] = []
    /// Plugged in but USB debugging still needs to be allowed on the phone.
    @Published private(set) var waitingForApproval = false
    /// Where `adb` is, or nil when it isn't installed.
    @Published private(set) var adbPath: String?

    private var timer: Timer?
    private var linked = Set<String>()          // serials that already have the reverse tunnel
    private let queue = DispatchQueue(label: "rokaconnect.usb", qos: .utility)
    private var busy = false

    /// Usual places adb lives (Android Studio, Homebrew, manual install).
    private static var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
                "\(home)/platform-tools/adb", "\(home)/Downloads/platform-tools/adb"]
    }

    func start() {
        adbPath = Self.candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        timer?.invalidate()
        // every 3 s: look for plugged-in phones and link new ones (cheap: one short adb call)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.check() }
        check()
    }

    private func check() {
        if adbPath == nil { adbPath = Self.candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }
        guard let adb = adbPath, !busy else { return }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let out = Self.run(adb, ["devices", "-l"]) ?? ""
            var ready: [Phone] = [], unauthorized = false
            for line in out.split(separator: "\n").dropFirst() {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2 else { continue }
                let serial = String(parts[0]), state = String(parts[1])
                if state == "unauthorized" { unauthorized = true; continue }
                guard state == "device" else { continue }
                let model = parts.first { $0.hasPrefix("model:") }.map { $0.dropFirst(6).replacingOccurrences(of: "_", with: " ") } ?? "Android phone"
                ready.append(Phone(id: serial, model: model))
            }
            // make sure every plugged-in phone has the cable link (set it up again if something removed it,
            // e.g. adb was restarted by another tool)
            // adb's cable link is the fastest when USB debugging is on (the accessory link without debugging is
            // limited by Android's accessory driver), so it keeps the port; the phone's accessory link takes over
            // by itself whenever adb isn't there
            for p in ready {
                let links = Self.run(adb, ["-s", p.id, "reverse", "--list"]) ?? ""
                if links.contains("tcp:\(Portal.port)") { self.linked.insert(p.id); continue }
                if Self.run(adb, ["-s", p.id, "reverse", "tcp:\(Portal.port)", "tcp:\(Portal.port)"]) != nil { self.linked.insert(p.id) }
            }
            self.linked.formIntersection(ready.map(\.id))
            DispatchQueue.main.async {
                if self.phones != ready { self.phones = ready }
                if self.waitingForApproval != unauthorized { self.waitingForApproval = unauthorized }
                self.busy = false
            }
        }
    }

    /// Runs adb and returns its output (nil if it failed or took longer than 5 s).
    private static func run(_ adb: String, _ args: [String]) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: adb); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// Settings → Portal: the USB cable card.
struct USBSection: View {
    @ObservedObject var usb = USBLink.shared
    @ObservedObject var aoa = AOALink.shared
    var connected: Bool { aoa.connected || !usb.phones.isEmpty }
    var body: some View {
        SectionLabel("USB cable — fastest")
        Card {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(connected ? Brand.cream : Brand.raised)
                    Image(systemName: "cable.connector").font(.system(size: 15, weight: .semibold)).foregroundStyle(Brand.coral)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Brand.ink.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if connected { Circle().fill(Color.green).frame(width: 8, height: 8) }
            }
        }
        Caption("Plug your Android phone into this Mac with a USB-C cable. The first time, the phone asks to open Rokaconnect — tick Always and tap OK. No USB debugging needed. (If USB debugging is on and adb is installed, that works too.)")
    }
    var title: String {
        if aoa.connected { return "Connected by USB cable" }
        if let p = usb.phones.first { return "Connected by USB: \(p.model)" }
        return "Plug in your phone with a USB cable"
    }
    var subtitle: String {
        if connected { return "Sending, receiving and clipboard now go through the cable." }
        return "Rokaconnect switches to the cable by itself — much faster than Wi-Fi."
    }
}
