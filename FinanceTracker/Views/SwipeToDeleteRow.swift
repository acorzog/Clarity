import SwiftUI

/// A manual swipe-to-reveal-delete gesture for rows that live in a custom card/VStack layout
/// rather than a `List` — SwiftUI's `.swipeActions` modifier only works on List rows, so this
/// fills the gap for card-based lists like Plan's budget rows.
///
/// The `DragGesture` this relies on has no VoiceOver equivalent, so deletion is also exposed as
/// an explicit accessibility action (Phase 2N-E, `CLARITY_GOALS_QA_REPORT.md` §8) — invoking the
/// exact same `onDelete` closure the revealed trash button already calls, guarded by the same
/// `canDelete` condition the gesture itself already checks. Shared here rather than duplicated
/// per call site, since every existing use (Plan, Shared, Goals) benefits identically.
struct SwipeToDeleteRow<Content: View>: View {
    let canDelete: Bool
    let onDelete: () -> Void
    var icon: String = "trash"
    var tint: Color = .expenseRed
    @ViewBuilder let content: Content

    @State private var offset: CGFloat = 0
    private let revealWidth: CGFloat = 72

    var body: some View {
        ZStack(alignment: .trailing) {
            if canDelete {
                Button(action: delete) {
                    Image(systemName: icon)
                        .foregroundStyle(.white)
                        .frame(width: revealWidth)
                        .frame(maxHeight: .infinity)
                }
                .background(tint)
            }

            content
                // Opaque so the trash button is fully hidden at rest — matches the
                // white-5%-on-appBackground look every card in this app uses.
                .background {
                    ZStack {
                        Color.appBackground
                        Color.white.opacity(0.05)
                    }
                }
                .offset(x: offset)
                // `simultaneousGesture` (rather than `gesture`) lets the enclosing ScrollView's
                // own pan gesture recognize alongside this one, instead of this row's DragGesture
                // exclusively claiming every touch — including vertical scrolls — the moment it
                // starts. The width/height comparison below then ignores drags that turn out to
                // be vertical scrolling rather than a horizontal swipe.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard canDelete else { return }
                            let translation = value.translation
                            guard abs(translation.width) > abs(translation.height) else { return }
                            if translation.width < 0 {
                                offset = max(translation.width, -revealWidth)
                            } else if offset < 0 {
                                offset = min(0, offset + translation.width)
                            }
                        }
                        .onEnded { value in
                            guard canDelete else { return }
                            let translation = value.translation
                            guard abs(translation.width) > abs(translation.height) else {
                                withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
                                return
                            }
                            withAnimation(.easeOut(duration: 0.2)) {
                                offset = translation.width < -revealWidth / 2 ? -revealWidth : 0
                            }
                        }
                )
                .accessibilityAction(named: "Delete", performAccessibilityDelete)
        }
        .clipShape(Rectangle())
    }

    private func delete() {
        withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
        onDelete()
    }

    /// The VoiceOver-triggered counterpart to `delete()` — no reveal offset to reset (VoiceOver
    /// never drags), so it calls `onDelete` directly, guarded by the same `canDelete` condition
    /// the drag gesture itself already checks. A named method rather than an inline closure so
    /// `SwipeToDeleteRowTests` can invoke exactly what the accessibility action invokes, without
    /// needing a SwiftUI view-inspection library this project doesn't have.
    func performAccessibilityDelete() {
        guard canDelete else { return }
        onDelete()
    }
}
