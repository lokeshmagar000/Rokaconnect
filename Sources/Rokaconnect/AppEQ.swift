import os
import Foundation
import AppKit
import CoreAudio
import AudioToolbox

struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0
    @inline(__always) mutating func process(_ x: Float) -> Float {
        let xd = Double(x), y = b0 * xd + z1
        z1 = b1 * xd - a1 * y + z2
        z2 = b2 * xd - a2 * y
        return Float(y)
    }
    mutating func setPeaking(freq: Double, gainDB: Double, q: Double, rate: Double) {
        let A = pow(10, gainDB / 40), w = 2 * Double.pi * freq / rate
        let al = sin(w) / (2 * q), c = cos(w)
        let a0 = 1 + al / A
        b0 = (1 + al * A) / a0; b1 = -2 * c / a0; b2 = (1 - al * A) / a0
        a1 = -2 * c / a0; a2 = (1 - al / A) / a0
    }
}

/// Realtime-safe 5-band equalizer (filters live in raw memory; no allocation on the audio thread).
final class EQDSP {
    static let freqs: [Double] = [60, 230, 910, 3600, 14000]
    static let channels = 8
    let filters = UnsafeMutablePointer<Biquad>.allocate(capacity: 8 * 5)
    var rate = 48000.0
    var preamp: Float = 1
    init() { filters.initialize(repeating: Biquad(), count: 8 * 5) }
    deinit { filters.deallocate() }
    func update(gains: [Float]) {
        for c in 0..<Self.channels { for b in 0..<5 {
            filters[c * 5 + b].setPeaking(freq: Self.freqs[b], gainDB: Double(gains[b]), q: 1.0, rate: rate)
        } }
        preamp = powf(10, -max(0, gains.max() ?? 0) * 0.8 / 20)
    }
    @inline(__always) func run(_ x: Float, channel: Int) -> Float {
        var v = x * preamp
        let base = min(channel, Self.channels - 1) * 5
        for b in 0..<5 { v = filters[base + b].process(v) }
        return max(-1, min(1, v))
    }
}

private let eqLog = Logger(subsystem: "com.rokaconnect.app", category: "EQ")

final class EQManager: ObservableObject {
    static let shared = EQManager()
    static let presets: [(String, [Float])] = [
        ("Flat", [0, 0, 0, 0, 0]), ("Bass boost", [8, 5, 0, 0, 0]), ("Vocal", [-2, 0, 4, 3, 0]),
        ("Treble boost", [0, 0, 0, 5, 8]), ("Loudness", [6, 2, -1, 2, 6])]

    @Published var gains: [Float] = [0, 0, 0, 0, 0]
    @Published var enabled = false
    @Published var status = ""
    @Published var apps: [(id: String, name: String)] = []
    @Published var bundleID: String { didSet { loadGains(); restartIfNeeded() } }

    private let dsp = EQDSP()
    private var tapID = AudioObjectID(kAudioObjectUnknown), aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var retry: Timer?
    /// What the running EQ is bound to; if either changes (app relaunched, headphones plugged in) it re-attaches.
    private var boundProcs: [AudioObjectID] = []
    private var boundOutput: String?
    private let ioQueue = DispatchQueue(label: "rokaconnect.eq.io", qos: .userInteractive)

    /// Video players are never picked for the EQ automatically, only when you choose one yourself in Settings.
    static let videoPlayers: Set<String> = ["com.lok.mediaplayer", "com.apple.QuickTimePlayerX", "com.apple.TV",
                                            "org.videolan.vlc", "com.colliderli.iina", "io.mpv"]

    init() {
        // keep the saved app, unless it is a video player that you didn't pick yourself
        let saved = UserDefaults.standard.string(forKey: "eqApp")
        let chosen = UserDefaults.standard.bool(forKey: "eqAppChosen")
        bundleID = saved.flatMap { Self.videoPlayers.contains($0) && !chosen ? nil : $0 } ?? "com.spotify.client"
        refreshApps(); loadGains()
        if UserDefaults.standard.bool(forKey: "eqEnabled") { setEnabled(true) }
    }

    func refreshApps() {
        var seen = Set<String>(); var list: [(String, String)] = []
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
            if let id = a.bundleIdentifier, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted {
                list.append((id, a.localizedName ?? id))
            }
        }
        // keep the saved app (and the common players) selectable even when they aren't running
        for id in [bundleID, "com.spotify.client", "com.apple.Music"] where seen.insert(id).inserted {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                list.append((id, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")))
            }
        }
        apps = list.sorted { $0.1.lowercased() < $1.1.lowercased() }.map { (id: $0.0, name: $0.1) }
    }

    /// Settings → Media: you picked this app yourself (so it's kept, even if it's a video player).
    func choose(_ id: String) { UserDefaults.standard.set(true, forKey: "eqAppChosen"); bundleID = id }

    func setGain(_ band: Int, _ v: Float) { gains[band] = v; applyGains() }
    func applyPreset(_ g: [Float]) { gains = g; applyGains() }

    private func applyGains() {
        dsp.update(gains: gains)
        UserDefaults.standard.set(gains.map { Double($0) }, forKey: "eqGains.\(bundleID)")
    }
    private func loadGains() {
        gains = (UserDefaults.standard.array(forKey: "eqGains.\(bundleID)") as? [Double])?.map { Float($0) } ?? [0, 0, 0, 0, 0]
        dsp.update(gains: gains)
        UserDefaults.standard.set(bundleID, forKey: "eqApp")
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "eqEnabled")
        retry?.invalidate(); retry = nil
        stop()
        guard on else { status = ""; return }
        silentSince = nil
        tick()
        // every 2 s: tap only while the app is really playing sound (macOS shows the purple dot while a tap exists),
        // let go after ~3 s of silence, and re-attach when the app relaunches or the output changes
        retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// When the app went quiet (nil while it plays).
    private var silentSince: Date?

    private func tick() {
        guard enabled else { return }
        let procs = processObjects(matching: bundleID).sorted()
        let playing = procs.contains { isPlaying($0) }
        if playing { silentSince = nil } else if silentSince == nil { silentSince = Date() }
        let name = apps.first { $0.id == bundleID }?.name ?? bundleID
        if tapID == kAudioObjectUnknown {
            if playing { _ = start() } else { setStatus("Ready — the EQ starts when \(name) plays sound.") }
            return
        }
        if let quiet = silentSince, Date().timeIntervalSince(quiet) >= 3 {
            eqLog.notice("app is silent, releasing the tap")
            stop(); setStatus("Ready — the EQ starts when \(name) plays sound.")
            return
        }
        if procs != boundProcs || defaultOutputUID() != boundOutput {
            eqLog.notice("re-attaching (app or output changed)")
            stop(); if playing { _ = start() }
        }
    }

    /// Core Audio says this process is sending sound to an output right now.
    private func isPlaying(_ id: AudioObjectID) -> Bool {
        var a = prop(kAudioProcessPropertyIsRunningOutput)
        var v: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v) == noErr && v != 0
    }
    private func restartIfNeeded() { if enabled { setEnabled(true) } }

    // MARK: Core Audio

    private func prop(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func processObjects(matching bundle: String) -> [AudioObjectID] {
        var a = prop(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var b = prop(kAudioProcessPropertyBundleID)
            var s: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &b, 0, nil, &sz, &s) == noErr, let str = s?.takeRetainedValue() as String? else { return false }
            return str == bundle || str.hasPrefix(bundle + ".")
        }
    }

    private func defaultOutputUID() -> String? {
        var a = prop(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = AudioObjectID(0); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr else { return nil }
        var u = prop(kAudioDevicePropertyDeviceUID)
        var s: Unmanaged<CFString>?; sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &u, 0, nil, &sz, &s) == noErr else { return nil }
        return s?.takeRetainedValue() as String?
    }

    @discardableResult private func start() -> Bool {
        let name = apps.first { $0.id == bundleID }?.name ?? bundleID
        let procs = processObjects(matching: bundleID)
        guard !procs.isEmpty else { setStatus("Start playing audio in \(name), then EQ will attach."); return false }
        guard let outUID = defaultOutputUID() else { setStatus("No output device found."); return false }

        let desc = CATapDescription(stereoMixdownOfProcesses: procs)
        desc.uuid = UUID(); desc.name = "Rokaconnect EQ"; desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapErr = AudioHardwareCreateProcessTap(desc, &tap)
        eqLog.notice("tap \(procs.count) process(es) of \(self.bundleID, privacy: .public): err \(tapErr)")
        guard tapErr == noErr else {
            setStatus("Couldn’t tap \(name). Allow audio capture for Rokaconnect in System Settings → Privacy & Security."); return false
        }
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Rokaconnect EQ",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: true]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let aggErr = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        eqLog.notice("aggregate device err \(aggErr) output \(outUID, privacy: .public)")
        guard aggErr == noErr else {
            AudioHardwareDestroyProcessTap(tap); setStatus("Couldn’t create the audio device."); return false
        }
        var fmt = AudioStreamBasicDescription(); var fsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fa = prop(kAudioTapPropertyFormat)
        if AudioObjectGetPropertyData(tap, &fa, 0, nil, &fsz, &fmt) == noErr, fmt.mSampleRate > 0 { dsp.rate = fmt.mSampleRate }
        dsp.update(gains: gains)

        let dsp = self.dsp
        var pid: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&pid, agg, ioQueue) { _, inData, _, outData, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            let outs = UnsafeMutableAudioBufferListPointer(outData)
            var ch = 0
            for i in 0..<min(ins.count, outs.count) {
                guard let src = ins[i].mData?.assumingMemoryBound(to: Float.self),
                      let dst = outs[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(min(ins[i].mDataByteSize, outs[i].mDataByteSize)) / 4
                let nch = max(1, Int(ins[i].mNumberChannels))
                for s in 0..<n { let v = src[s]; if abs(v) > EQManager.peak { EQManager.peak = abs(v) }; dst[s] = dsp.run(v, channel: nch > 1 ? s % nch : ch) }
                if nch == 1 { ch += 1 }
            }
        }
        guard err == noErr, let pid, AudioDeviceStart(agg, pid) == noErr else {
            AudioHardwareDestroyAggregateDevice(agg); AudioHardwareDestroyProcessTap(tap)
            setStatus("Couldn’t start the equalizer."); return false
        }
        tapID = tap; aggID = agg; procID = pid
        boundProcs = procs.sorted(); boundOutput = outUID
        setStatus("EQ active on \(name)")
        return true
    }

    func stop() {
        if aggID != kAudioObjectUnknown {
            if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown); aggID = AudioObjectID(kAudioObjectUnknown); procID = nil
    }

    private var lastLogged = ""
    private func setStatus(_ s: String) {
        if s != lastLogged { lastLogged = s; eqLog.notice("\(s, privacy: .public)") }
        DispatchQueue.main.async { self.status = s }
    }
    /// Peak level seen by the EQ (for diagnostics).
    static var peak: Float = 0
}
