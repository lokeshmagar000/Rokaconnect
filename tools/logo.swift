import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
bg.addClip()
NSGradient(colors: [NSColor(red: 0.98, green: 0.35, blue: 0.25, alpha: 1), NSColor(red: 0.55, green: 0.15, blue: 0.85, alpha: 1)])!.draw(in: rect, angle: -60)
// notch pill
NSColor.black.setFill()
NSBezierPath(roundedRect: CGRect(x: 262, y: 640, width: 500, height: 150), xRadius: 75, yRadius: 75).fill()
// connect arcs (wireless "connect" motif)
NSColor.white.setStroke()
for (i, r) in [90.0, 170.0, 250.0].enumerated() {
    let p = NSBezierPath()
    p.appendArc(withCenter: CGPoint(x: 512, y: 330), radius: r, startAngle: 45, endAngle: 135)
    p.lineWidth = 46; p.lineCapStyle = .round
    NSColor.white.withAlphaComponent(1.0 - Double(i) * 0.25).setStroke()
    p.stroke()
}
NSColor.white.setFill()
NSBezierPath(ovalIn: CGRect(x: 512-38, y: 330-38, width: 76, height: 76)).fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
