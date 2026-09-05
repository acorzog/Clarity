import SwiftUI

/// Renders a category's icon (SF Symbol or emoji) on a tinted circular badge,
/// resolving custom color/icon overrides with the parent HeadCategory as fallback.
struct CategoryIconView: View {
    let category: Category
    var size: CGFloat = 32

    private var color: Color { Color(hex: category.resolvedColorHex) }

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))

            if category.iconIsEmoji, let emoji = category.customIcon {
                Text(emoji)
                    .font(.system(size: size * 0.5))
            } else {
                Image(systemName: category.customIcon ?? category.headCategory.icon)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
    }
}
