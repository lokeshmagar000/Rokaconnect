import SwiftUI
import AppKit

// MARK: - State & metrics

final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var welcome = false
    /// Bumped to make the island give a little bounce (hover with nothing to show, transfer start/finish).
    @Published var bump = 0
    /// Files are being dragged towards the notch: the open island shows the drop zone.
    @Published var fileDrag = false
    /// With music playing, the open island shows the player (.music) or the Devices widget.
    @Published var page: IslandPage = .music
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    init(notchWidth: CGFloat, notchHeight: CGFloat) { self.notchWidth = notchWidth; self.notchHeight = notchHeight }
}

enum IslandMetrics {
    static let ear: CGFloat = 6
    static let compactSide: CGFloat = 27
    static func expandedWidth(notch: CGFloat) -> CGFloat { max(333, notch + 180) }
    /// Open island height: the Devices widget, or the player (both start just below the notch).
    static func expandedHeight(hasTrack: Bool, devices: Bool, notch: CGFloat, buds: Bool = false) -> CGFloat {
        devices || !hasTrack ? notch + 236 + (buds ? 50 : 0) : notch + 262      // + the earbuds noise-control row
    }
}

// MARK: - Shape

struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var ear: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(bottomRadius, ear) }
        set { bottomRadius = newValue.first; ear = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        let e = ear, br = min(bottomRadius, (r.height - e) / 2, (r.width - 2 * e) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + e, y: r.minY + e), control: CGPoint(x: r.minX + e, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + e, y: r.maxY - br))
        p.addQuadCurve(to: CGPoint(x: r.minX + e + br, y: r.maxY), control: CGPoint(x: r.minX + e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e - br, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - e, y: r.maxY - br), control: CGPoint(x: r.maxX - e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e, y: r.minY + e))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - e, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Behind-window blur, used for the Liquid Glass look.
struct GlassBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var alpha: CGFloat = 1
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow; v.material = material; v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        v.alphaValue = alpha
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Liquid Glass surface: blur + faint tint + bright rim light.
struct LiquidGlass<S: Shape>: View {
    var shape: S
    var body: some View {
        ZStack {
            GlassBlur(material: .popover, alpha: 0.5).clipShape(shape)
            shape.fill(Color.black.opacity(0.12))
            shape.fill(LinearGradient(colors: [.white.opacity(0.14), .clear, .white.opacity(0.04)], startPoint: .top, endPoint: .bottom))
            shape.stroke(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.25)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
    }
}

// MARK: - Artwork accent colour

enum Accent {
    private static var cache: [Int: Color] = [:]
    static func color(_ data: Data?) -> Color {
        guard let data else { return .white }
        let key = data.hashValue
        if let c = cache[key] { return c }
        var result = Color.white
        if let img = NSImage(data: data), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            var px = [UInt8](repeating: 0, count: 4)
            if let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
                    .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                result = Color(nsColor: NSColor(hue: h, saturation: min(1, s * 1.3 + 0.15), brightness: max(b, 0.8), alpha: 1))
            }
        }
        cache[key] = result
        return result
    }
}

// MARK: - Small components

struct MusicBars: View {
    var playing: Bool
    var color: Color
    var height: CGFloat = 12
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.6) {
                ForEach(0..<5, id: \.self) { i in
                    let h = playing ? 0.3 + 0.7 * abs(sin(t * (2.6 + Double(i) * 1.1) + Double(i) * 0.9)) : 0.22
                    Capsule().fill(color).frame(width: 2.2, height: height * h)
                }
            }
            .frame(height: height)
        }
    }
}

/// Single-line text that scrolls when it doesn't fit.
struct Marquee: View {
    let text: String
    let size: CGFloat
    let weight: NSFont.Weight
    var color: Color = .white
    private var textWidth: CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width + 1
    }
    var body: some View {
        GeometryReader { g in
            let fits = textWidth <= g.size.width
            let gap: CGFloat = 28
            TimelineView(.animation(minimumInterval: 1 / 30, paused: fits)) { ctx in
                let cycle = Double(textWidth + gap) / 26          // seconds per loop
                let raw = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle + 2.5)
                let x = fits ? 0 : -CGFloat(max(0, raw - 2.5) / cycle) * (textWidth + gap)
                HStack(spacing: gap) {
                    label
                    if !fits { label }
                }
                .offset(x: x)
                .frame(width: g.size.width, alignment: .leading)
            }
            .mask(LinearGradient(stops: fits ? [.init(color: .black, location: 0), .init(color: .black, location: 1)] :
                                    [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                     .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
        }
        .frame(height: size * 1.3)
        .clipped()
    }
    var label: some View {
        Text(text).font(.system(size: size, weight: Font.Weight(weight))).foregroundStyle(color).lineLimit(1).fixedSize()
    }
}

extension Font.Weight {
    init(_ w: NSFont.Weight) {
        switch w {
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .medium: self = .medium
        default: self = .regular
        }
    }
}

// MARK: - Shared player card (used by the island and the lock screen)

enum PlayerStyle { case island, lock }

/// Player layout measured from Canopy's published look: big artwork + titles, progress row, centred transport.
struct PlayerCard: View {
    let track: Track
    @ObservedObject var music: NowPlaying
    @ObservedObject var lyrics: LyricsStore
    @ObservedObject var settings = Settings.shared
    var outputIcon: String
    var fg: Color = .white
    var style: PlayerStyle = .island

    var accent: Color { Accent.color(track.artwork) }
    @State private var scrub: Double?        // 0…1 while you drag the seek bar

    var body: some View {
        VStack(spacing: style == .island ? 14 : 12) {
            if style == .island {
                HStack(alignment: .center, spacing: 14) {
                    Artwork(data: track.artwork, size: 55, radius: 12)
                    titles.frame(maxWidth: .infinity, alignment: .leading)
                    waveform
                }
            } else {
                ZStack {
                    titles.multilineTextAlignment(.center).padding(.horizontal, 28)
                    HStack { Spacer(); waveform }
                }
            }
            progress
            controls
        }
        .foregroundStyle(fg)
    }

    @ViewBuilder var waveform: some View {
        if settings.liveWaveform { MusicBars(playing: track.playing, color: accent, height: 13) }
        else { Image(systemName: "waveform").font(.system(size: 12)).foregroundStyle(accent) }
    }

    @ViewBuilder var titles: some View {
        VStack(alignment: style == .island ? .leading : .center, spacing: 2) {
            if style == .island { Marquee(text: track.title, size: 13, weight: .semibold, color: fg) }
            else { Text(track.title).font(.system(size: 13, weight: .bold)).lineLimit(1) }
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                let pos = track.position + (track.playing ? ctx.date.timeIntervalSince(track.stamp) : 0)
                let line = lyrics.line(at: pos)
                let text = line ?? track.artist
                let color = line == nil ? fg.opacity(0.55) : accent
                if style == .island { Marquee(text: text, size: 12.5, weight: line == nil ? .regular : .medium, color: color) }
                else { Text(text).font(.system(size: 12, weight: .regular)).foregroundStyle(color).lineLimit(1) }
            }
            .frame(height: 16)
        }
    }

    var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { c in
            let live = min(track.duration, track.position + (track.playing ? c.date.timeIntervalSince(track.stamp) : 0))
            // while dragging, show where you'll land instead of the playing position
            let pos = scrub.map { $0 * track.duration } ?? live
            let frac = track.duration > 0 ? pos / track.duration : 0
            HStack(spacing: 10) {
                Text(fmt(pos)).frame(width: 30, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(fg.opacity(0.22))
                        Capsule().fill(fg.opacity(0.95)).frame(width: max(4, g.size.width * frac))
                    }
                    .frame(height: scrub == nil ? 5 : 9)                       // grows while you drag
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())                                 // the whole strip is grabbable
                    // click anywhere to jump, or drag; the song moves when you let go
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("seekbar"))   // measured from the bar's own left edge
                        .onChanged { v in scrub = min(max(v.location.x / max(g.size.width, 1), 0), 1) }
                        .onEnded { v in
                            let f = min(max(v.location.x / max(g.size.width, 1), 0), 1)
                            if track.duration > 0 { music.seek(to: f * track.duration) }
                            scrub = nil
                        })
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: scrub == nil)
                }
                .coordinateSpace(name: "seekbar")
                .frame(height: 16)
                Text(style == .lock ? "-" + fmt(max(0, track.duration - pos)) : fmt(track.duration)).frame(width: 34, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(fg.opacity(0.55))
        }
        .frame(height: 16)
    }

    var controls: some View {
        HStack {
            Color.clear.frame(width: 26, height: 1)
            Spacer()
            HStack(spacing: style == .island ? 44 : 34) {
                btn("backward.fill", style == .island ? 17 : 15) { music.send("previous track") }
                btn(track.playing ? "pause.fill" : "play.fill", style == .island ? 24 : 21) { music.send("playpause") }
                btn("forward.fill", style == .island ? 17 : 15) { music.send("next track") }
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
            } label: { Image(systemName: outputIcon).font(.system(size: 15)).opacity(0.55).frame(width: 26) }
            .buttonStyle(.plain)
        }
        .frame(height: 26)
    }

    func fmt(_ s: Double) -> String { let i = Int(max(0, s)); return String(format: "%d:%02d", i / 60, i % 60) }

    func btn(_ name: String, _ size: CGFloat, _ a: @escaping () -> Void) -> some View {
        Button(action: a) { Image(systemName: name).font(.system(size: size)).frame(width: 32, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.plain)
    }
}

struct Artwork: View {
    let data: Data?
    let size: CGFloat
    let radius: CGFloat
    var body: some View {
        Group {
            if let d = data, let img = NSImage(data: d) { Image(nsImage: img).resizable().scaledToFill() }
            else { ZStack { Color.gray.opacity(0.35); Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundStyle(.white) } }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Island

struct IslandView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var music: NowPlaying
    @ObservedObject var power: Power
    @ObservedObject var lyrics: LyricsStore
    @ObservedObject var airpods: AirPods
    @ObservedObject var weather: Weather
    @ObservedObject var output: OutputWatcher
    @ObservedObject var buds: GalaxyBuds
    @ObservedObject var settings = Settings.shared
    @ObservedObject var hub = TransferHub.shared
    @State private var dropHover = false
    @State private var pressed = false     // finger/mouse down on the island
    @State private var pop = false         // little bounce when the island opens
    @State private var hop = false         // stretchy bounce: hover with nothing to show, transfers
    @Environment(\.accessibilityReduceMotion) private var reduceMotion   // System Settings → Accessibility → Reduce motion

    enum Live { case none, music, charging, pods, output, share, done }

    var live: Live {
        if power.justPlugged && settings.showCharging { return .charging }
        if hub.active != nil { return .share }
        if hub.justFinished != nil { return .done }
        if settings.podsAlerts, airpods.justConnected, airpods.device != nil { return .pods }
        if output.justChanged { return .output }
        if let t = music.track, t.playing { return .music }
        return .none
    }

    var size: CGSize {
        let e = IslandMetrics.ear
        if state.welcome {
            return CGSize(width: IslandMetrics.expandedWidth(notch: state.notchWidth) + 2 * e, height: state.notchHeight + 100)
        }
        if state.expanded { return openSize }
        let extra: CGFloat = live == .none ? 0 : IslandMetrics.compactSide * 2 + (live == .music ? 0 : 60)
        return CGSize(width: state.notchWidth + extra + 2 * e, height: state.notchHeight)
    }

    /// The open island's size (also used to keep its content laid out at full size while it closes).
    var openSize: CGSize {
        let w = IslandMetrics.expandedWidth(notch: state.notchWidth) + 2 * IslandMetrics.ear
        if hub.consent != nil { return CGSize(width: w, height: state.notchHeight + 104) }
        if !hub.staged.isEmpty { return CGSize(width: w, height: state.notchHeight + 160) }
        if showDropZone { return CGSize(width: w, height: state.notchHeight + 92) }
        return CGSize(width: w, height: IslandMetrics.expandedHeight(hasTrack: music.track != nil, devices: showDevicesPage, notch: state.notchHeight, buds: buds.name != nil))
    }

    /// The open island shows the Devices widget: always when nothing is playing, or when its tab is picked.
    var showDevicesPage: Bool { music.track == nil || state.page == .devices }

    /// Dragging files over the notch (and nothing else needs the space).
    var showDropZone: Bool { (state.fileDrag || dropHover) && hub.staged.isEmpty && hub.consent == nil }

    var light: Bool { settings.theme == .light && state.expanded && !state.welcome }
    var glassTint: Color {
        if state.welcome { return .black.opacity(0.15) }
        switch settings.theme {
        case .glass: return .black.opacity(0.1)
        case .dark: return .black.opacity(0.5)
        case .light: return .white.opacity(0.45)
        }
    }
    /// How dark the bottom of the open island is (the top always fades from notch-black).
    var topFadeEnd: Double {
        if settings.theme == .light && !state.welcome { return 0 }
        return settings.backgroundBlur ? 0 : 0.35
    }
    var fg: Color { light ? .black : .white }
    var accent: Color { Accent.color(music.track?.artwork) }

    var body: some View {
        let shape = IslandShape(bottomRadius: state.expanded || state.welcome ? 24 : 10, ear: IslandMetrics.ear)
        let open = state.expanded || state.welcome
        ZStack(alignment: .top) {
            // Always real Liquid Glass. The collapsed pill is solid black so it melts into the physical notch;
            // when open, the black fades out downward and the glass shows through.
            GlassBackground(shape: shape, tint: glassTint, clear: settings.theme == .glass)
            shape.fill(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.85), location: 0.2),
                                              .init(color: .black.opacity(topFadeEnd), location: 1)],
                                      startPoint: .top, endPoint: .bottom))
                .opacity(open ? 1 : 0)
            shape.fill(.black).opacity(open ? 0 : 1)
            Group {
                if state.welcome { WelcomeCard(notch: state.notchHeight).transition(.opacity) }
                else if state.expanded {
                    // keep the open layout at its full size while the shape morphs, so nothing squashes;
                    // it fades in after the island has grown, and out at once when it starts to close
                    expanded
                        .frame(width: openSize.width - 2 * IslandMetrics.ear, height: openSize.height, alignment: .top)
                        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.1)),
                                                removal: .opacity.animation(.easeIn(duration: 0.08))))
                }
                else {
                    compact.transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.14)),
                                                   removal: .opacity.animation(.easeIn(duration: 0.06))))
                }
            }
            .padding(.horizontal, IslandMetrics.ear)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)                // nothing is ever drawn outside the island, even mid-animation
        .onDrop(of: [.fileURL], isTargeted: $dropHover) { stageDrop($0) }
        // reaction: squeeze while pressed, spring back on release; bounce when it opens
        .scaleEffect(x: pressed ? 0.95 : (pop ? 1.035 : (hop ? 1.07 : 1)),
                     y: pressed ? 0.95 : (pop ? 1.035 : (hop ? 1.16 : 1)), anchor: .top)
        .animation(DS.motion(.spring(response: 0.28, dampingFraction: 0.42), reduce: reduceMotion), value: hop)
        // hover with nothing to show, a transfer starting or finishing → a quick stretchy bounce
        .onChange(of: state.bump) { _, _ in
            guard !reduceMotion else { return }
            hop = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { hop = false }
        }
        .onChange(of: hub.active?.id) { _, id in if id != nil { state.bump += 1 } }
        .onChange(of: hub.justFinished?.id) { _, id in if id != nil { state.bump += 1 } }
        .animation(DS.motion(.spring(response: 0.22, dampingFraction: 0.5), reduce: reduceMotion), value: pressed)
        .animation(DS.motion(.spring(response: 0.3, dampingFraction: 0.45), reduce: reduceMotion), value: pop)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !pressed { pressed = true; NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) } }
            .onEnded { _ in pressed = false })
        .onChange(of: state.expanded) { _, open in
            guard open, !reduceMotion else { return }   // no bounce when Reduce motion is on
            pop = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { pop = false }
        }
        .foregroundStyle(fg)
        .animation(DS.motion(.spring(response: 0.42, dampingFraction: 0.9), reduce: reduceMotion), value: hub.consent?.id)
        .animation(DS.motion(.spring(response: 0.42, dampingFraction: 0.9), reduce: reduceMotion), value: hub.staged.count)
        .animation(DS.motion(.spring(response: 0.38, dampingFraction: 0.78), reduce: reduceMotion), value: showDropZone)
        .animation(DS.motion(.spring(response: 0.42, dampingFraction: 0.82), reduce: reduceMotion), value: state.page)
        // opening: a gentle bounce · closing: a softer settle
        .animation(DS.motion(state.expanded ? .spring(response: 0.42, dampingFraction: 0.72) : .spring(response: 0.38, dampingFraction: 0.8), reduce: reduceMotion), value: state.expanded)
        .animation(DS.motion(.spring(response: 0.5, dampingFraction: 0.9), reduce: reduceMotion), value: state.welcome)
        .animation(DS.motion(.spring(response: 0.4, dampingFraction: 0.75), reduce: reduceMotion), value: live)
        .animation(DS.motion(.spring(response: 0.4, dampingFraction: 0.9), reduce: reduceMotion), value: music.track != nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // Collapsed: live activities either side of the notch
    @ViewBuilder var compact: some View {
        let side = IslandMetrics.compactSide + (live == .music ? 0 : 30)
        HStack(spacing: 0) {
            Group {
                switch live {
                case .music: Artwork(data: music.track?.artwork, size: 17, radius: 4.5)
                case .charging: Image(systemName: "bolt.fill").font(.system(size: 12)).foregroundStyle(.green)
                case .pods: Image(systemName: podsIcon).font(.system(size: 13))
                case .output: Image(systemName: output.icon).font(.system(size: 13))
                case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                case .share: Image(systemName: hub.active?.direction == .outgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 14)).foregroundStyle(Brand.coral)
                case .none: EmptyView()
                }
            }
            .frame(width: side)
            Spacer(minLength: state.notchWidth)
            Group {
                switch live {
                case .music: MusicBars(playing: settings.liveWaveform, color: accent, height: 11)
                case .charging: Text("\(power.level)%").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                case .pods: Text(airpods.device.map { "\(podsLevel($0))%" } ?? "").font(.system(size: 11, weight: .semibold))
                case .output: Text(output.name).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 4)
                case .done: Text(hub.justFinished?.direction == .incoming ? "Saved" : "Sent")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                case .share: Text(hub.active?.state == .waiting ? "…" : "\(Int((hub.active?.progress ?? 0) * 100))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Brand.coral)
                case .none: EmptyView()
                }
            }
            .frame(width: side)
        }
        .frame(height: state.notchHeight)
        .opacity(live == .none ? 0 : 1)
    }

    // Expanded (hover)
    @ViewBuilder var expanded: some View {
        Group {
            if let c = hub.consent {
                ConsentCard(consent: c).padding(.top, state.notchHeight + 8).frame(maxHeight: .infinity, alignment: .top)
            } else if !hub.staged.isEmpty {
                SendCard().padding(.top, state.notchHeight + 10).frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if showDropZone {
                DropZone(targeted: dropHover).padding(.top, state.notchHeight + 8).padding(.horizontal, 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else {
                ZStack(alignment: .top) {
                    // music page: the artwork fills the top of the island edge to edge, fading into black
                    if !showDevicesPage, let t = music.track {
                        MusicHero(track: t, height: state.notchHeight + 108)
                            .padding(.horizontal, -(12 + IslandMetrics.ear))
                            .transition(.opacity)
                    }
                    // the ears beside the notch: Music · Devices tabs while something plays, otherwise date and weather
                    if music.track != nil { IslandTabs(page: $state.page, notchWidth: state.notchWidth, notchHeight: state.notchHeight) }
                    else { ears }
                    Group {
                        if showDevicesPage {
                            DevicesCard(power: power, airpods: airpods, galaxy: buds, collapse: { (NSApp.delegate as? AppDelegate)?.collapseIsland() })
                                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .trailing).combined(with: .opacity)))
                        } else if let t = music.track {
                            MusicCard(track: t, music: music, lyrics: lyrics, output: output)
                                .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                        }
                    }
                    .padding(.top, state.notchHeight + 8)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// Date on the left of the notch, weather (or the time) on the right — shown when nothing is playing.
    var ears: some View {
        TimelineView(.periodic(from: .now, by: 30)) { c in
            HStack(spacing: 0) {
                Text(c.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .frame(maxWidth: .infinity)
                Color.clear.frame(width: state.notchWidth)
                Group {
                    if settings.weatherOn, let w = weather.temp { Label(settings.temperature(w), systemImage: weather.symbol).labelStyle(TightLabel()) }
                    else { Text(c.date, format: .dateTime.hour().minute()) }
                }
                .frame(maxWidth: .infinity)
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(height: state.notchHeight)
        }
    }

    var podsIcon: String { (airpods.device?.name ?? "").localizedCaseInsensitiveContains("buds") ? "earbuds" : "airpods" }
    var outputIcon: String { airpods.device == nil ? "laptopcomputer" : (podsIcon == "earbuds" ? "earbuds" : "airpods") }
    func podsLevel(_ d: BTDevice) -> Int { d.single ?? min(d.left ?? d.right ?? 100, d.right ?? d.left ?? 100) }
    func podsText(_ d: BTDevice) -> String {
        var parts: [String] = []
        if let l = d.left { parts.append("L\(l)") }
        if let r = d.right { parts.append("R\(r)") }
        return parts.isEmpty ? "\(podsLevel(d))%" : parts.joined(separator: " ") + "%"
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon.opacity(0.7); configuration.title }
    }
}
