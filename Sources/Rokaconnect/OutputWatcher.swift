import Foundation
import CoreAudio

/// Watches the system's default sound output and announces changes (Canopy's "Output Change").
final class OutputWatcher: ObservableObject {
    @Published var name = ""
    @Published var justChanged = false
    private var current: AudioObjectID = 0
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    init() {
        current = Self.defaultDevice(); name = Self.name(of: current)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.changed()
        }
    }

    var icon: String {
        let n = name.lowercased()
        if n.contains("buds") { return "earbuds" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("headphone") || n.contains("beats") { return "headphones" }
        if n.contains("macbook") || n.contains("speaker") { return "laptopcomputer" }
        return "hifispeaker.fill"
    }

    private func changed() {
        let d = Self.defaultDevice()
        guard d != current else { return }
        current = d; name = Self.name(of: d)
        guard Settings.shared.outputChange else { return }
        justChanged = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.shared.overlayDuration) { self.justChanged = false }
    }

    private static func defaultDevice() -> AudioObjectID {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var d = AudioObjectID(0); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &d)
        return d
    }
    private static func name(of d: AudioObjectID) -> String {
        var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var s: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &s) == noErr, let n = s?.takeRetainedValue() else { return "" }
        return n as String
    }
}
