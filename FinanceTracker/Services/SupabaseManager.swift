import Foundation
import Supabase

final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    /// Derived from the running bundle (mirrors `SharedModelContainer.appGroupID`'s pattern) so
    /// this same source file resolves to each target's own already-registered URL scheme
    /// (`financetracker` / `financetrackerdev` — see `project.yml`) instead of hardcoding one.
    private static var urlScheme: String {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        return bundleID.hasSuffix(".dev") ? "financetrackerdev" : "financetracker"
    }

    /// Where the password-recovery email link redirects back into the app — Supabase appends its
    /// PKCE `code` as a query item and 302s here after validating the emailed token.
    static var passwordRecoveryRedirectURL: URL {
        URL(string: "\(urlScheme)://reset-password")!
    }

    /// Where the "confirm your signup" email link redirects back into the app. Kept distinct
    /// from `passwordRecoveryRedirectURL` — both are a PKCE `code` exchange on arrival, but
    /// `RootView.onOpenURL` needs to tell them apart to show "email confirmed" rather than
    /// incorrectly routing a brand-new signup into `SetNewPasswordView`.
    static var emailConfirmationRedirectURL: URL {
        URL(string: "\(urlScheme)://email-confirmed")!
    }

    /// Where the "confirm your email change" link redirects back into the app — Phase 6.0.3.
    /// Deliberately its own host, distinct from `emailConfirmationRedirectURL`: a brand-new
    /// signup confirming for the first time and an already-signed-in user changing their email
    /// are different events (the former seeds local defaults, the latter never does), and
    /// `RootView.onOpenURL` needs to tell them apart to route to the right one.
    static var emailChangeRedirectURL: URL {
        URL(string: "\(urlScheme)://email-changed")!
    }

    private init() {
        client = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.publishableKey,
            options: SupabaseClientOptions(
                auth: .init(redirectToURL: Self.passwordRecoveryRedirectURL)
            )
        )
    }
}