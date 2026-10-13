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
            MainPane(model: model)
        }
        .environment(\.reviewReplacesThread, layout.reviewReplacesThread)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
