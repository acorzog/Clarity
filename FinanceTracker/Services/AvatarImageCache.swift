import UIKit

/// In-memory cache for the signed-in user's avatar thumbnail, keyed by its (cache-busted)
/// Supabase Storage URL. `SupabaseAuthService.uploadAvatar` always mints a new URL — via a fresh
/// `cacheNonce` — whenever the photo actually changes, so caching by URL never risks serving a
/// stale image: a different photo always has a different key, and the same photo is never
/// re-downloaded just because a view holding it reappeared. `NSCache` (not a plain dictionary) so
/// it can be trimmed automatically under memory pressure.
final class AvatarImageCache {
    static let shared = AvatarImageCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {}

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}
