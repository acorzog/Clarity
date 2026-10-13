import SwiftUI
import UIKit

/// The gradient avatar circle shared by `AccountView`'s header and `ProfileEditView`'s photo
/// picker — loads `avatarURL` through `AvatarImageCache` so a photo already seen this session
/// renders instantly instead of re-fetching, and falls back to `fallbackInitial` while loading or
/// when there's no photo set.
struct AvatarCircleView: View {
    let avatarURL: URL?
    let fallbackInitial: String
    var diameter: CGFloat = 76
    /// Driven by the caller's own loading state (e.g. `AccountView`'s initial profile fetch,
    /// `ProfileEditView`'s in-flight upload) — distinct from this view's own cache/download state,
    /// which never shows a spinner for an already-cached image.
    var isLoading: Bool = false

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient.emeraldSky)
                .frame(width: diameter, height: diameter)

            if isLoading {
                ProgressView()
                    .tint(.white)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
            } else {
                Text(fallbackInitial)
                    .font(.system(size: diameter * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .task(id: avatarURL) { await loadImage() }
    }

    @MainActor
    private func loadImage() async {
        guard let avatarURL else {
            image = nil
            return
        }
        if let cached = AvatarImageCache.shared.image(for: avatarURL) {
            image = cached
            return
        }
        guard
            let (data, _) = try? await URLSession.shared.data(from: avatarURL),
            let downloaded = UIImage(data: data)
        else {
            return
        }
        AvatarImageCache.shared.store(downloaded, for: avatarURL)
        image = downloaded
    }
}
