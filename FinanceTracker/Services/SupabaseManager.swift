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

    /// Where the password-recovery email link redirects back into the app. Points at the
    /// `reset-password` Edge Function's landing page — an HTTPS URL, not the bare `financetracker:`
    /// scheme directly — because a custom URL scheme only resolves when opened straight from a
    /// device with the app installed; any other context (desktop, link-preview crawler, no app
    /// installed) left the link with nowhere to land. The landing page itself bridges into
    /// `\(urlScheme)://reset-password?code=...` (and shows a plain-language fallback if that
    /// doesn't resolve), so `RootView.onOpenURL`/`completePasswordRecovery` are unaffected — see
    /// `supabase/functions/reset-password/index.ts`. `scheme` tells the page which app install
    /// (prod/dev) actually requested this, since Supabase appends its own `code` query item on top.
    static var passwordRecoveryRedirectURL: URL {
        URL(string: "https://coktoiawbuxxgehnahhl.supabase.co/functions/v1/reset-password?scheme=\(urlScheme)")!
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