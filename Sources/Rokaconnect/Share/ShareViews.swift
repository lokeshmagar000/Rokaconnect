import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name { static let openPortalPage = Notification.Name("rokaconnect.openPortalPage") }

/// Glass capsule button used across the share UI.
struct GlassPill: View {
    let title: String
    var icon: String? = nil
    var prominent = false
    let action: () -> Void
    var label: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
    }
    @State private var hover = false
    var body: some View {
        // main action: the brand gradient with dark text · others: a raised warm capsule (like the Android app)
        Button(action: action) {
            label.foregroundStyle(prominent ? Brand.onAccent : Brand.ink)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(prominent ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Brand.raised)))
                .overlay(Capsule().stroke(Brand.ink.opacity(hover ? 0.18 : 0.06), lineWidth: 1))
                .contentShape(Capsule())
                .scaleEffect(hover ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { hover = h } }
    }
}

// MARK: - Island cards

struct ConsentCard: View {
    let consent: TransferHub.Consent
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "candybarphone").font(.system(size: 22)).frame(width: 40, height: 40).glass(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(consent.peer) is sharing").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(consent.title).font(.system(size: 12)).opacity(0.7).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !consent.pin.isEmpty {
                    VStack(spacing: 0) {
                        Text("PIN").font(.system(size: 9, weight: .semibold)).opacity(0.55)
                        Text(consent.pin).font(.system(size: 15, weight: .bold).monospacedDigit())
                    }
                }
            }
            HStack(spacing: 10) {
                GlassPill(title: "Decline") { TransferHub.shared.answer(consent.id, false) }
                GlassPill(title: "Accept", icon: "arrow.down", prominent: true) { TransferHub.shared.answer(consent.id, true) }
            }
        }
    }
}

/// While files are dragged over the notch: a clear target with a moving gradient border.
struct DropZone: View {
    var targeted: Bool                     // the pointer is right over the island
    @ObservedObject var hub = TransferHub.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
            let phase = reduceMotion ? 0 : CGFloat(ctx.date.timeIntervalSinceReferenceDate * 30).truncatingRemainder(dividingBy: 40)
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Brand.cream)
                    Image(systemName: "arrow.down.doc.fill").font(.system(size: 19, weight: .semibold)).foregroundStyle(Brand.coral)
                }
                .frame(width: 46, height: 46)
                .scaleEffect(targeted ? 1.08 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(targeted ? "Let go to send" : "Drop to send").font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(Brand.coral.opacity(targeted ? 0.16 : 0.07)))
            .overlay(shape.stroke(Brand.gradient, style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: [7, 5], dashPhase: -phase)))
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)
    }
    var subtitle: String {
        let names = hub.onlinePhones.map(\.name) + hub.androidPeers.map(\.name)
        if names.isEmpty { return "Then pick where it goes" }
        return names.count == 1 ? "Then tap \(names[0])" : "Then pick one of \(names.count) phones"
    }
}

/// After a drop: what you're sending, and the phones as round buttons.
struct SendCard: View {
    @ObservedObject var hub = TransferHub.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FileStack(urls: hub.staged)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hub.staged.count == 1 ? hub.staged[0].lastPathComponent : "\(hub.staged.count) items")
                        .font(.system(size: 13.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: hub.staged.reduce(0) { $0 + TransferHub.size($1) }, countStyle: .file) + " · choose a device")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                Button { hub.staged = [] } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                        .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain).help("Cancel")
            }
            HStack(alignment: .top, spacing: 4) {
                ForEach(hub.onlinePhones.prefix(3)) { p in
                    DeviceChip(icon: p.platform == "android" ? "candybarphone" : "iphone", name: p.name, sub: "Rokaconnect", primary: true) {
                        hub.sendToPhone(hub.staged, p); hub.staged = []
                    }
                }
                ForEach(hub.androidPeers.prefix(max(0, 3 - hub.onlinePhones.count))) { p in
                    DeviceChip(icon: "candybarphone", name: p.name, sub: "Quick Share", primary: false) {
                        NearbyShare.shared.send(hub.staged, to: p); hub.staged = []
                    }
                }
                DeviceChip(icon: "qrcode", name: "Any phone", sub: "QR code", primary: false) {
                    hub.addToOutbox(hub.staged); hub.staged = []
                    (NSApp.delegate as? AppDelegate)?.openSettings()
                    NotificationCenter.default.post(name: .openPortalPage, object: nil)
                }
                if hub.onlinePhones.isEmpty && hub.androidPeers.isEmpty {
                    Text("Open Rokaconnect on your phone (same Wi-Fi) and it shows up here.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Up to three file previews, fanned out like cards.
struct FileStack: View {
    let urls: [URL]
    var body: some View {
        ZStack {
            ForEach(Array(urls.prefix(3).enumerated().reversed()), id: \.offset) { i, u in
                FileThumb(url: u)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .rotationEffect(.degrees(Double(i) * 8))
                    .offset(x: CGFloat(i) * 4, y: CGFloat(i) * -2)
            }
        }
        .frame(width: 52, height: 48)
    }
}

/// A picture's own preview, or the file's icon.
struct FileThumb: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().padding(4).background(Color.white.opacity(0.08)) }
        }
        .task(id: url) {
            guard ["jpg", "jpeg", "png", "heic", "gif", "tiff", "webp"].contains(url.pathExtension.lowercased()) else { return }
            let u = url
            image = await Task.detached { NSImage(contentsOf: u) }.value
        }
    }
}

/// A round device button: icon in a circle (gradient ring for the app's own phones), name and how it sends.
struct DeviceChip: View {
    let icon: String, name: String, sub: String
    var primary: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(primary ? AnyShapeStyle(Brand.cream) : AnyShapeStyle(Color.white.opacity(0.1)))
                    Image(systemName: icon).font(.system(size: 18, weight: .medium)).foregroundStyle(primary ? Brand.coral : .white)
                }
                .frame(width: 46, height: 46)
                .overlay(Circle().stroke(Brand.gradient, lineWidth: hover ? 2.5 : (primary ? 1.5 : 0)).padding(-3))
                .scaleEffect(hover ? 1.07 : 1)
                Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Text(sub).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            .frame(maxWidth: 104)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hover = h } }
        .help("Send to \(name)")
    }
}

/// Loads file URLs from a drop and stages them on the hub.
func stageDrop(_ providers: [NSItemProvider]) -> Bool {
    final class Box { var urls: [URL] = []; let lock = NSLock() }
    let box = Box()
    let group = DispatchGroup()
    for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { u, _ in
            if let u { box.lock.lock(); box.urls.append(u); box.lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        (NSApp.delegate as? AppDelegate)?.island?.fileDrag = false
        if !box.urls.isEmpty { TransferHub.shared.staged = box.urls }
    }
    return !providers.isEmpty
}

// MARK: - Settings: Portal hub

struct ShareHubSection: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var hub = TransferHub.shared
    @ObservedObject var web = WebShare.shared

    var body: some View {
        SectionLabel("Phones with the Rokaconnect app")
        Card {
            if hub.onlinePhones.isEmpty {
                Text("No phone connected. Open the Rokaconnect app on your phone (same Wi-Fi).").font(.system(size: 11.5)).opacity(0.6)
            }
            ForEach(hub.onlinePhones) { p in
                HStack {
                    Label(p.name, systemImage: p.platform == "android" ? "candybarphone" : "iphone").font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    GlassPill(title: "Send files…", icon: "arrow.up", prominent: true) { hub.pickFiles { hub.sendToPhone($0, p) } }
                }
            }
        }
        Card { ToggleRow(title: "Sync clipboard automatically", on: $s.autoClipboard) }
        Caption("Files go straight to the phone and save in Downloads/Rokaconnect, no tapping needed. You can also drop files on the notch and pick the phone. With clipboard sync on, anything you copy on the Mac appears on the phone within a few seconds, and Copy on the phone lands on the Mac.")

        SectionLabel("Android — Quick Share")
        Card {
            ToggleRow(title: "Visible to Android phones", on: $s.androidShare)
            ToggleRow(title: "Accept without asking", on: $s.autoAcceptShares)
            if s.androidShare {
                if hub.androidPeers.isEmpty {
                    Text("No Android phones nearby right now").font(.system(size: 11)).opacity(0.55)
                } else {
                    ForEach(hub.androidPeers) { p in
                        HStack {
                            Label(p.name, systemImage: "candybarphone").font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            GlassPill(title: "Send files…", icon: "arrow.up") { hub.pickFiles { NearbyShare.shared.send($0, to: p) } }
                        }
                    }
                }
            }
        }
        Caption("Receive: on Android tap Share → Quick Share and pick “\(Host.current().localizedName ?? "this Mac")”, and files arrive straight away (turn off “Accept without asking” to approve each one in the island). Send: open Quick Share on the phone (or set it to Everyone) so it appears above, or drop files on the notch. Both need the same Wi-Fi.")

        SectionLabel("Any phone — browser")
        Card {
            ToggleRow(title: "Share with a QR code", on: $s.webShare)
            if s.webShare {
                HStack(alignment: .top, spacing: 14) {
                    if let qr = web.qr {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 128, height: 128)
                            .padding(8).background(RoundedRectangle(cornerRadius: 12).fill(.white))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(web.status).font(.system(size: 11.5)).opacity(0.75).fixedSize(horizontal: false, vertical: true)
                        if let u = web.url {
                            Text(u.absoluteString).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled).opacity(0.6).lineLimit(2)
                        }
                        HStack {
                            GlassPill(title: "Offer files…", icon: "plus") { hub.pickFiles { hub.addToOutbox($0) } }
                            GlassPill(title: "New link", icon: "arrow.clockwise") { web.newLink() }
                        }
                    }
                }
                if !hub.outbox.isEmpty {
                    Text("Offered to phones").font(.system(size: 11, weight: .semibold)).opacity(0.6).padding(.top, 4)
                    ForEach(hub.outbox, id: \.self) { u in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 18, height: 18)
                            Text(u.lastPathComponent).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Button { hub.removeFromOutbox(u) } label: { Image(systemName: "minus.circle.fill").opacity(0.6) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        Caption("Phones send files and text to this Mac, and can save anything you offer here. Only someone who scans the code (or has the link) can connect; “New link” cuts off old ones.")
    }
}

struct TransferHistory: View {
    @ObservedObject var hub = TransferHub.shared
    var body: some View {
        SectionLabel("Recent transfers")
        Card {
            if hub.transfers.isEmpty {
                Text("Nothing yet").font(.system(size: 11.5)).opacity(0.55)
            }
            ForEach(hub.transfers.prefix(12)) { t in
                HStack(spacing: 10) {
                    Image(systemName: t.icon).font(.system(size: 13)).frame(width: 26, height: 26).glass(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("\(t.direction == .incoming ? "From" : "To") \(t.peer) · \(t.channel.rawValue) · \(stateText(t))")
                            .font(.system(size: 10.5)).opacity(0.6).lineLimit(1)
                        if t.state == .active { ProgressView(value: t.progress).progressViewStyle(.linear).tint(.white).controlSize(.small) }
                    }
                    Spacer()
                    if let f = t.files.first {
                        Button { NSWorkspace.shared.activateFileViewerSelecting(t.files) } label: { Image(systemName: "magnifyingglass.circle.fill").font(.system(size: 16)).opacity(0.7) }
                            .buttonStyle(.plain).help("Show \(f.lastPathComponent) in Finder")
                    }
                }
            }
        }
    }
    func stateText(_ t: TransferHub.Transfer) -> String {
        switch t.state {
        case .waiting: "Waiting"
        case .active: "\(Int(t.progress * 100))%"
        case .done: t.date.formatted(date: .omitted, time: .shortened)
        case .failed(let m): m
        case .declined: "Declined"
        }
    }
}
