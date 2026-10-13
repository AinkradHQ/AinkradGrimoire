import AinkradAppKit
import SwiftUI

/// The mockups' `.cut` card (GP18, GP66). Neon: an 8 pt chamfer, `fill`, and a 1 pt rim (the cyan stroke unless the
/// card has its own). Glass: a 12 pt continuous card on the window's material, `glassFill` over it, and a white 12 %
/// hairline.
struct CardSurface: ViewModifier {
    let fill: Color
    var glassFill: Color?
    var rim: Color?
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    @ViewBuilder func body(content: Content) -> some View {
        if skin.usesNativeGlass {
            let shape = RoundedRectangle(cornerRadius: skin.size.s12, style: .continuous)
            content
                .background {
                    // `backdrop-filter: blur(30px) saturate(160%)` under the card's own fill.
                    shape.fill(.ultraThinMaterial).overlay(shape.fill(glassFill ?? fill))
                }
                .overlay(shape.strokeBorder(rim ?? skin.color(skin.palette.white).opacity(skin.opacity.o12), lineWidth: 1))
        } else {
            let shape = skin.shape(cut: skin.size.s8)
            content
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(rim ?? theme.accentSecondary.opacity(skin.opacity.o45), lineWidth: 1))
        }
    }
}

extension View {
    func cardSurface(_ fill: Color, glass glassFill: Color? = nil, rim: Color? = nil) -> some View {
        modifier(CardSurface(fill: fill, glassFill: glassFill, rim: rim))
    }
}
