import SwiftUI

/// A manual swipe-to-reveal-delete gesture for rows that live in a custom card/VStack layout
/// rather than a `List` — SwiftUI's `.swipeActions` modifier only works on List rows, so this
/// fills the gap for card-based lists like Plan's budget rows.
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
        }
        .clipShape(Rectangle())
    }

    private func delete() {
        withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
        onDelete()
    }
}
