import AinkradAppKit
import SwiftUI

/// The label of a pull-down `AinkradMenuButton`, dressed in the kit's trigger
/// role (`skin.roles.trigger`): the shape, fill, edge, chevron and padding that
/// `AinkradSelect` draws on its own trigger.
///
/// Local only because the kit draws that trigger inside `AinkradSelect` and
/// does not expose it as a view a menu button can use as its label. A public
/// pull-down trigger label is an Epic 4 gap; until then every value here comes
/// from the skin.
struct PullDownLabel<Content: View>: View {
    /// The mockups draw ▾ only on a value you pick from a list (Model), not on a cycling one (Mode).
    var showsChevron = true
    @ViewBuilder let content: Content

    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTypography) private var typo

    @ViewBuilder var body: some View {
        if #available(macOS 26, *), skin.usesNativeGlass {
            // Liquid Glass: Apple's pop-up button look — the value and the
            // up/down chevrons on an interactive glass capsule.
            HStack(spacing: skin.spacing.xs) {
                content
                if showsChevron {
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, skin.spacing.md)
            .padding(.vertical, skin.spacing.sm)
            .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            kitBody
        }
    }

    private var kitBody: some View {
        let trigger = skin.roles.trigger
        let shape = AinkradSkinShape(token: trigger.shape)
        return HStack(spacing: skin.spacing.xs) {
            content
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(skin.font(trigger.chevron, typography: typo))
                    .foregroundStyle(skin.color(trigger.chevronColor))
            }
        }
        .padding(.horizontal, skin.spacing.md)
        .padding(.vertical, skin.spacing.sm)
        .background(shape.fill(skin.color(trigger.fill)))
        .overlay(
            shape.strokeBorder(
                skin.color(trigger.stroke.color), lineWidth: trigger.stroke.width.resolve([])))
    }
}

/// A menu's label drawn like the kit's framed icon buttons beside it: the header's More (⋯), framed as mockup 2's
/// `.icon-btn` (6 pt chamfer, the cyan rim, the strong fill). A menu can't take an `AinkradIconButton` as its label
/// (a button in a button), and the kit's icon-button tokens aren't public.
struct IconMenuLabel: View {
    let systemName: String
    let size: CGFloat
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    @ViewBuilder var body: some View {
        let glyph = Image(systemName: systemName)
            .font(skin.font(AinkradFontToken(sizeKey: "t13", weight: "semibold", scaled: false)))
            .frame(width: size, height: size)
        if #available(macOS 26, *), skin.usesNativeGlass {
            glyph.glassEffect(.regular.interactive(), in: .circle).contentShape(.circle)
        } else {
            let shape = skin.shape(cut: skin.size.s6)
            glyph
                .foregroundStyle(theme.foreground)
                .background(shape.fill(theme.surfaceElevated.opacity(skin.opacity.o95)))
                .overlay(shape.strokeBorder(theme.accentSecondary.opacity(skin.opacity.o45), lineWidth: 1))
                .contentShape(shape)
        }
    }
}
