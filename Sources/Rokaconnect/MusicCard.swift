import SwiftUI
import AppKit

/// The open island's music player: big artwork fading into black, title + app button, seek bar with a knob,
/// shuffle · back · play/pause · forward · repeat, and where the sound is playing.
struct MusicCard: View {
    let track: Track
    @ObservedObject var music: NowPlaying
    @ObservedObject var lyrics: LyricsStore
    @ObservedObject var output: OutputWatcher
    @State private var scrub: Double?            // 0…1 while dragging the seek bar
    @State private var shuffleOn: Bool?          // shown right away when tapped, until the player reports back
    @State private var repeatOn: Bool?

    var accent: Color { MusicHero.accent(for: track) }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Color.clear.frame(height: 30)               // room for the artwork to show above the title
            titleRow
            seekBar
            controls
            outputPill
        }
        .foregroundStyle(.white)
        .onChange(of: track.shuffle) { _, _ in shuffleOn = nil }
        .onChange(of: track.repeatMode) { _, _ in repeatOn = nil }
    }

    // title + artist (or the current lyric line) + a round button that opens the playing app
    var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Marquee(text: track.title, size: 18, weight: .bold)
                TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                    let pos = track.position + (track.playing ? ctx.date.timeIntervalSince(track.stamp) : 0)
                    let line = lyrics.line(at: pos)
                    Marquee(text: line ?? track.artist, size: 13, weight: line == nil ? .regular : .medium,
                            color: line == nil ? .white.opacity(0.62) : accent)
                }
                .frame(height: 17)
            }
            Spacer(minLength: 0)
            AppButton(bundleID: track.app)
        }
    }

    var seekBar: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { c in
            let live = min(track.duration, track.position + (track.playing ? c.date.timeIntervalSince(track.stamp) : 0))
            let pos = scrub.map { $0 * track.duration } ?? live
            let frac = track.duration > 0 ? min(max(pos / track.duration, 0), 1) : 0
            VStack(spacing: 5) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18)).frame(height: 4)
                        Capsule().fill(.white).frame(width: max(4, g.size.width * frac), height: 4)
                        Circle().fill(.white).frame(width: scrub == nil ? 12 : 16, height: scrub == nil ? 12 : 16)
                            .shadow(color: .black.opacity(0.4), radius: 3)
                            .offset(x: g.size.width * frac - (scrub == nil ? 6 : 8))
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    // click anywhere to jump, or drag the knob; the song moves when you let go
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("musicSeek"))
                        .onChanged { v in scrub = min(max(v.location.x / max(g.size.width, 1), 0), 1) }
                        .onEnded { v in
                            let f = min(max(v.location.x / max(g.size.width, 1), 0), 1)
                            if track.duration > 0 { music.seek(to: f * track.duration) }
                            scrub = nil
                        })
                    .animation(.spring(response: 0.25, dampingFraction: 0.75), value: scrub == nil)
                }
                .coordinateSpace(name: "musicSeek")
                .frame(height: 16)
                HStack {
                    Text(fmt(pos))
                    Spacer()
                    Text("-" + fmt(max(0, track.duration - pos)))
                }
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(height: 34)
    }

    var controls: some View {
        let shuffle = shuffleOn ?? (track.shuffle > 1)
        let repeating = repeatOn ?? (track.repeatMode > 1)
        return HStack {
            small(shuffle ? "shuffle.circle.fill" : "shuffle", on: shuffle) { shuffleOn = !shuffle; music.send("shuffle") }
            Spacer()
            ControlButton(icon: "backward.fill", size: 19) { music.send("previous track") }
            Spacer()
            Button { music.send("playpause") } label: {
                Image(systemName: track.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 19, weight: .bold)).foregroundStyle(.black)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 48, height: 48).background(Circle().fill(.white))
                    .shadow(color: accent.opacity(0.45), radius: 10)
            }
            .buttonStyle(PressScale())
            Spacer()
            ControlButton(icon: "forward.fill", size: 19) { music.send("next track") }
            Spacer()
            small(track.repeatMode == 2 ? "repeat.1" : "repeat", on: repeating) { repeatOn = !repeating; music.send("repeat") }
        }
        .padding(.horizontal, 4)
    }

    func small(_ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? Brand.coral : .white.opacity(0.6))
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }

    // where the sound is playing (MacBook speakers, AirPods…); tap = Sound settings
    var outputPill: some View {
        HStack {
            Spacer()
            Button {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: output.icon).font(.system(size: 11, weight: .semibold))
                    Text("Playing on \(output.name.isEmpty ? "MacBook" : shortOutput)").font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(PressScale())
            Spacer()
        }
    }
    /// "MacBook Air Speakers" → "MacBook Air".
    var shortOutput: String { output.name.replacingOccurrences(of: " Speakers", with: "") }

    func fmt(_ s: Double) -> String { let i = Int(max(0, s)); return String(format: "%d:%02d", i / 60, i % 60) }
}

/// The artwork as a wide background behind the top of the open island, fading into black.
/// Without artwork: the accent colour and a big faint music note (like the design).
struct MusicHero: View {
    let track: Track
    var height: CGFloat
    /// Song without artwork → the design's pink-red; otherwise the artwork's own colour.
    static func accent(for t: Track) -> Color {
        t.artwork == nil ? Color(red: 1.0, green: 0.23, blue: 0.37) : Accent.color(t.artwork)
    }
    var body: some View {
        let accent = Self.accent(for: track)
        ZStack {
            Rectangle().fill(LinearGradient(colors: [accent, accent.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            if let d = track.artwork, let img = NSImage(data: d) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: 64, weight: .light)).foregroundStyle(.white.opacity(0.28))
                    .offset(y: -8)
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.15), location: 0), .init(color: .clear, location: 0.3),
                                   .init(color: .black.opacity(0.55), location: 0.68), .init(color: .black, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(height: height)
        .clipped()
        .animation(.easeInOut(duration: 0.4), value: track.title)
    }
}

/// Round button with the playing app's icon; opens that app.
struct AppButton: View {
    let bundleID: String
    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        Button {
            if let url { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
        } label: {
            ZStack {
                Circle().fill(Color.white.opacity(0.16))
                if let url { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24) }
                else { Image(systemName: "music.note").font(.system(size: 15, weight: .semibold)) }
            }
            .frame(width: 40, height: 40)
            .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(PressScale())
        .help("Open the app that's playing")
    }
}

/// A plain transport button (back / forward).
struct ControlButton: View {
    let icon: String
    var size: CGFloat = 18
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
    }
}
