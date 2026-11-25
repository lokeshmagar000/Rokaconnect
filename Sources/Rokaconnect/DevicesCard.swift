import SwiftUI
import AppKit

/// Which page the open island shows when music is playing.
enum IslandPage { case music, devices }

/// The island's "Your devices" widget: battery rings for this Mac, the phone and the earbuds,
/// plus quick actions (Lock Mac, Ring phone, Send files, Keep awake).
struct DevicesCard: View {
    @ObservedObject var power: Power
    @ObservedObject var airpods: AirPods
    @ObservedObject var galaxy: GalaxyBuds      // Galaxy Buds control channel (noise control)
    @ObservedObject var hub = TransferHub.shared
    @ObservedObject var awake = KeepAwake.shared
    var collapse: () -> Void = {}
    @State private var ringing = false

    var phone: TransferHub.AppPeer? { hub.onlinePhones.first }
    var buds: BTDevice? { airpods.device }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Your devices").font(.system(size: 13.5, weight: .bold))
                Spacer()
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            HStack(alignment: .top, spacing: 0) {
                BatteryRing(level: power.level, charging: power.charging, icon: "laptopcomputer", name: "MacBook", order: 0)
                BatteryRing(level: phone?.battery, charging: phone?.charging ?? false, icon: "smartphone",
                            name: phone.map { shortName($0.name) } ?? "Phone", order: 1, missing: phone == nil ? "Open the app" : nil)
                BatteryRing(level: buds.map(budsLevel), charging: false,
                            icon: (buds?.name ?? "").localizedCaseInsensitiveContains("airpods") ? "airpods" : "earbuds",
                            name: buds.map { shortName($0.name) } ?? "Earbuds", order: 2, missing: buds == nil ? "Not connected" : nil)
            }
            if galaxy.name != nil { NoiseControl(mode: galaxy.noiseMode) { galaxy.setNoise($0) } }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                DeviceAction(icon: "lock.fill", title: "Lock Mac") { collapse(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MacActions.lock() } }
                DeviceAction(icon: ringing ? "bell.and.waves.left.and.right.fill" : "bell.fill", title: ringing ? "Ringing…" : "Ring phone",
                             active: ringing, enabled: phone != nil) {
                    guard let phone else { return }
                    hub.ring(phone); ringing = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { ringing = false }
                }
                DeviceAction(icon: "arrow.up.doc.fill", title: "Send files", enabled: phone != nil) {
                    guard let phone else { return }
                    collapse(); hub.pickFiles { hub.sendToPhone($0, phone) }
                }
                DeviceAction(icon: awake.on ? "sun.max.fill" : "moon.zzz.fill", title: awake.on ? "Awake" : "Keep awake", active: awake.on) { awake.toggle() }
            }
        }
    }

    var statusText: String {
        switch (phone != nil, buds != nil) {
        case (true, true): "All linked"
        case (true, false): "Phone linked"
        case (false, true): "Earbuds linked"
        default: "Not linked"
        }
    }
    var statusColor: Color { phone != nil ? .green : Color.white.opacity(0.35) }

    func budsLevel(_ d: BTDevice) -> Int { d.single ?? min(d.left ?? d.right ?? 0, d.right ?? d.left ?? 0) }
    /// "Galaxy S24 Ultra" → "S24 Ultra", "Lok's Galaxy Buds2 Pro" → "Galaxy Buds2 Pro" (fits under the ring).
    func shortName(_ n: String) -> String {
        var s = n.replacingOccurrences(of: "Samsung ", with: "")
        if s.hasPrefix("Galaxy S") || s.hasPrefix("Galaxy Z") { s = String(s.dropFirst(7)) }
        if let r = s.range(of: "’s ") ?? s.range(of: "'s ") { s = String(s[r.upperBound...]) }
        return s
    }
}

/// Galaxy Buds noise control: Off · Noise cancelling · Ambient, as one sliding segmented switch.
struct NoiseControl: View {
    let mode: Int?                       // 0 off, 1 noise cancelling, 2 ambient (nil = not known yet)
    let set: (Int) -> Void
    @Namespace private var pick
    private let items: [(Int, String, String)] = [(0, "Off", "speaker.slash.fill"), (1, "Noise cancelling", "ear.fill"), (2, "Ambient", "waveform")]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.0) { m, title, icon in
                Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { set(m) } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                        Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(mode == m ? Brand.onAccent : .white.opacity(0.75))
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background {
                        if mode == m { Capsule().fill(Brand.gradient).matchedGeometryEffect(id: "noise", in: pick) }   // slides between options
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScale())
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

/// One battery ring: fills up with a spring when the island opens; green / orange / red by level, bolt while charging.
struct BatteryRing: View {
    let level: Int?
    var charging = false
    let icon: String
    let name: String
    var order = 0
    var missing: String? = nil
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var color: Color {
        guard let level else { return .white.opacity(0.3) }
        return level <= 20 ? Color(red: 1, green: 0.33, blue: 0.33) : level <= 40 ? Color(red: 1, green: 0.62, blue: 0.1) : Color(red: 0.2, green: 0.84, blue: 0.4)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 6, dash: level == nil ? [3, 4] : []))
                if let level {
                    Circle().trim(from: 0, to: shown ? CGFloat(level) / 100 : 0)
                        .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: color.opacity(0.45), radius: 4)
                }
                Image(systemName: icon).font(.system(size: 19, weight: .medium)).foregroundStyle(.white.opacity(level == nil ? 0.45 : 1))
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 17, height: 17).background(Circle().fill(color))
                        .offset(x: 21, y: -21).transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 60, height: 60)
            VStack(spacing: 1) {
                Text(level.map { "\($0)%" } ?? "—").font(.system(size: 14, weight: .bold).monospacedDigit())
                    .contentTransition(.numericText())
                Text(missing ?? name).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if reduceMotion { shown = true; return }
            withAnimation(.spring(response: 0.9, dampingFraction: 0.78).delay(0.08 + Double(order) * 0.07)) { shown = true }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: level)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: charging)
    }
}

/// A quick-action button: glass-dark rounded rectangle, brightens on hover, squeezes on press, coral when active.
struct DeviceAction: View {
    let icon: String
    let title: String
    var active = false
    var enabled = true
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                    .symbolEffect(.bounce, value: active)
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(active ? Brand.cream : .white.opacity(enabled ? 1 : 0.35))
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(active ? AnyShapeStyle(Brand.coral.opacity(0.32)) : AnyShapeStyle(Color.white.opacity(hover && enabled ? 0.14 : 0.08))))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(active ? Brand.coral.opacity(0.7) : .white.opacity(0.06), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: active)
    }
}

/// Squeezes a little while pressed and springs back.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Two small tabs sitting in the island's "ears" left and right of the notch: Music · Devices.
struct IslandTabs: View {
    @Binding var page: IslandPage
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            tab("Music", "music.note", .music).frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth)
            tab("Devices", "circle.circle", .devices).frame(maxWidth: .infinity)
        }
        .frame(height: notchHeight)
    }
    func tab(_ title: String, _ icon: String, _ p: IslandPage) -> some View {
        let on = page == p
        return Button { withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { page = p } } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .bold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(on ? Brand.onAccent : .white.opacity(0.8))
            // dark glass behind the unpicked tab, so it stays readable on bright artwork
            .background(Capsule().fill(on ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.black.opacity(0.4))))
            .overlay(Capsule().stroke(Color.white.opacity(on ? 0 : 0.12), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
    }
}
