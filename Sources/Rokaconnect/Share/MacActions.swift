import Foundation
import IOKit.pwr_mgt

/// Actions for the island's Devices widget.
enum MacActions {
    /// Locks the Mac right away (like Control-Command-Q). Uses `SACLockScreenImmediate` from Apple's private
    /// login framework — the same call the menu bar's Lock Screen item uses. Being private, a macOS update could
    /// remove it; then this does nothing and reports false.
    @discardableResult static func lock() -> Bool {
        guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let sym = dlsym(h, "SACLockScreenImmediate") else { return false }
        typealias Fn = @convention(c) () -> Int32
        _ = unsafeBitCast(sym, to: Fn.self)()
        return true
    }

    /// True if the lock call is available on this macOS (checked without locking).
    static var canLock: Bool {
        guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY) else { return false }
        return dlsym(h, "SACLockScreenImmediate") != nil
    }
}

/// Keep awake: stops the Mac (and its screen) from going to sleep until turned off again. Not saved: it ends when you quit.
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()
    @Published private(set) var on = false
    private var assertion: IOPMAssertionID = 0

    func toggle() { on ? stop() : start() }
    /// From the phone island: turn it on or off explicitly.
    func set(_ wanted: Bool) { if wanted != on { toggle() } }

    private func start() {
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Rokaconnect: Keep awake" as CFString, &assertion)
        on = (r == kIOReturnSuccess)
    }
    private func stop() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        on = false
    }
}
