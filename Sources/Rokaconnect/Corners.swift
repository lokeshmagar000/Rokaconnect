import AppKit

/// Draws black inverted corners on the four screen corners so the display looks uniformly rounded.
final class CornerView: NSView {
    let corner: Int // 0 TL, 1 TR, 2 BL, 3 BR
    init(corner: Int) { self.corner = corner; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) {
        let s = bounds.width
        let cx: CGFloat = (corner == 0 || corner == 2) ? s : 0
        let cy: CGFloat = (corner == 2 || corner == 3) ? s : 0
        let p = NSBezierPath(rect: bounds)
        p.append(NSBezierPath(ovalIn: NSRect(x: cx - s, y: cy - s, width: s * 2, height: s * 2)))
        p.windingRule = .evenOdd
        NSColor.black.setFill(); p.fill()
    }
}

final class Corners {
    var panels: [NSPanel] = []
    func show(radius: CGFloat = 10) {
        panels.forEach { $0.orderOut(nil) }; panels = []
        guard let sc = NSScreen.main else { return }
        let f = sc.frame
        let spots = [NSPoint(x: f.minX, y: f.maxY - radius), NSPoint(x: f.maxX - radius, y: f.maxY - radius),
                     NSPoint(x: f.minX, y: f.minY), NSPoint(x: f.maxX - radius, y: f.minY)]
        for (i, o) in spots.enumerated() {
            let p = NSPanel(contentRect: NSRect(origin: o, size: NSSize(width: radius, height: radius)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.ignoresMouseEvents = true; p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            p.contentView = CornerView(corner: i)
            p.orderFrontRegardless(); panels.append(p)
        }
    }
    func hide() { panels.forEach { $0.orderOut(nil) }; panels = [] }
}
