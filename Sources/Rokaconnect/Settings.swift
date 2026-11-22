import SwiftUI
import AppKit
import ServiceManagement

enum IslandTheme: String, CaseIterable, Identifiable {
    case glass = "Liquid Glass", light = "Light", dark = "Dark"
    var id: String { rawValue }
}

enum MediaSource: String, CaseIterable, Identifiable {
    case auto = "Auto", spotify = "Spotify", music = "Music"
    var id: String { rawValue }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private static let d = UserDefaults.standard
    @Published var theme: IslandTheme { didSet { Self.d.set(theme.rawValue, forKey: "theme") } }
    @Published var haptics: Bool { didSet { Self.d.set(haptics, forKey: "haptics") } }
    @Published var showCharging: Bool { didSet { Self.d.set(showCharging, forKey: "charging") } }
    @Published var corners: Bool { didSet { Self.d.set(corners, forKey: "corners") } }
    @Published var faceID: Bool { didSet { Self.d.set(faceID, forKey: "faceID") } }
    @Published var autoLockMinutes: Double { didSet { Self.d.set(autoLockMinutes, forKey: "autoLock") } }
    @Published var lockScreen: Bool { didSet { Self.d.set(lockScreen, forKey: "lockScreen") } }
    @Published var mediaPlayer: Bool { didSet { Self.d.set(mediaPlayer, forKey: "mediaPlayer") } }
    @Published var source: MediaSource { didSet { Self.d.set(source.rawValue, forKey: "source") } }
    @Published var lyricsOn: Bool { didSet { Self.d.set(lyricsOn, forKey: "lyricsOn") } }
    @Published var weatherOn: Bool { didSet { Self.d.set(weatherOn, forKey: "weatherOn") } }
    @Published var fahrenheit: Bool { didSet { Self.d.set(fahrenheit, forKey: "fahrenheit") } }
    @Published var podsAlerts: Bool { didSet { Self.d.set(podsAlerts, forKey: "podsAlerts") } }
    @Published var liveWaveform: Bool { didSet { Self.d.set(liveWaveform, forKey: "liveWaveform") } }
    @Published var expandOnHover: Bool { didSet { Self.d.set(expandOnHover, forKey: "expandOnHover") } }
    @Published var backgroundBlur: Bool { didSet { Self.d.set(backgroundBlur, forKey: "backgroundBlur") } }
    @Published var lockSound: Bool { didSet { Self.d.set(lockSound, forKey: "lockSound") } }
    @Published var unlockSound: Bool { didSet { Self.d.set(unlockSound, forKey: "unlockSound") } }
    @Published var soundVolume: Double { didSet { Self.d.set(soundVolume, forKey: "soundVolume") } }
    @Published var outputChange: Bool { didSet { Self.d.set(outputChange, forKey: "outputChange") } }
    @Published var overlayDuration: Double { didSet { Self.d.set(overlayDuration, forKey: "overlayDuration") } }
    @Published var portalEffects: Bool { didSet { Self.d.set(portalEffects, forKey: "portalEffects") } }
    @Published var portalStyle: String { didSet { Self.d.set(portalStyle, forKey: "portalStyle2") } }
    @Published var androidShare: Bool { didSet { Self.d.set(androidShare, forKey: "androidShare"); NearbyShare.shared.setEnabled(androidShare) } }
    @Published var autoAcceptShares: Bool { didSet { Self.d.set(autoAcceptShares, forKey: "autoAcceptShares") } }
    /// Keep the Mac and phone clipboards in sync automatically.
    @Published var autoClipboard: Bool { didSet { Self.d.set(autoClipboard, forKey: "autoClipboard") } }

    init() {
        let d = Self.d
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        theme = IslandTheme(rawValue: d.string(forKey: "theme") ?? "") ?? .glass
        haptics = b("haptics", true); faceID = b("faceID", false)
        autoLockMinutes = d.object(forKey: "autoLock") as? Double ?? 5
        lockScreen = b("lockScreen", true)
        corners = b("corners", true); showCharging = b("charging", true)
        mediaPlayer = b("mediaPlayer", true); lyricsOn = b("lyricsOn", true)
        source = MediaSource(rawValue: d.string(forKey: "source") ?? "") ?? .auto
        liveWaveform = b("liveWaveform", true); expandOnHover = b("expandOnHover", true); backgroundBlur = b("backgroundBlur", true)
        lockSound = b("lockSound", true); unlockSound = b("unlockSound", true)
        soundVolume = d.object(forKey: "soundVolume") as? Double ?? 1
        outputChange = b("outputChange", true)
        overlayDuration = d.object(forKey: "overlayDuration") as? Double ?? 4
        portalEffects = b("portalEffects", true); portalStyle = d.string(forKey: "portalStyle2") ?? "portal"   // new key: everyone starts on the portal
        androidShare = b("androidShare", true); autoAcceptShares = b("autoAcceptShares", true); autoClipboard = b("autoClipboard", true)
        weatherOn = b("weatherOn", true); fahrenheit = b("fahrenheit", false); podsAlerts = b("podsAlerts", true)
    }

    func temperature(_ c: Int) -> String { fahrenheit ? "\(Int((Double(c) * 9 / 5 + 32).rounded()))°" : "\(c)°" }
}

/// Brand colours — the same warm palette as the app icon and the Android app (Glass.kt → Palette).
enum Brand {
    static let orange = Color(red: 1.0, green: 0.761, blue: 0.478)       // #FFC27A
    static let coral = Color(red: 0.941, green: 0.502, blue: 0.353)      // #F0805A
    static let pink = Color(red: 0.910, green: 0.353, blue: 0.471)       // #E85A78
    static let cream = Color(red: 1.0, green: 0.945, blue: 0.871)        // #FFF1DE
    static let bg = Color(red: 0.082, green: 0.063, blue: 0.055)         // #15100E
    static let surface = Color(red: 0.129, green: 0.098, blue: 0.086)    // #211916
    static let raised = Color(red: 0.180, green: 0.141, blue: 0.125)     // #2E2420
    static let ink = Color(red: 1.0, green: 0.957, blue: 0.918)          // #FFF4EA
    static let onAccent = Color(red: 0.165, green: 0.078, blue: 0.059)   // dark text on the gradient
    static let accent = coral
    static let gradient = LinearGradient(colors: [orange, coral, pink], startPoint: .leading, endPoint: .trailing)
}

/// Simple labelled slider row.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var valueText: String
    var lo = "", hi = ""
    var body: some View {
        VStack(spacing: 6) {
            HStack { Text(title).font(.system(size: 12.5, weight: .medium)); Spacer(); Text(valueText).font(.system(size: 12.5, weight: .semibold)).monospacedDigit() }
            Slider(value: $value, in: range, step: step).tint(.white).controlSize(.small)
            if !lo.isEmpty { HStack { Text(lo); Spacer(); Text(hi) }.font(.system(size: 9.5)).foregroundStyle(.secondary) }
        }
    }
}

/// Small label above a card ("BEHAVIOR", "SOUNDS"…) — same style as the Android app.
struct SectionLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(1.1)
            .foregroundStyle(Brand.ink.opacity(0.6)).padding(.top, 8).padding(.leading, 6)
    }
}

// MARK: - Building blocks (dark glass style)

/// A section card: warm surface with a hairline edge, the same as the Android app's cards.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)   // same radius as Android
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(DS.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Brand.surface))
            .overlay(shape.stroke(Brand.ink.opacity(0.07), lineWidth: 1))
    }
}

struct ToggleRow: View {
    let title: String
    @Binding var on: Bool
    var body: some View {
        HStack { Text(title).font(.system(size: 13, weight: .medium)); Spacer(); Toggle("", isOn: $on).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Brand.coral) }
    }
}

struct Caption: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Brand.ink.opacity(0.55)).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
    }
}

/// Vertical EQ slider (white knob on a thin track).
struct VSlider: View {
    @Binding var value: Double      // -12...12
    var range: ClosedRange<Double> = -12...12
    var body: some View {
        GeometryReader { g in
            let h = g.size.height - 18
            let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .top) {
                Capsule().fill(Color.white.opacity(0.14)).frame(width: 4).frame(maxHeight: .infinity).padding(.vertical, 9)
                Capsule().fill(Color.white.opacity(0.5)).frame(width: 4, height: max(0, abs(frac - 0.5) * h))
                    .offset(y: 9 + (frac > 0.5 ? (1 - frac) * h : h / 2))
                Circle().fill(.white).frame(width: 18, height: 18).shadow(radius: 2).offset(y: (1 - frac) * h)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = 1 - min(max((v.location.y - 9) / h, 0), 1)
                value = (range.lowerBound + f * (range.upperBound - range.lowerBound)).rounded(toPlaces: 1)
            })
            .onTapGesture(count: 2) { value = 0 }
        }
    }
}

extension Double { func rounded(toPlaces p: Int) -> Double { let m = pow(10, Double(p)); return (self * m).rounded() / m } }

// MARK: - Window

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", media = "Media", portal = "Portal"
    case sensory = "Sensory", battery = "Battery", weather = "Weather", lockScreen = "Lock Screen", faceID = "Touch ID", accessories = "Accessories"
    case about = "About"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: "gearshape.fill"; case .media: "play.fill"; case .portal: "rectangle.portrait.and.arrow.right.fill"
        case .sensory: "hand.tap.fill"; case .battery: "bolt.fill"; case .weather: "cloud.sun.fill"
        case .lockScreen: "lock.fill"; case .faceID: "touchid"; case .accessories: "earbuds"; case .about: "info.circle.fill"
        }
    }
    static let top: [SettingsPage] = [.general, .media, .portal]
    static let devices: [SettingsPage] = [.sensory, .battery, .weather, .lockScreen, .faceID, .accessories]
}

struct SettingsView: View {
    @State var page: SettingsPage = SettingsPage(rawValue: UserDefaults.standard.string(forKey: "debugSettings") ?? "") ?? .general
    @State var search = ""
    @ObservedObject var look = Settings.shared

    /// Warm near-black with a soft coral glow at the top — the Android app's background.
    var background: some View {
        ZStack {
            Brand.bg
            RadialGradient(colors: [Brand.coral.opacity(0.16), .clear], center: .init(x: 0.6, y: 0), startRadius: 0, endRadius: 520)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 196)
            Rectangle().fill(Brand.ink.opacity(0.06)).frame(width: 1)
            ScrollView {
                // GlassGroup lets neighbouring glass cards blend like Apple's own apps
                GlassGroup {
                    VStack(alignment: .leading, spacing: DS.gap) {
                        HStack(spacing: 10) {
                            ZStack { Circle().fill(Brand.cream); Image(systemName: page.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.coral) }
                                .frame(width: 32, height: 32)
                            Text(page.rawValue).font(.system(size: 20, weight: .bold))
                        }
                        .padding(.bottom, 2)
                        pageView
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 640, height: 520)
        .background(background.ignoresSafeArea())
        .foregroundStyle(Brand.ink)
        .environment(\.colorScheme, .dark)
        .onReceive(NotificationCenter.default.publisher(for: .openPortalPage)) { _ in page = .portal }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).opacity(0.5)
                TextField("Search", text: $search).textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Brand.raised))
            .padding(.bottom, 10)
            ForEach(filter(SettingsPage.top)) { item($0) }
            if !filter(SettingsPage.devices).isEmpty {
                Text("Overlays").font(.system(size: 10.5, weight: .semibold)).opacity(0.4).padding(.top, 14).padding(.bottom, 4).padding(.leading, 8)
                ForEach(filter(SettingsPage.devices)) { item($0) }
            }
            Spacer()
            ForEach(filter([.about])) { item($0) }
        }
        .padding(.horizontal, 10).padding(.top, 36).padding(.bottom, 12)
    }

    func filter(_ p: [SettingsPage]) -> [SettingsPage] {
        search.isEmpty ? p : p.filter { $0.rawValue.localizedCaseInsensitiveContains(search) }
    }

    func item(_ p: SettingsPage) -> some View {
        let on = page == p
        return Button { page = p } label: {
            HStack(spacing: 9) {
                Image(systemName: p.icon).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Brand.coral)
                    .frame(width: 22, height: 22).background(Circle().fill(on ? Brand.cream : Brand.raised))
                Text(p.rawValue).font(.system(size: 12.5, weight: on ? .semibold : .medium))
                Spacer()
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background { if on { Capsule().fill(Brand.raised) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder var pageView: some View {
        let app = NSApp.delegate as! AppDelegate
        switch page {
        case .general: GeneralPage()
        case .media: MediaPage()
        case .portal: PortalSection(p: app.portal)
        case .sensory: SensoryPage()
        case .battery: BatteryPage()
        case .weather: WeatherPage()
        case .lockScreen: LockPage()
        case .faceID: TouchIDSection()
        case .accessories: AccessoriesPage(buds: app.buds)
        case .about: AboutPage()
        }
    }
}

// MARK: - Pages

struct GeneralPage: View {
    @ObservedObject var s = Settings.shared
    @State var loginError = ""
    var body: some View {
        Card {
            Text("Island Look").font(.system(size: 12.5, weight: .medium))
            Picker("", selection: $s.theme) { ForEach(IslandTheme.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
        }
        SectionLabel("Behavior")
        Card {
            ToggleRow(title: "Haptic Touch", on: $s.haptics)
            ToggleRow(title: "Expand on Hover", on: $s.expandOnHover)
            ToggleRow(title: "Background Blur", on: $s.backgroundBlur)
            ToggleRow(title: "Live Waveform", on: $s.liveWaveform)
        }
        Caption("With Expand on Hover off, click the notch to open the island.")
        SectionLabel("Sounds")
        Card {
            ToggleRow(title: "Lock Sound", on: $s.lockSound)
            ToggleRow(title: "Unlock Sound", on: $s.unlockSound)
            SliderRow(title: "Volume", value: $s.soundVolume, range: 0...1, step: 0.05,
                      valueText: "\(Int(s.soundVolume * 100))%", lo: "Quiet", hi: "Loud")
        }
        SectionLabel("Display")
        Card { ToggleRow(title: "Rounded screen corners", on: $s.corners) }
        Card {
            ToggleRow(title: "Open at login", on: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { on in
                do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister(); loginError = "" }
                catch { loginError = "macOS refused: \(error.localizedDescription). Move Rokaconnect to Applications and try again." }
            }))
        }
        if !loginError.isEmpty { Caption(loginError) }
        Card {
            Button("Show the welcome tour again") { (NSApp.delegate as? AppDelegate)?.showWelcome() }.buttonStyle(.plain).foregroundStyle(Brand.coral)
        }
    }
}

struct MediaPage: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var eq = EQManager.shared
    let bands = ["Sub", "Low", "Mid", "Pres", "Air"]
    var body: some View {
        Card { ToggleRow(title: "Media Player", on: $s.mediaPlayer) }
        Card {
            Text("Source").font(.system(size: 12.5, weight: .medium))
            HStack(spacing: 0) {
                ForEach(MediaSource.allCases) { src in
                    Button { s.source = src } label: {
                        VStack(spacing: 5) {
                            Text(src.rawValue).font(.system(size: 10.5, weight: .medium)).opacity(0.7)
                            sourceIcon(src).frame(width: 30, height: 30)
                            Circle().fill(.white).frame(width: 4, height: 4).opacity(s.source == src ? 1 : 0)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .glass(RoundedRectangle(cornerRadius: 12, style: .continuous), clear: true)
        }
        Caption("Auto shows whichever app is playing music. Pick Spotify or Music to only ever show that app.")
        Card { ToggleRow(title: "Time-synced lyrics", on: $s.lyricsOn) }
        Card {
            HStack {
                Text("EQ").font(.system(size: 12.5, weight: .medium))
                Spacer()
                Picker("", selection: Binding(get: { eq.bundleID }, set: { eq.choose($0) })) { ForEach(eq.apps, id: \.id) { Text($0.name).tag($0.id) } }
                    .labelsHidden().frame(width: 150).controlSize(.small)
                Toggle("", isOn: Binding(get: { eq.enabled }, set: { eq.setEnabled($0) })).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
        }
        Caption("macOS shows a purple dot while the EQ is working. That is normal: the sound is only changed and played, never saved or sent.")
        Card {
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { i in
                    VStack(spacing: 6) {
                        VSlider(value: Binding(get: { Double(eq.gains[i]) }, set: { eq.setGain(i, Float($0)) })).frame(height: 110)
                        Text(String(format: "%+.1f", eq.gains[i])).font(.system(size: 9.5).monospacedDigit()).opacity(0.6)
                        Text(bands[i]).font(.system(size: 10.5, weight: .medium)).opacity(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
        }
        Card {
            HStack {
                Button { eq.applyPreset([0, 0, 0, 0, 0]) } label: { Text("Reset EQ").frame(maxWidth: .infinity) }
                    .buttonStyle(.plain).foregroundStyle(.blue)
                Menu("Presets") { ForEach(EQManager.presets, id: \.0) { p in Button(p.0) { eq.applyPreset(p.1) } } }
                    .menuStyle(.borderlessButton).frame(width: 80)
            }
        }
        Caption(eq.status.isEmpty ? "Shape how your music sounds — tune the lows, mids and presence for each app." : eq.status)
    }

    @ViewBuilder func sourceIcon(_ s: MediaSource) -> some View {
        switch s {
        case .auto: Image(systemName: "sparkles").font(.system(size: 18))
        case .spotify: appIcon("com.spotify.client", fallback: "music.note")
        case .music: appIcon("com.apple.Music", fallback: "music.note")
        }
    }
    @ViewBuilder func appIcon(_ id: String, fallback: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else { Image(systemName: fallback).font(.system(size: 18)) }
    }
}

struct SensoryPage: View {
    @ObservedObject var s = Settings.shared
    var body: some View {
        Card { ToggleRow(title: "Haptics", on: $s.haptics) }
        Caption("A small tap on the trackpad when the island opens.")
    }
}

struct BatteryPage: View {
    @ObservedObject var s = Settings.shared
    var body: some View {
        Card { ToggleRow(title: "Show charging in the island", on: $s.showCharging) }
        Caption("Plug in and the island tells you where you are.")
    }
}

struct WeatherPage: View {
    @ObservedObject var s = Settings.shared
    var body: some View {
        Card {
            ToggleRow(title: "Show weather", on: $s.weatherOn)
            ToggleRow(title: "Use Fahrenheit", on: $s.fahrenheit)
        }
        Caption("Uses your approximate location (rounded to about 1 km) and Open-Meteo.")
    }
}

/// Settings → Lock Screen: just the unlock animation (macOS 27 blocks drawing on the lock screen itself).
struct LockPage: View {
    @ObservedObject var s = Settings.shared
    var body: some View {
        Card {
            ToggleRow(title: "Unlock animation", on: $s.lockScreen)
            HStack {
                Spacer()
                GlassPill(title: "Play it now", icon: "lock.open.fill") { (NSApp.delegate as? AppDelegate)?.lockScreen.preview() }
            }
        }
        Caption("When you unlock your Mac, a lock in the notch springs open — like iPhone. macOS doesn't let apps draw on the lock screen itself, so nothing appears there.")
    }
}

struct AccessoriesPage: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var buds: GalaxyBuds
    var body: some View {
        Card { ToggleRow(title: "Accessory Connect", on: $s.podsAlerts) }
        Card { ToggleRow(title: "Output Change", on: $s.outputChange) }
        Caption("Shows battery when AirPods or Galaxy Buds connect, and the new device when your sound output changes.")
        Card {
            SliderRow(title: "Overlay Duration", value: $s.overlayDuration, range: 2...8, step: 1,
                      valueText: "\(Int(s.overlayDuration)) sec", lo: "2", hi: "8")
        }
        SectionLabel("Galaxy Buds")
        Card { BudsSection(b: buds) }
    }
}

struct AboutPage: View {
    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text("Rokaconnect").font(.system(size: 15, weight: .bold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.system(size: 11)).opacity(0.6)
                }
            }
        }
        // the creator — kept in both apps' About screens
        Card {
            Text("Lok Bahadur Roka Magar — Creator, from Nepal").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                GlassPill(title: "Facebook", icon: "person.2.fill") { open("https://facebook.com/iamlokeshmagar") }
                GlassPill(title: "Instagram", icon: "camera.fill") { open("https://instagram.com/iamlokeshmagar") }
                GlassPill(title: "TikTok", icon: "music.note") { open("https://www.tiktok.com/@lokeshmagar000") }
            }
            Text("Facebook iamlokeshmagar · Instagram @iamlokeshmagar · TikTok @lokeshmagar000").font(.system(size: 10.5)).opacity(0.55)
        }
    }
    /// Opens a link in the default browser.
    func open(_ url: String) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
}

/// Settings → Touch ID: ask for Touch ID (or the Mac password) before Settings opens.
struct TouchIDSection: View {
    @ObservedObject var s = Settings.shared
    let auth = TouchAuth.shared
    var body: some View {
        Card {
            ToggleRow(title: "Lock Settings with \(auth.methodName)", on: $s.faceID)
            HStack {
                Text("Stay unlocked for").font(.system(size: 12.5, weight: .medium))
                Spacer()
                Picker("", selection: $s.autoLockMinutes) {
                    Text("1 min").tag(1.0); Text("5 min").tag(5.0); Text("15 min").tag(15.0); Text("1 hour").tag(60.0)
                }.labelsHidden().frame(width: 100).controlSize(.small)
            }
        }
        Caption("Uses Apple's Touch ID — Rokaconnect never sees your fingerprint. Macs have no Face ID camera, so the old camera face check was removed.")
    }
}
