import Foundation
import IOKit.ps

final class Power: ObservableObject {
    @Published var level = 100
    @Published var charging = false
    @Published var justPlugged = false
    private var timer: Timer?
    init() {
        update(initial: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.update(initial: false) }
    }
    private func update(initial: Bool) {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as Array
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps).takeUnretainedValue() as? [String: Any] else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 100
            let ch = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            if ch && !charging && !initial {
                justPlugged = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Settings.shared.overlayDuration) { self.justPlugged = false }
            }
            level = cur; charging = ch
        }
    }
}
