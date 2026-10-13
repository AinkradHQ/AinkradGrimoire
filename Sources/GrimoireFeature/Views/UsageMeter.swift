import AinkradAppKit
import SwiftUI

/// The mockups' `.meter`: a thin continuous bar (6 pt, 3 pt corners) on a white 8 % track — Settings' usage windows
/// in cyan (mockup 8), the limit bar's in amber (12 D).
struct UsageMeter: View {
    let value: Double
    let tint: Color
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: skin.size.s3, style: .continuous)
        shape.fill(skin.color(skin.palette.white).opacity(skin.opacity.o08))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    shape.fill(tint).frame(width: proxy.size.width * min(max(value, 0), 1))
                }
            }
            .clipShape(shape)
            .frame(height: skin.size.s6)
            .frame(minWidth: skin.size.s60)
            .accessibilityElement()
            .accessibilityValue("\(Int((value * 100).rounded())) %")
    }
}
