import AinkradAppKit
import SwiftUI

/// The transcript. A streaming reply keeps a reader at the bottom with it; one who scrolled up keeps their place,
/// with "Jump to latest" to come back down (GD41).
struct ConversationView<Trailer: View>: View {
    let live: LiveThread
    let workingDirectory: String
    /// What the engine is doing (starting, failed), under the last message.
    @ViewBuilder let trailer: Trailer
    @Environment(\.ainkradSkin) private var skin
    /// The reader is at the newest message, so what arrives scrolls into view.
    @State private var follows = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: skin.size.s14) {
                    ForEach(Array(live.entries.enumerated()), id: \.offset) { index, entry in
                        EntryRow(
                            entry: entry, images: live.sentImages[index] ?? [], workingDirectory: workingDirectory,
                            waitingToolID: live.pendingApproval?.toolUseID
                        ).id(index)
                    }
                    trailer.id("trailer")
                }
                .padding(.horizontal, skin.size.s20)
                .padding(.top, skin.size.s8)
                .padding(.bottom, skin.size.s20)
            }
            .modifier(FollowsNewest(follows: $follows))
            .onChange(of: live.entries.count) {
                // Your own message always shows; the agent's only while you're at the bottom.
                if case .user = live.entries.last { follows = true }
                if follows { scrollToNewest(proxy) }
            }
            .onChange(of: live.entries.last) { if follows { scrollToNewest(proxy) } }
            .onChange(of: live.failure) { proxy.scrollTo("trailer", anchor: .bottom) }
            .overlay(alignment: .bottom) {
                if !follows {
                    AinkradButton(title: "Jump to latest", style: .primary, icon: "arrow.down") {
                        follows = true
                        proxy.scrollTo("trailer", anchor: .bottom)
                    }
                    .fixedSize()
                    .padding(skin.size.s14)
                }
            }
        }
    }

    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        guard !live.entries.isEmpty else { return }
        proxy.scrollTo(live.entries.count - 1, anchor: .bottom)
    }
}

/// Opens at the newest message without jumping there before the rows above are laid out (which left a blank gap
/// at the top), and keeps `follows` up to date from the scroll position. Rows measured or growing keep the bottom
/// in place only while following; otherwise the reader's place holds (macOS 15+; earlier systems always follow).
private struct FollowsNewest: ViewModifier {
    @Binding var follows: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                // A short thread sits at the bottom, by the composer, as it always has.
                .defaultScrollAnchor(.bottom, for: .alignment)
                .defaultScrollAnchor(follows ? .bottom : nil, for: .sizeChanges)
                .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
                follows = Self.follows(
                    follows, oldOffset: old.contentOffset.y, offset: new.contentOffset.y,
                    visibleBottom: new.visibleRect.maxY, contentHeight: new.contentSize.height)
            }
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }

    /// At the bottom always follows; scrolling up stops following. Content growing under a still reader changes
    /// neither, so a reply streaming in can't flip it on its own.
    static func follows(
        _ follows: Bool, oldOffset: CGFloat, offset: CGFloat, visibleBottom: CGFloat, contentHeight: CGFloat
    ) -> Bool {
        if contentHeight - visibleBottom <= 24 { return true }
        if offset < oldOffset - 1 { return false }
        return follows
    }
}
