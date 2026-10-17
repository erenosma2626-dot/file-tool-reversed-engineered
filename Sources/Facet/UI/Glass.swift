import SwiftUI

/// Facet's surface treatment: Liquid Glass on macOS 26+, a translucent material before that,
/// or an opaque fill when the user picks the Solid style.
struct FacetSurface<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color? = nil
    var interactive = false
    @ObservedObject private var prefs = Prefs.shared

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prefs.style == .glass {
                content.glassEffect(glass, in: shape)
            } else {
                fallback(content)
            }
        } else {
            fallback(content)
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    if prefs.style == .glass {
                        shape.fill(.ultraThinMaterial)
                    } else {
                        shape.fill(Color(nsColor: .windowBackgroundColor))
                    }
                    if let tint { shape.fill(tint) }
                }
            }
            .overlay { shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5) }
    }
}

extension View {
    func facetSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(FacetSurface(shape: shape, tint: tint, interactive: interactive))
    }

    /// Groups nearby glass shapes so they blend into each other on macOS 26.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

/// Palette: the system accent color, kept soft so it reads like tinted glass.
enum Tint {
    static var selection: Color { Color.accentColor.opacity(0.42) }
    static var subtle: Color { Color.accentColor.opacity(0.16) }
}

/// Small circular glass button (close, back, chevrons).
struct GlassIconButton: View {
    let symbol: String
    var size: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.8))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .facetSurface(Circle(), interactive: true)
    }
}
