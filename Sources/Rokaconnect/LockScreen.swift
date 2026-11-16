import AppKit
import SwiftUI
import os

private let lockLog = Logger(subsystem: "com.rokaconnect.app", category: "LockScreen")

// Note: on macOS 27 Apple draws the lock screen above every app window (even with private APIs),
// so Rokaconnect can't show anything ON the lock screen. It plays the unlock animation right after
// you unlock instead, in a normal window — no private API needed.

// MARK: - Unlock animation in the notch

/// Locked → unlocked state of the lock-screen island.
/// The steps of the unlock animation.
final class LockIslandModel: ObservableObject {
    enum Phase { case start, locked, unlocked, end }
    @Published var phase = Phase.start
    /// Width of the normal island right now, so the animation starts and ends exactly matching it.
    var mainWidth: CGFloat = 200
}

/// Right after you unlock: the island (starting exactly like the normal one) grows to show a lock,
/// the lock springs open (iPhone-style) with "Unlocked", then it shrinks back to the normal island —
/// no fading, so the hand-over back to the normal island is seamless.
struct LockIslandView: View {
    let notchWidth: CGFloat, notchHeight: CGFloat
    @ObservedObject var model: LockIslandModel
    @ObservedObject var music: NowPlaying
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let e = IslandMetrics.ear
        let width: CGFloat = {
            switch model.phase {
            case .start, .end: return model.mainWidth
            case .locked: return notchWidth + 2 * IslandMetrics.compactSide + 2 * e
            case .unlocked: return notchWidth + 2 * (IslandMetrics.compactSide + 42) + 2 * e
            }
        }()
        let side = (width - notchWidth - 2 * e) / 2
        let showIcon = model.phase == .locked || model.phase == .unlocked
        let open = model.phase == .unlocked
        ZStack(alignment: .top) {
            IslandShape(bottomRadius: 10, ear: e).fill(.black)               // melts into the real notch
            HStack(spacing: 0) {
                Image(systemName: open ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(open ? Color.green : .white)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: open)
                    .frame(width: max(0, side))
                    .opacity(showIcon ? 1 : 0)
                Spacer(minLength: notchWidth)
                Text("Unlocked").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                    .lineLimit(1).fixedSize()
                    .frame(width: max(0, side))
                    .opacity(open ? 1 : 0)
            }
            .padding(.horizontal, e)
            .frame(height: notchHeight)
            .clipped()
        }
        .frame(width: width, height: notchHeight)
        // grows with a gentle bounce, settles back without one
        .animation(DS.motion(model.phase == .end ? .spring(response: 0.4, dampingFraction: 0.85) : .spring(response: 0.42, dampingFraction: 0.62), reduce: reduceMotion), value: model.phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Watches lock / unlock and plays the unlock animation in the notch.
final class LockScreenController {
    private let music: NowPlaying
    /// Notch size, and a way to hide the normal island while the animation plays.
    var notch: () -> (width: CGFloat, height: CGFloat) = { (180, 32) }
    var setMainIslandHidden: (Bool) -> Void = { _ in }
    private var panel: NSPanel?
    private let model = LockIslandModel()

    init(music: NowPlaying, lyrics: LyricsStore, airpods: AirPods) {
        self.music = music
        let c = DistributedNotificationCenter.default()
        c.addObserver(self, selector: #selector(unlocked), name: .init("com.apple.screenIsUnlocked"), object: nil)
    }

    /// macOS says the Mac was unlocked → wait for the lock screen to slide away, then animate.
    @objc func unlocked() {
        lockLog.notice("unlocked — animation \(Settings.shared.lockScreen ? "on" : "off", privacy: .public)")
        guard Settings.shared.lockScreen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.play() }
    }

    /// Settings → Lock Screen → "Play it now".
    func preview() { play() }

    /// Width of the normal island (set by the app) — the animation begins and ends at exactly this size.
    var mainIslandWidth: () -> CGFloat = { 200 }

    private func play() {
        hide()
        guard let sc = NSScreen.main ?? NSScreen.screens.first else { return }
        model.mainWidth = mainIslandWidth()
        model.phase = .start
        let (w, h) = notch()
        let size = NSSize(width: 520, height: 80)
        let p = NSPanel(contentRect: NSRect(x: sc.frame.midX - size.width / 2, y: sc.frame.maxY - size.height, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.ignoresMouseEvents = true
        p.level = .statusBar + 2                                   // just above the normal island
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: LockIslandView(notchWidth: w, notchHeight: h, model: model, music: music))
        p.orderFrontRegardless()
        panel = p
        // it looks exactly like the normal island, so hiding the normal one under it can't be seen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.setMainIslandHidden(true) }
        let steps: [(Double, LockIslandModel.Phase)] = [(0.1, .locked), (0.55, .unlocked), (1.55, .end)]
        for (t, ph) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { if self.panel === p { self.model.phase = ph } } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { if self.panel === p { self.hide() } }
    }

    /// Shows the normal island first, then removes the animation window on top of it (no blink).
    private func hide() {
        guard let p = panel else { return }
        panel = nil
        setMainIslandHidden(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { p.orderOut(nil) }
    }
}
