import AppKit
import SwiftUI
import Combine
import AVFoundation


final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: IslandPanel!
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    let music = NowPlaying()
    let power = Power()
    let airpods = AirPods()
    let weather = Weather()
    let output = OutputWatcher()
    lazy var buds = GalaxyBuds(airpods: airpods)
    let corners = Corners()
    let portal = PortalReceiver()
    lazy var lockScreen: LockScreenController = {
        let c = LockScreenController(music: music, lyrics: lyrics, airpods: airpods)
        c.notch = { [weak self] in (self?.island.notchWidth ?? 180, self?.island.notchHeight ?? 32) }
        c.setMainIslandHidden = { [weak self] hide in hide ? self?.panel.orderOut(nil) : self?.panel.orderFrontRegardless() }
        // the normal island's current width: just the notch, or wider when music/transfer is showing beside it
        c.mainIslandWidth = { [weak self] in
            guard let self else { return 200 }
            let busy = self.music.track?.playing == true || TransferHub.shared.active != nil
            return self.island.notchWidth + 2 * IslandMetrics.ear + (busy ? 2 * IslandMetrics.compactSide : 0)
        }
        return c
    }()
    var cancel: Any?
    lazy var lyrics = LyricsStore(music: music)

    func applicationWillTerminate(_ n: Notification) { music.stop() }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildPanel()
        _ = lockScreen
        _ = buds
        portal.start()
        USBLink.shared.start()      // USB cable mode: links plugged-in phones through the cable (needs adb)
        AOALink.shared.start()      // USB cable mode without USB debugging (Android Open Accessory)
        TransferHub.shared.startClipboardWatch()   // automatic Mac → phone clipboard
        _ = EQManager.shared        // start the equalizer at launch (it used to wait until Settings → Media was opened)
        if Settings.shared.androidShare { NearbyShare.shared.start() }
        if UserDefaults.standard.bool(forKey: "debugShareSelfTest") { NearbyShare.shared.selfTest() }
        #if DEBUG   // diagnostics for test builds only: report what the EQ hears
        if UserDefaults.standard.bool(forKey: "debugEQPeak") {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in NSLog("[EQ] peak %.5f status %@", EQManager.peak, EQManager.shared.status); EQManager.peak = 0 }
        }
        #endif
        if let p = UserDefaults.standard.string(forKey: "debugOutbox") { TransferHub.shared.addToOutbox([URL(fileURLWithPath: p)]) }
        if let p = UserDefaults.standard.string(forKey: "debugDirect") {    // test aid: send straight to the first phone that checks in
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
                if let phone = TransferHub.shared.onlinePhones.first { t.invalidate(); TransferHub.shared.sendToPhone([URL(fileURLWithPath: p)], phone) }
            }
        }
        hubWatch = TransferHub.shared.$consent.receive(on: DispatchQueue.main).sink { [weak self] c in self?.consentChanged(c != nil) }
        stagedWatch = TransferHub.shared.$staged.receive(on: DispatchQueue.main).sink { [weak self] s in if !s.isEmpty { self?.forceOpen() } }
        applyCorners()
        cancel = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.applyCorners() }
        NotificationCenter.default.addObserver(self, selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Rokaconnect")
        let m = NSMenu()
        hideItem = m.addItem(withTitle: "Hide", action: #selector(toggleHidden), keyEquivalent: "")
        hideItem.target = self
        let srcItem = m.addItem(withTitle: "Source", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for src in MediaSource.allCases {
            let it = sub.addItem(withTitle: src.rawValue, action: #selector(pickSource(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = src.rawValue
        }
        srcItem.submenu = sub
        m.delegate = self
        m.addItem(.separator())
        m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Rokaconnect", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    func buildPanel() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let inset = screen.safeAreaInsets.top
        var nw: CGFloat = 0
        if inset > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            nw = screen.frame.width - l.width - r.width
        }
        let state = IslandState(notchWidth: nw > 0 ? nw : 180, notchHeight: inset > 0 ? inset : 32)
        island = state
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true          // let clicks reach the menu bar until the island is open
        panel.appearance = NSAppearance(named: .darkAqua)   // keep the glass dark so white text stays readable
        let host = NSHostingView(rootView: IslandView(state: state, music: music, power: power, lyrics: lyrics, airpods: airpods, weather: weather, output: output, buds: buds))
        panel.contentView = host
        reposition()
        panel.orderFrontRegardless()
        startTracking()
        if UserDefaults.standard.bool(forKey: "debugExpanded") { state.expanded = true }   // screenshot aid
        if UserDefaults.standard.string(forKey: "debugSettings") != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showSettings() } }
        if UserDefaults.standard.bool(forKey: "debugSetup") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.startSetup() } }
        if !UserDefaults.standard.bool(forKey: "onboarded") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.showWelcome() } }
        if UserDefaults.standard.bool(forKey: "debugLock") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.lockScreen.preview() } }
    }

    // MARK: hover tracking (global mouse monitor, so the panel never blocks the menu bar)

    var island: IslandState!
    private var monitors: [Any] = []
    private var collapseWork: DispatchWorkItem?

    private func startTracking() {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in self?.mouseMoved() }) { monitors.append(g) }
        // while something is being dragged: is it a file? then the island opens to catch it
        if let d = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] _ in
            guard let self else { return }
            self.mouseMoved(fileDrag: self.isFileDrag())
        }) { monitors.append(d) }
        if let c = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            self?.dragBaseline = NSPasteboard(name: .drag).changeCount      // a new drag will change this
            self?.mouseMoved(click: true)
        }) { monitors.append(c) }
        // lock / unlock sounds
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.didLock() }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.didUnlock() }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in self?.mouseMoved(); return e }) { monitors.append(l) }
    }

    static func play(_ name: String) {
        guard let snd = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        snd.volume = Float(Settings.shared.soundVolume); snd.play()
    }

    // MARK: lock / unlock — keep Rokaconnect quiet while macOS draws the lock screen

    /// True while the Mac is locked: the island and corners are hidden and skip all work.
    private(set) var screenLocked = false
    /// Was the island showing before the lock (the menu's "Hide" stays respected)?
    private var shownBeforeLock = true
    /// Lock / unlock sounds loaded once at launch and kept ready, so playing them at lock time
    /// needs no file loading or audio setup (that work used to land right on the lock animation).
    private lazy var lockSounds: [String: AVAudioPlayer] = {
        var d: [String: AVAudioPlayer] = [:]
        for n in ["Pop", "Tink"] {
            if let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: "/System/Library/Sounds/\(n).aiff")) { p.prepareToPlay(); d[n] = p }
        }
        return d
    }()

    private func playReady(_ name: String) {
        guard let p = lockSounds[name] else { Self.play(name); return }
        p.volume = Float(Settings.shared.soundVolume); p.currentTime = 0; p.play()
    }

    /// Locked: the lock screen already covers everything, so hiding our windows now can't be seen —
    /// and it leaves macOS nothing of ours to redraw while it animates the lock screen.
    private func didLock() {
        screenLocked = true
        if Settings.shared.lockSound { playReady("Pop") }
        shownBeforeLock = panel.isVisible
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { island.expanded = false }
        collapseWork?.cancel()
        panel.orderOut(nil)
        corners.hide()
    }

    /// Unlocked: put everything back once, then the unlock animation (if on) plays over it.
    private func didUnlock() {
        screenLocked = false
        if Settings.shared.unlockSound { playReady("Tink") }
        reposition()                                  // also brings the corners back
        if shownBeforeLock { panel.orderFrontRegardless() }
    }

    /// Drag pasteboard count at the last mouse-down; it changes when a new drag starts.
    private var dragBaseline = NSPasteboard(name: .drag).changeCount

    /// True while files (from Finder, Desktop or any app) are being dragged.
    private func isFileDrag() -> Bool {
        let pb = NSPasteboard(name: .drag)
        return pb.changeCount != dragBaseline && (pb.types?.contains(.fileURL) ?? false)
    }

    private func mouseMoved(click: Bool = false, fileDrag: Bool = false) {
        guard !screenLocked, !UserDefaults.standard.bool(forKey: "debugExpanded"), island?.welcome != true,
              let screen = panel.screen ?? NSScreen.main, let s = island else { return }
        let p = NSEvent.mouseLocation, top = screen.frame.maxY, mid = screen.frame.midX
        // Inclusive hit test, extended above the screen edge: NSRect.contains() excludes maxY, which is exactly
        // where the pointer sits when it is pushed against the top of the screen (that made the island flicker).
        func hit(width w: CGFloat, height h: CGFloat) -> Bool {
            p.x >= mid - w / 2 && p.x <= mid + w / 2 && p.y >= top - h && p.y <= top + 40
        }
        // the drag ended without a drop (button released): back to normal
        if s.fileDrag && !fileDrag && NSEvent.pressedMouseButtons == 0 { s.fileDrag = false }
        if s.expanded && islandPinned { collapseWork?.cancel(); collapseWork = nil; return }
        if s.expanded {
            let w = IslandMetrics.expandedWidth(notch: s.notchWidth) + 2 * IslandMetrics.ear + 40
            let h = IslandMetrics.expandedHeight(hasTrack: music.track != nil, devices: music.track == nil || s.page == .devices, notch: s.notchHeight, buds: buds.name != nil) + 24
            if hit(width: w, height: h) { collapseWork?.cancel(); collapseWork = nil }
            else if collapseWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.island.expanded = false; self.island.fileDrag = false; self.panel.ignoresMouseEvents = true; self.collapseWork = nil
                    self.lastToggle = Date()
                }
                collapseWork = work
                // never collapse while the open animation is still running
                let wait = max(0.3, 0.55 - Date().timeIntervalSince(lastToggle))
                DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            }
        } else if click || Date().timeIntervalSince(lastToggle) > 0.35 {
            // dragging files: a bigger catch area, and the island always opens so the drop can land on it
            if fileDrag, hit(width: s.notchWidth + 120, height: s.notchHeight + 30) {
                s.fileDrag = true
                s.expanded = true; panel.ignoresMouseEvents = false; lastToggle = Date()
                if Settings.shared.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default) }
                return
            }
            let over = hit(width: s.notchWidth + 40, height: s.notchHeight + 4)
            // nothing to show (no music, no transfer)? hovering only bounces the island — it doesn't open (click still does)
            let hasContent = music.track != nil || TransferHub.shared.active != nil || TransferHub.shared.justFinished != nil
            if over && !click && !hasContent {
                if !hoverBounced { hoverBounced = true; s.bump += 1
                    if Settings.shared.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default) } }
                return
            }
            if !over { hoverBounced = false }
            if over, Settings.shared.expandOnHover || click {
                s.expanded = true; panel.ignoresMouseEvents = false; lastToggle = Date()
                if Settings.shared.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default) }
            }
        }
    }

    private var lastToggle = Date.distantPast
    private var hoverBounced = false     // bounce once per hover, not on every mouse move

    var hideItem: NSMenuItem!
    var hubWatch: AnyCancellable?
    var stagedWatch: AnyCancellable?

    /// The island stays open while it is asking for consent or holding dropped files.
    var islandPinned: Bool { TransferHub.shared.consent != nil || !TransferHub.shared.staged.isEmpty }

    /// Closes the open island right away (used by the Devices widget before locking or picking files).
    func collapseIsland() {
        collapseWork?.cancel(); collapseWork = nil
        island.expanded = false; island.fileDrag = false; panel.ignoresMouseEvents = true; lastToggle = Date()
    }

    func forceOpen() {
        collapseWork?.cancel(); collapseWork = nil
        island.expanded = true; panel.ignoresMouseEvents = false; lastToggle = Date()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func consentChanged(_ asking: Bool) {
        if asking {
            forceOpen()
            NSSound(named: "Glass")?.play()
        } else if TransferHub.shared.staged.isEmpty {
            island.expanded = false; panel.ignoresMouseEvents = true; lastToggle = Date()
        }
    }

    @objc func toggleHidden() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc func pickSource(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let src = MediaSource(rawValue: raw) { Settings.shared.source = src }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        hideItem.title = panel.isVisible ? "Hide" : "Show"
        menu.items.first(where: { $0.submenu != nil })?.submenu?.items.forEach {
            $0.state = ($0.representedObject as? String) == Settings.shared.source.rawValue ? .on : .off
            $0.title = ($0.representedObject as? String) ?? $0.title
        }
        if let src = menu.items.first(where: { $0.submenu != nil }) { src.title = "Source: \(Settings.shared.source.rawValue)" }
    }

    /// Rounded screen corners on/off. Rebuilt only when the setting or the screen really changes.
    private var cornersApplied: (on: Bool, frame: NSRect)?
    func applyCorners() {
        guard !screenLocked else { return }
        let on = Settings.shared.corners, frame = NSScreen.main?.frame ?? .zero
        if let a = cornersApplied, a.on == on, a.frame == frame, !on || !corners.panels.isEmpty { return }
        cornersApplied = (on, frame)
        on ? corners.show() : corners.hide()
    }

    @objc func reposition() {
        guard !screenLocked else { return }               // screen changes during lock are redone at unlock
        defer { applyCorners() }
        guard let screen = NSScreen.main else { return }
        let w: CGFloat = 520, h: CGFloat = 340       // room for the tallest open island (music player)
        panel.setFrame(NSRect(x: screen.frame.midX - w/2, y: screen.frame.maxY - h, width: w, height: h), display: true)
    }


    @objc func openSettings() {
        if TouchAuth.shared.locked && Settings.shared.faceID {      // "faceID" key now means "lock with Touch ID"
            TouchAuth.shared.authenticate { [weak self] ok in if ok { self?.showSettings() } }
        } else { showSettings() }
    }

    // MARK: welcome & setup

    var setupWindow: NSWindow?

    func showWelcome() {
        island.welcome = true
        panel.ignoresMouseEvents = false
    }

    func startSetup() {
        island.welcome = false
        panel.ignoresMouseEvents = true
        let w = makeGlassWindow(SetupView(close: { [weak self] in
            self?.setupWindow?.close(); self?.setupWindow = nil
        }), title: "Welcome")
        setupWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.center(); w.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        if settingsWindow == nil {
            let w = makeGlassWindow(SettingsView(), title: "Rokaconnect")
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center(); settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
