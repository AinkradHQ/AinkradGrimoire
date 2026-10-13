import AinkradAppKit
import SwiftUI

/// How the window's columns give way as it narrows (GD16, GD26): the sidebar slims, then yields to an open review
/// pane, and in a window too narrow for both the review pane takes the thread's place until it is closed.
struct ColumnLayout: Equatable {
    var showsSidebar = true
    var isSidebarCompact = false
    var reviewReplacesThread = false

    /// Below this the sidebar slims to its compact width.
    static let compactBelow: CGFloat = 760
    /// Below this an open review pane takes the sidebar's room: sidebar, thread and pane don't fit side by side.
    static let sidebarYieldsToReviewBelow: CGFloat = 1000
    /// Below this the thread beside a review pane would be too narrow to read; the pane takes its place.
    static let reviewReplacesThreadBelow: CGFloat = 700

    static func forWidth(_ width: CGFloat, showsReview: Bool) -> ColumnLayout {
        ColumnLayout(
            showsSidebar: !showsReview || width >= sidebarYieldsToReviewBelow,
            isSidebarCompact: width < compactBelow,
            reviewReplacesThread: showsReview && width < reviewReplacesThreadBelow)
    }
}

extension EnvironmentValues {
    /// Set by `Columns` when the window is too narrow for the thread and its review pane side by side.
    @Entry var reviewReplacesThread = false
}

/// The window's columns: the sidebar and whatever the main pane shows, laid out for the window's width.
struct Columns: View {
    let model: GrimoireModel
    @State private var width: CGFloat?

    var body: some View {
        let showsReview =
            model.isReviewOpen && model.selectedThread != nil && !model.isShowingSettings && model.forgeAsk == nil
        let layout = ColumnLayout.forWidth(width ?? .infinity, showsReview: showsReview)
        HStack(spacing: 0) {
            if layout.showsSidebar {
                Sidebar(model: model, isCompact: layout.isSidebarCompact)
            }
            VStack(spacing: 0) {
                // The sidebar's "needs you" has gone with it: say it here instead.
                if !layout.showsSidebar, !model.othersNeedingYou.isEmpty {
                    NeedsYouStrip(model: model, threads: model.othersNeedingYou)
                }
                MainPane(model: model)
            }
        }
        .environment(\.reviewReplacesThread, layout.reviewReplacesThread)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

extension GrimoireModel {
    /// Threads other than the open one waiting on an approval, oldest id first.
    var othersNeedingYou: [ClaudeSessionSummary] {
        let waiting = Set(liveThreads.filter { $0.key != selectedThreadID && $0.value.status == .needsYou }.keys)
        return projects.flatMap(\.sessions).filter { waiting.contains($0.id) }.sorted { $0.id < $1.id }
    }
}

/// Over the main pane while the sidebar is hidden (a narrow window with the review open): the sidebar's amber
/// "needs you", naming the thread, and a way there.
struct NeedsYouStrip: View {
    let model: GrimoireModel
    let threads: [ClaudeSessionSummary]
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var statusColors

    var body: some View {
        HStack(spacing: skin.size.s8) {
            StatusDot(status: .needsYou)
            Group {
                if threads.count == 1, let thread = threads.first {
                    Text(thread.title).foregroundStyle(theme.foreground.opacity(skin.opacity.o85))
                    Text("needs you").foregroundStyle(statusColors.warning)
                } else {
                    Text("\(threads.count) threads need you").foregroundStyle(statusColors.warning)
                }
            }
            .lineLimit(1)
            Spacer(minLength: skin.size.s6)
            AinkradButton(title: "Open", style: .ghost) { model.selectedThreadID = threads.first?.id }
                .borderless().secondaryAccent().fixedSize()
                .help(threads.first.map { "Open \($0.title)" } ?? "")
        }
        .font(skin.font(AinkradFontToken(sizeKey: "t12")))
        .padding(.horizontal, skin.size.s20)
        .padding(.top, skin.size.s8)
    }
}

/// The kit's segmented picker while it fits; a pull-down of the same choices when it doesn't (GD26).
struct FittingPicker<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let label: (Item) -> String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            AinkradSegmentedPicker(items: items, selection: $selection, label: label).fixedSize()
            AinkradMenuButton(
                items: items.map { item in
                    AinkradMenuItem(title: label(item), systemName: item == selection ? "checkmark" : nil) {
                        selection = item
                    }
                }
            ) {
                PullDownLabel { MenuValue(caption: nil, value: label(selection)) }
            }
            .fixedSize()
        }
    }
}
