import AppKit
import Foundation

struct Track: Equatable {
    var title = "", artist = "", app = ""
    var playing = false
    var artwork: Data?
    var position = 0.0, duration = 0.0
    var stamp = Date()
}

final class NowPlaying: ObservableObject {
    @Published var track: Track?
    private var timer: Timer?
    private let q = DispatchQueue(label: "nowplaying")

    init() {
        if UserDefaults.standard.bool(forKey: "debugTrack") {          // screenshot aid only
            var t = Track(title: "A Really Long Song Title That Scrolls", artist: "Rokaconnect Demo", app: "Music", playing: true)
            t.duration = 214; t.position = 63; t.stamp = Date()
            t.artwork = NSImage(contentsOfFile: Bundle.main.path(forResource: "AppIcon", ofType: "icns") ?? "")?.tiffRepresentation
            track = t
            return
        }
        if !startAdapter() { startPolling() }
    }

    // MARK: system-wide now playing (open-source MediaRemoteAdapter, run through Apple's /usr/bin/perl)

    private var adapter: Process?
    private var state: [String: Any] = [:]
    private var lineBuf = Data()
    private(set) var usingAdapter = false

    private static var adapterPaths: (script: String, framework: String)? {
        guard let res = Bundle.main.resourcePath, let fw = Bundle.main.privateFrameworksPath else { return nil }
        let script = res + "/mediaremote-adapter.pl", framework = fw + "/MediaRemoteAdapter.framework"
        let fm = FileManager.default
        return fm.fileExists(atPath: script) && fm.fileExists(atPath: framework) ? (script, framework) : nil
    }

    /// A music reader left behind by an earlier run (if the app was force-quit) — stop it once at launch.
    private static var cleanedUp = false
    private static func stopLeftovers(_ script: String) {
        guard !cleanedUp else { return }
        cleanedUp = true
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", script + " .* stream"]
        try? k.run(); k.waitUntilExit()
    }

    private func startAdapter() -> Bool {
        guard let paths = Self.adapterPaths else { return false }
        Self.stopLeftovers(paths.script)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [paths.script, paths.framework, "stream", "--debounce=80"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            self?.q.async { self?.consume(d) }
        }
        proc.terminationHandler = { [weak self] _ in
            // restart if it ever exits; fall back to AppleScript polling if it can't start
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self else { return }
                self.usingAdapter = false
                if !self.startAdapter() { self.startPolling() }
            }
        }
        do { try proc.run() } catch { return false }
        adapter = proc; usingAdapter = true
        timer?.invalidate(); timer = nil
        return true
    }

    func stop() { adapter?.terminationHandler = nil; adapter?.terminate() }

    private func consume(_ d: Data) {
        lineBuf.append(d)
        while let nl = lineBuf.firstIndex(of: 0x0A) {
            let line = lineBuf[lineBuf.startIndex..<nl]
            lineBuf.removeSubrange(lineBuf.startIndex...nl)
            guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (j["type"] as? String) == "data" else { continue }
            let payload = j["payload"] as? [String: Any] ?? [:]
            if (j["diff"] as? Bool) == true {
                for (k, v) in payload { if v is NSNull { state.removeValue(forKey: k) } else { state[k] = v } }
            } else {
                state = payload.filter { !($0.value is NSNull) }
            }
            let t = trackFromState()
            DispatchQueue.main.async { if self.track != t { self.track = t } }
        }
    }

    private func trackFromState() -> Track? {
        guard Settings.shared.mediaPlayer, let title = state["title"] as? String, !title.isEmpty else { return nil }
        let bundle = state["bundleIdentifier"] as? String ?? ""
        switch Settings.shared.source {
        case .spotify where bundle != "com.spotify.client": return nil
        case .music where bundle != "com.apple.Music": return nil
        default: break
        }
        var t = Track(title: title, artist: state["artist"] as? String ?? "", app: bundle,
                      playing: state["playing"] as? Bool ?? false)
        t.duration = (state["duration"] as? NSNumber)?.doubleValue ?? 0
        let elapsed = (state["elapsedTime"] as? NSNumber)?.doubleValue ?? 0
        var since = 0.0
        if t.playing, let ts = Self.date(state["timestamp"]) { since = max(0, Date().timeIntervalSince(ts)) }
        t.position = t.duration > 0 ? min(t.duration, elapsed + since) : elapsed + since
        t.stamp = Date()
        if let b64 = state["artworkData"] as? String { t.artwork = Data(base64Encoded: b64) }
        return t
    }

    private static func date(_ v: Any?) -> Date? {
        if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    // MARK: fallback: AppleScript polling of Music and Spotify

    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func running(_ id: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
    }

    private func poll() {
        let spotify = running("com.spotify.client"), music = running("com.apple.Music")
        q.async { [weak self] in
            var result: Track?
            let src = Settings.shared.source, on = Settings.shared.mediaPlayer
            if on, music, src != .spotify, let t = Self.musicTrack() { result = t }
            if on, spotify, src != .music, let t = Self.spotifyTrack(), result == nil || t.playing { result = t }
            DispatchQueue.main.async { result?.stamp = Date(); if self?.track != result { self?.track = result } }
        }
    }

    private static func run(_ src: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
        return err == nil ? r : nil
    }

    private static func musicTrack() -> Track? {
        guard let d = run("""
        tell application "Music"
          if player state is stopped then return {"", "", "stopped", 0, 0}
          return {name of current track, artist of current track, player state as text, player position, duration of current track}
        end tell
        """), d.numberOfItems == 5 else { return nil }
        let title = d.atIndex(1)?.stringValue ?? "", state = d.atIndex(3)?.stringValue ?? ""
        if title.isEmpty { return nil }
        var t = Track(title: title, artist: d.atIndex(2)?.stringValue ?? "", app: "Music", playing: state == "playing")
        t.position = d.atIndex(4)?.doubleValue ?? 0; t.duration = d.atIndex(5)?.doubleValue ?? 0
        if let a = run("tell application \"Music\" to get data of artwork 1 of current track") { t.artwork = a.data }
        return t
    }

    private static func spotifyTrack() -> Track? {
        guard let d = run("""
        tell application "Spotify"
          if player state is stopped then return {"", "", "stopped", "", 0, 0}
          return {name of current track, artist of current track, player state as text, artwork url of current track, player position, duration of current track}
        end tell
        """), d.numberOfItems == 6 else { return nil }
        let title = d.atIndex(1)?.stringValue ?? ""
        if title.isEmpty { return nil }
        var t = Track(title: title, artist: d.atIndex(2)?.stringValue ?? "", app: "Spotify",
                      playing: d.atIndex(3)?.stringValue == "playing")
        t.position = d.atIndex(5)?.doubleValue ?? 0; t.duration = (d.atIndex(6)?.doubleValue ?? 0) / 1000
        if let u = URL(string: d.atIndex(4)?.stringValue ?? ""), let data = try? Data(contentsOf: u) { t.artwork = data }
        return t
    }

    /// Jumps the song to `seconds` (island seek bar). Updates the island at once, then tells the player.
    func seek(to seconds: Double) {
        guard var t = track else { return }
        let s = max(0, min(seconds, t.duration))
        t.position = s; t.stamp = Date(); track = t
        if usingAdapter, let paths = Self.adapterPaths {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = [paths.script, paths.framework, "seek", String(Int(s * 1_000_000))]   // microseconds
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run()
            return
        }
        // fallback for Music / Spotify without the adapter
        q.async { _ = Self.run("tell application \"\(t.app)\" to set player position to \(s)") }
    }

    func send(_ cmd: String) {
        if usingAdapter, let paths = Self.adapterPaths {
            // MediaRemote command ids: 2 toggle play/pause, 4 next, 5 previous
            let id = cmd == "playpause" ? "2" : cmd == "next track" ? "4" : cmd == "previous track" ? "5" : nil
            guard let id else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = [paths.script, paths.framework, "send", id]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run()
            return
        }
        guard let app = track?.app else { return }
        q.async { _ = Self.run("tell application \"\(app)\" to \(cmd)") }
    }
}
