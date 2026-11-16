import SwiftUI
import AppKit

/// One glass surface: Apple's real Liquid Glass on macOS 26+, frosted `.ultraThinMaterial` on older
/// macOS, and a solid surface when the user turns on "Reduce transparency" in Accessibility.
struct GlassBackground<S: Shape>: View {
    var shape: S
    var tint: Color? = nil
    var clear = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if reduceTransparency {
            shape.fill(Color(white: 0.14)).overlay(shape.fill(tint ?? .clear))      // solid, readable
        } else if #available(macOS 26, *) {
            Color.clear.glassEffect(glass, in: shape)                               // real Liquid Glass
        } else {
            shape.fill(.ultraThinMaterial).overlay(shape.fill(tint ?? .clear))     // older macOS
        }
    }
    @available(macOS 26, *)
    private var glass: Glass {
        var g: Glass = clear ? .clear : .regular
        if let tint { g = g.tint(tint) }
        return g
    }
}

extension View {
    func glass<S: Shape>(_ shape: S, tint: Color? = nil, clear: Bool = false) -> some View {
        background(GlassBackground(shape: shape, tint: tint, clear: clear))
    }
    /// Window-level backdrop only needed before macOS 26 (newer systems get a real glass window).
    @ViewBuilder func legacyWindowGlass() -> some View {
        if #available(macOS 26, *) { self }
        else { background(ZStack { GlassBlur(material: .hudWindow); Color.black.opacity(0.2) }.ignoresSafeArea()) }
    }
}

/// A transparent window whose whole background is Liquid Glass.
func makeGlassWindow<V: View>(_ root: V, title: String) -> NSWindow {
    let host = NSHostingView(rootView: root)
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                     styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    w.title = title
    w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
    w.isOpaque = false; w.backgroundColor = .clear
    w.appearance = NSAppearance(named: .darkAqua)
    w.isMovableByWindowBackground = true
    w.isReleasedWhenClosed = false
    if #available(macOS 26, *) {
        let g = NSGlassEffectView()
        g.cornerRadius = 18
        g.style = .regular
        g.tintColor = NSColor.black.withAlphaComponent(0.18)
        g.contentView = host
        w.contentView = g
    } else {
        w.contentView = host
    }
    return w
}
