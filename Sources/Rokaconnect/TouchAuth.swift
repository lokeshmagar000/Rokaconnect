import Foundation
import LocalAuthentication
import Security

/// Locks Rokaconnect's Settings behind Touch ID (or your Mac password if Touch ID isn't available).
/// Replaces the old camera "Face ID": a Mac has no depth camera, so camera face checks could be fooled
/// by a photo. Touch ID is Apple's own secure check — the app never sees your fingerprint.
final class TouchAuth: ObservableObject {
    static let shared = TouchAuth()

    /// True when Settings should ask before opening.
    var locked: Bool { Date() > unlockedUntil }
    private var unlockedUntil = Date.distantPast

    /// "Touch ID" when the Mac has a sensor, otherwise "your password".
    var methodName: String {
        let c = LAContext()
        return c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) && c.biometryType == .touchID ? "Touch ID" : "your password"
    }

    init() {
        // tidy up: remove the old camera face data from the Keychain, if any
        for account in ["feature-prints", "feature-prints-v2"] {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: "com.rokaconnect.face",
                           kSecAttrAccount as String: account] as CFDictionary)
        }
        UserDefaults.standard.removeObject(forKey: "faceThreshold")
        UserDefaults.standard.removeObject(forKey: "faceThreshold2")
    }

    /// Shows Apple's Touch ID sheet (falls back to the Mac password). Calls back on the main thread.
    func authenticate(_ done: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Password"
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "open Rokaconnect settings") { ok, _ in
            DispatchQueue.main.async {
                if ok { self.unlockedUntil = Date().addingTimeInterval(Settings.shared.autoLockMinutes * 60) }
                done(ok)
            }
        }
    }

    /// Locks again straight away.
    func lockNow() { unlockedUntil = .distantPast }
}
