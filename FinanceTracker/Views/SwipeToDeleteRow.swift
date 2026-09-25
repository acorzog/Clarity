import SwiftUI

/// A manual swipe-to-reveal gesture for rows that live in a custom card/VStack layout rather than
/// a `List` — SwiftUI's `.swipeActions` modifier only works on List rows, so this fills the gap
/// for card-based lists like Plan's budget rows.
///
/// Trailing (swipe-left) reveal is the original behavior, shared by Goals, Plan, and
/// `SharedEventDetailView`. Leading (swipe-right) reveal is optional and off by default
/// (`canLeadingAction: false`) — Plan's Allocate rows are the only current user, for a one-swipe
/// Fixed/Variable toggle that replaces the old tap-into-a-settings-sheet flow.
///
/// The `DragGesture` this relies on has no VoiceOver equivalent, so each enabled side is also
/// exposed as an explicit accessibility action (Phase 2N-E, `CLARITY_GOALS_QA_REPORT.md` §8) —
/// invoking the exact same closure the revealed button already calls, guarded by the same
/// condition the gesture itself already checks.
struct SwipeToDeleteRow<Content: View>: View {
    let canDelete: Bool
    let onDelete: () -> Void
    var icon: String = "trash"
    var tint: Color = .expenseRed

    /// Leading (swipe-right) action — disabled unless a caller opts in.
    var canLeadingAction: Bool = false
    var onLeadingAction: () -> Void = {}
    var leadingIcon: String = "checkmark"
    var leadingTint: Color = .emerald
    var leadingAccessibilityActionName: String = "Action"

    @ViewBuilder let content: Content

    @State private var offset: CGFloat = 0
    private let revealWidth: CGFloat = 72

    var body: some View {
        ZStack {
            if canLeadingAction {
                HStack {
                    Button(action: performLeadingAction) {
                        Image(systemName: leadingIcon)
                            .foregroundStyle(.white)
                            .frame(width: revealWidth)
                            .frame(maxHeight: .infinity)
                    }
                    .background(leadingTint)
                    Spacer(minLength: 0)
                }
            }

            if canDelete {
                HStack {
                    Spacer(minLength: 0)
                    Button(action: delete) {
                        Image(systemName: icon)
                            .foregroundStyle(.white)
                            .frame(width: revealWidth)
                            .frame(maxHeight: .infinity)
                    }
                    .background(tint)
                }
            }

            content
                // Opaque so a revealed button is fully hidden at rest — matches the
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
                            guard canDelete || canLeadingAction else { return }
                            let translation = value.translation
                            guard abs(translation.width) > abs(translation.height) else { return }
                            if translation.width < 0 {
                                if offset > 0 {
                                    offset = max(0, offset + translation.width)
                                } else if canDelete {
                                    offset = max(translation.width, -revealWidth)
                                }
                            } else if translation.width > 0 {
                                if offset < 0 {
                                    offset = min(0, offset + translation.width)
                                } else if canLeadingAction {
                                    offset = min(translation.width, revealWidth)
                                }
                            }
                        }
                        .onEnded { value in
                            guard canDelete || canLeadingAction else { return }
                            let translation = value.translation
                            guard abs(translation.width) > abs(translation.height) else {
                                withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
                                return
                            }
                            withAnimation(.easeOut(duration: 0.2)) {
                                if canDelete, translation.width < -revealWidth / 2 {
                                    offset = -revealWidth
                                } else if canLeadingAction, translation.width > revealWidth / 2 {
                                    offset = revealWidth
                                } else {
                                    offset = 0
                                }
                            }
                        }
                )
                .accessibilityAction(named: "Delete", performAccessibilityDelete)
                .modify(when: canLeadingAction) {
                    $0.accessibilityAction(named: leadingAccessibilityActionName, performAccessibilityLeadingAction)
                }
        }
        .clipShape(Rectangle())
    }

    private func delete() {
        withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
        onDelete()
    }

    private func performLeadingAction() {
        withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
        onLeadingAction()
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

    /// The VoiceOver-triggered counterpart to `performLeadingAction()` — same reasoning as
    /// `performAccessibilityDelete()`, mirrored for the leading side.
    func performAccessibilityLeadingAction() {
        guard canLeadingAction else { return }
        onLeadingAction()
    }
}

private extension View {
    /// Applies `transform` only when `condition` holds — used here so the leading accessibility
    /// action is only ever registered for rows that actually opted into a leading swipe, instead
    /// of exposing an always-present but silently-no-op VoiceOver action on every other row.
    @ViewBuilder
    func modify<T: View>(when condition: Bool, @ViewBuilder _ transform: (Self) -> T) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
