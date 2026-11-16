import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// Design tokens — the SAME numbers are used in the Android app (Glass.kt → DS),
// so both apps share one look: corner radius, spacing and spring timing.
// ─────────────────────────────────────────────────────────────────────────────
enum DS {
    static let cardRadius: CGFloat = 24      // big glass cards
    static let tileRadius: CGFloat = 22      // square-ish buttons
    static let gap: CGFloat = 14             // space between cards
    static let pad: CGFloat = 18             // padding inside a card

    /// The one spring both apps use (Android: dampingRatio 0.85, stiffness ≈ 250).
    static let spring = Animation.spring(response: 0.4, dampingFraction: 0.85)

    /// Use this instead of a spring directly: with "Reduce motion" on it becomes a short fade.
    static func motion(_ a: Animation = spring, reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.15) : a }
}

/// Groups glass pieces so Apple's Liquid Glass can blend and morph neighbours together (macOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = DS.gap
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { content } }
        else { content }
    }
}
