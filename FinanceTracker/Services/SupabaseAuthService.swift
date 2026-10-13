import Foundation
import Supabase

/// What `SupabaseAuthService.signUp` resolved to — Supabase returns a full session when email
/// confirmation is disabled for the project, and only a `User` (no session) when it's required.
/// `SignUpView` uses this to decide whether to sign the new user straight in or send them back to
/// `LoginView` with a "check your email" message.
enum SignUpOutcome: Equatable {
    case signedIn
    case confirmationRequired
}

/// Which auth flow a `SupabaseAuthError`/Supabase `AuthError` is being surfaced for — lets
/// `userFacingMessage` fall back to a flow-appropriate generic message when the error doesn't map
/// to anything more specific, without every call site repeating its own fallback string.
enum AuthFlow {
    case signIn, signUp, resetPassword, signOut, recoveryLink, updatePassword, emailConfirmationLink
    case reauthenticate, changeEmail, emailChangeLink, updateProfile, updateAvatar, deleteAccount

    fileprivate var genericFallback: String {
        switch self {
        case .signIn: "Couldn't sign in. Check your email and password and try again."
        case .signUp: "Couldn't create your account. Please try again."
        case .resetPassword: "Couldn't send the reset email. Please try again."
        case .signOut: "Couldn't sign out. Check your connection and try again."
        case .recoveryLink: "This password reset link is invalid or has expired. Request a new one."
        case .updatePassword: "Couldn't update your password. Please try again."
        case .emailConfirmationLink: "This confirmation link is invalid or has expired. Try signing up again."
        case .reauthenticate: "Couldn't send a confirmation code. Please try again."
        case .changeEmail: "Couldn't change your email. Please try again."
        case .emailChangeLink: "This confirmation link is invalid or has expired. Request the change again."
        case .updateProfile: "Couldn't update your profile. Please try again."
        case .updateAvatar: "Couldn't update your photo. Please try again."
        case .deleteAccount: "Couldn't delete your account. Please try again."
        }
    }
}

@MainActor
final class SupabaseAuthService {

    static let shared = SupabaseAuthService()

    private let client = SupabaseManager.shared.client

    private init() {}

    func signIn(email: String, password: String) async throws {
        try await client.auth.signIn(
            email: email,
            password: password
        )
    }

    func signUp(email: String, password: String) async throws -> SignUpOutcome {
        let response = try await client.auth.signUp(
            email: email,
            password: password,
            redirectTo: SupabaseManager.emailConfirmationRedirectURL
        )
        switch response {
        case .session: return .signedIn
        case .user: return .confirmationRequired
        }
    }

    /// Supabase's `/recover` endpoint always returns success regardless of whether the email
    /// matches an account, to avoid leaking which emails are registered — callers should show the
    /// same "check your email" confirmation either way rather than branching on the result.
    func resetPassword(email: String) async throws {
        try await client.auth.resetPasswordForEmail(email)
    }

    /// Exchanges the PKCE `code` in a password-recovery deep link (opened via `RootView.onOpenURL`)
    /// for a real session — the code verifier `resetPassword` stashed locally is still on disk as
    /// long as this is the same device/app install, which is the only case a custom URL scheme
    /// redirect can reach anyway. Throws (link already used, expired, or tampered with) rather
    /// than silently failing, so the caller can show `SetNewPasswordView` only on success.
    @discardableResult
    func completePasswordRecovery(url: URL) async throws -> Session {
        try await client.auth.session(from: url)
    }

    /// Exchanges the PKCE `code` in a "confirm your signup" deep link for a session — same
    /// underlying mechanism as `completePasswordRecovery`, kept as its own method (rather than one
    /// shared `exchangeSession` called with a flow argument) so each call site in `RootView` reads
    /// as what it's actually completing.
    @discardableResult
    func completeEmailConfirmation(url: URL) async throws -> Session {
        try await client.auth.session(from: url)
    }

    /// Sets a new password on the current session — used both by `SetNewPasswordView` (the
    /// session `completePasswordRecovery` just established) and `ChangePasswordView` (an
    /// already-signed-in user). `nonce` is the code `reauthenticate()` sent, required only when
    /// the Supabase project has "secure password change" enabled and only on a retry after the
    /// first attempt threw `reauthenticationNeeded` — `nil` (the default) preserves the original
    /// recovery-flow behavior exactly.
    func updatePassword(_ newPassword: String, nonce: String? = nil) async throws {
        try await client.auth.update(user: UserAttributes(password: newPassword, nonce: nonce))
    }

    /// Requests an email change for the current session — Supabase doesn't apply this
    /// immediately: it sends a confirmation link (via `UserAttributes.email`'s own PKCE
    /// challenge, set automatically by the SDK whenever `email` is non-nil) to the new address
    /// and only actually changes it once that link is opened and exchanged, via
    /// `completeEmailChange`. `nonce` mirrors `updatePassword`'s — required only on a retry after
    /// a first attempt threw `reauthenticationNeeded`.
    func changeEmail(to newEmail: String, nonce: String? = nil) async throws {
        try await client.auth.update(
            user: UserAttributes(email: newEmail, nonce: nonce),
            redirectTo: SupabaseManager.emailChangeRedirectURL
        )
    }

    /// Exchanges the PKCE `code` in a "confirm your email change" deep link for a session
    /// reflecting the now-updated email — same underlying mechanism as `completePasswordRecovery`/
    /// `completeEmailConfirmation`, kept as its own method so `RootView` can tell this apart from
    /// a brand-new signup confirming for the first time (this is always an existing,
    /// already-authenticated user; a signup confirmation never is).
    @discardableResult
    func completeEmailChange(url: URL) async throws -> Session {
        try await client.auth.session(from: url)
    }

    /// Sends a one-time confirmation code to the signed-in user's email — the first step of
    /// Supabase's reauthentication flow, required before a sensitive change (password, email,
    /// account deletion) on projects with "secure password/email change" enabled. This call alone
    /// doesn't verify anything; the code the user enters becomes a nonce the caller attaches via
    /// `UserAttributes.nonce` to whichever sensitive request follows — Supabase only validates it
    /// at that point, which is why this type has no separate "verify code" method. Shared by every
    /// sensitive-operation flow rather than duplicated per feature (password/email change, account
    /// deletion all need the exact same first step).
    func reauthenticate() async throws {
        try await client.auth.reauthenticate()
    }

    /// Calls the `delete-account` Edge Function (Phase 6.0.5) — the only place that can delete the
    /// Supabase Auth user itself, since that requires the service-role key, which never ships in
    /// this app. Takes no parameters at all: the caller must already have re-verified their
    /// password via `signIn(email:password:)` (the same GoTrue endpoint `ChangePasswordView`
    /// already uses) immediately before calling this — see `AccountView.deleteAccount`.
    ///
    /// An earlier version sent the password in this function's own request body and had it
    /// verified server-side via `signInWithPassword`. That's real verification, but the
    /// Supabase Dashboard's Edge Functions "Invocations" view captures full request bodies by
    /// default with no documented way to disable or redact that — so a plaintext password would
    /// sit in a retained log. Verifying it via the ordinary `signIn` call instead means the
    /// password only ever transits the same path every login already does. The Edge Function
    /// independently confirms that sign-in was *recent* (via `auth.users.last_sign_in_at`,
    /// fetched server-side through the Admin API — never a client-supplied timestamp, and never
    /// satisfied by merely holding a valid-but-stale JWT) rather than trusting this client's word
    /// for it.
    ///
    /// Throws `AccountDeletionError`, never a bare `FunctionsError`, so callers can branch on the
    /// specific failure without parsing response bodies themselves.
    func deleteAccount() async throws -> AccountDeletionResponse {
        do {
            return try await client.functions.invoke("delete-account")
        } catch let FunctionsError.httpError(_, data) {
            let body = try? JSONDecoder().decode(AccountDeletionErrorBody.self, from: data)
            switch body?.error {
            case "user_not_found":
                // The ONE outcome the caller may treat as "may already be deleted": GoTrue's own
                // `requireAuthentication` returns this distinct code specifically when the JWT's
                // signature and session are both fine but the `sub` claim's user row is gone —
                // e.g. a retried call after a prior invocation's `deleteUser` already succeeded
                // but its response never arrived. Never confused with a merely expired or
                // revoked session (that's `unauthenticated` below, handled separately) — see
                // `AccountView.deleteAccount`.
                throw AccountDeletionError.ambiguous
            case "unauthenticated":
                // A plain invalid/expired/revoked session — unrelated to deletion. Must NOT be
                // treated as ambiguous: the account is presumably still fully intact, so local
                // data and the (already-dead) session are left alone and the user is told to
                // sign in again, not funneled into a "maybe this worked" path.
                throw AccountDeletionError.sessionInvalid
            case "reauthentication_required":
                // The pre-call `signIn` succeeded, but the Edge Function's own server-side check
                // of `last_sign_in_at` didn't find it recent enough (clock skew, an unusually
                // slow network hop between the two calls). Retrying — sign in again, then delete
                // again — resolves this normally.
                throw AccountDeletionError.reauthenticationRequired
            case "wallet_conflict":
                throw AccountDeletionError.walletConflict(message: body?.message)
            default:
                throw AccountDeletionError.failed(message: body?.message)
            }
        }
    }

    func currentUserID() async throws -> UUID? {
        try await client.auth.session.user.id
    }

    func currentUserEmail() async throws -> String? {
        try await client.auth.session.user.email
    }

    func fetchCurrentProfile() async throws -> ProfileDTO {
        guard let userID = try await currentUserID() else {
            throw SupabaseAuthError.notAuthenticated
        }

        return try await client
            .from("profiles")
            .select()
            .eq("id", value: userID.uuidString)
            .single()
            .execute()
            .value
    }

    /// Sets or clears (`nil`) the current user's display name — Phase 6.0.6 (profile roadmap,
    /// Phase B). No photo upload yet; `avatar_url` isn't touched here. Unlike email/password, a
    /// display name isn't a Supabase "secure change" category, so this never requires
    /// reauthentication — it's a plain `profiles` table update, gated only by the row-level
    /// security policy restricting it to the row's own owner.
    func updateDisplayName(_ displayName: String?) async throws {
        guard let userID = try await currentUserID() else {
            throw SupabaseAuthError.notAuthenticated
        }
        try await client
            .from("profiles")
            .update(ProfileDisplayNameUpdate(displayName: displayName))
            .eq("id", value: userID.uuidString)
            .execute()
    }

    /// Uploads `imageData` (already resized/compressed by the caller — `ProfileEditView`) as the
    /// current user's avatar and records the resulting public URL on `profiles.avatar_url`. Always
    /// writes to the same fixed path (`{userID}/avatar.jpg`) with `upsert: true` so each new photo
    /// replaces the previous one in the `avatars` bucket rather than accumulating orphaned files.
    /// The `avatars` bucket is public (Phase A Dashboard config), so the URL itself never expires —
    /// but it also never changes when the file is replaced, so a `cacheNonce` is appended to force
    /// `AsyncImage`/the CDN to fetch the new bytes instead of serving a stale cached copy under the
    /// same URL.
    @discardableResult
    func uploadAvatar(_ imageData: Data) async throws -> URL {
        guard let userID = try await currentUserID() else {
            throw SupabaseAuthError.notAuthenticated
        }

        let path = Self.avatarStoragePath(for: userID)
        _ = try await client.storage.from("avatars").upload(
            path,
            data: imageData,
            options: FileOptions(contentType: "image/jpeg", upsert: true)
        )

        let publicURL = try client.storage.from("avatars").getPublicURL(
            path: path,
            cacheNonce: UUID().uuidString
        )

        try await client
            .from("profiles")
            .update(ProfileAvatarURLUpdate(avatarURL: publicURL.absoluteString))
            .eq("id", value: userID.uuidString)
            .execute()

        return publicURL
    }

    /// The `avatars` bucket path for `userID` — a separate, testable static function rather than
    /// inlined into `uploadAvatar`, since getting this wrong is exactly what caused a real bug:
    /// Postgres always renders `auth.uid()::text` in lowercase canonical form, but `UUID.
    /// uuidString` is uppercase, and the storage policy's `(storage.foldername(name))[1] = auth.
    /// uid()::text` comparison is case-sensitive — an uppercase path is silently rejected (403
    /// "new row violates row-level security policy") even for the file's own owner.
    nonisolated static func avatarStoragePath(for userID: UUID) -> String {
        "\(userID.uuidString.lowercased())/avatar.jpg"
    }

    /// Whether a Supabase session already exists (and is valid, refreshing it if needed) —
    /// used by `RootView` at launch to decide between `LoginView` and `MainTabView` without
    /// forcing a fresh sign-in on every app start. `client.auth.session` throws `AuthError.
    /// sessionMissing` when there's none, which this collapses to `false`.
    func hasActiveSession() async -> Bool {
        (try? await client.auth.session) != nil
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }

    /// The live stream of Supabase auth state changes — `RootView`'s single centralized listener
    /// (Phase 6.0.4) subscribes to this once, for the app's lifetime, to notice when a session
    /// becomes invalid out from under the app (revoked server-side, or its own refresh token
    /// expiring) rather than only when the user explicitly signs out. The SDK always emits
    /// `.initialSession` immediately on subscribing (with whatever session already exists, or
    /// none) — `RootAuthState.shouldTransitionToSignedOut` only ever acts on `.signedOut`, so that
    /// first emission is a harmless no-op here, not a race with `RootView`'s own launch-time
    /// `hasActiveSession()` check. `nonisolated` so obtaining the stream itself doesn't require
    /// hopping onto the main actor.
    nonisolated var authStateChanges: AsyncStream<(event: AuthChangeEvent, session: Session?)> {
        client.auth.authStateChanges
    }
}

enum SupabaseAuthError: Error {
    case notAuthenticated
}

struct AccountDeletionResponse: Decodable {
    let success: Bool
    let avatarCleanupFailed: Bool
}

private struct AccountDeletionErrorBody: Decodable {
    let error: String
    let message: String?
}

enum AccountDeletionError: Error, Equatable {
    /// The pre-call `signIn` succeeded, but the Edge Function's own server-side freshness check
    /// (on `auth.users.last_sign_in_at`, via the Admin API) rejected it as too old. Distinct from
    /// `.sessionInvalid` — the session itself is fine, just not recently (re)established enough.
    case reauthenticationRequired
    case walletConflict(message: String?)
    /// GoTrue's `requireAuthentication` returned its specific `user_not_found` code: the JWT's
    /// signature and session are both fine, but the `sub` claim's user row is gone. The one
    /// outcome plausibly meaning "already deleted by a prior call whose response never arrived."
    /// Never treated as confirmed success — only as "safe to proceed with local cleanup."
    case ambiguous
    /// A plain invalid, expired, or revoked session (GoTrue's `bad_jwt`/`session_not_found`, or
    /// no Authorization header at all) — unrelated to deletion. Deliberately distinct from
    /// `.ambiguous`: the account is presumably untouched, so this must never trigger local
    /// cleanup or be treated as even possible success.
    case sessionInvalid
    case failed(message: String?)
}

extension SupabaseAuthService {
    /// Maps a thrown error to copy a user should actually see — never the raw PostgREST/GoTrue
    /// message (that's what `SupabaseTestView`'s diagnostics are for). Only the handful of
    /// `AuthError.errorCode` cases a real user can hit from these flows are covered explicitly;
    /// anything else (including non-`AuthError` failures) falls back to `flow`'s generic message.
    nonisolated static func userFacingMessage(for error: Error, flow: AuthFlow) -> String {
        if error is URLError {
            return "Check your internet connection and try again."
        }
        if let deletionError = error as? AccountDeletionError {
            switch deletionError {
            case .reauthenticationRequired:
                return "Please sign in again, then retry deleting your account."
            case .walletConflict(let message):
                return message ?? "Another account has transactions linked to one of your wallets."
            case .ambiguous:
                return "We couldn't confirm this completed. If your account still exists, sign in again and retry."
            case .sessionInvalid:
                return "Your session is no longer valid. Please sign in again."
            case .failed:
                return flow.genericFallback
            }
        }
        guard let authError = error as? AuthError else {
            return flow.genericFallback
        }
        // `ErrorCode` is a plain struct with static members, not an enum — it doesn't support
        // `switch`'s `case .x:` pattern matching, so this compares `errorCode` values directly.
        let code = authError.errorCode
        if code == .invalidCredentials {
            return "Incorrect email or password."
        } else if code == .emailExists || code == .userAlreadyExists || code == .identityAlreadyExists {
            return "An account with that email already exists."
        } else if code == .weakPassword {
            return "Choose a stronger password — at least 8 characters."
        } else if code == .emailNotConfirmed {
            return "Confirm your email before signing in — check your inbox for the link."
        } else if code == .overEmailSendRateLimit || code == .overRequestRateLimit || code == .overSMSSendRateLimit {
            return "Too many attempts. Wait a moment and try again."
        } else if code == .userBanned {
            return "This account has been disabled."
        } else if code == .signupDisabled {
            return "Sign-ups aren't available right now."
        } else if code == .sessionNotFound {
            return "Your session expired. Please sign in again."
        } else if code == .flowStateNotFound || code == .flowStateExpired || code == .otpExpired {
            // Falls through to `flow`'s own generic message rather than a hardcoded one here —
            // "invalid or expired" applies to both the recovery and email-confirmation links, but
            // each flow's fallback already says the right thing for which link it was.
            return flow.genericFallback
        } else if code == .reauthenticationNeeded {
            return "For your security, please confirm it's you before continuing."
        } else if code == .reauthenticationNotValid {
            return "That code wasn't correct. Please try again."
        } else if code == .samePassword {
            return "Your new password must be different from your current password."
        } else {
            return flow.genericFallback
        }
    }

    nonisolated static func isValidEmail(_ email: String) -> Bool {
        let pattern = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
        return email.range(of: pattern, options: .regularExpression) != nil
    }

    static let minimumPasswordLength = 8

    /// Whether `error` is specifically Supabase asking for reauthentication before a sensitive
    /// change can proceed — the signal a caller (`ChangePasswordView`, and the upcoming change-
    /// email/account-deletion flows) uses to present `ReauthenticationView` rather than just
    /// showing an error. Deliberately its own predicate rather than string-matching
    /// `userFacingMessage`'s output, which is display text, not a reliable thing to branch logic
    /// on.
    nonisolated static func requiresReauthentication(_ error: Error) -> Bool {
        (error as? AuthError)?.errorCode == .reauthenticationNeeded
    }

    /// Whether `error` means the Edge Function's own freshness check rejected an otherwise-valid,
    /// just-verified sign-in as too old — as opposed to a conflict, an unrelated invalid session,
    /// or a failure that leaves the account and local data exactly as they were. Exposed
    /// distinctly from `userFacingMessage` so a caller could branch on it (e.g. to re-prompt)
    /// even though `AccountView` currently just surfaces its message like any other deletion
    /// failure.
    nonisolated static func deletionRequiresReauthentication(_ error: Error) -> Bool {
        switch error as? AccountDeletionError {
        case .reauthenticationRequired: true
        default: false
        }
    }
}

struct ProfileDTO: Decodable {
    let id: UUID
    let createdAt: Date
    /// `nil` until the user sets one via `SupabaseAuthService.updateDisplayName`.
    let displayName: String?
    /// `nil` until the user sets one via `SupabaseAuthService.uploadAvatar`.
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }
}

/// The `profiles` table update payload for `updateDisplayName` — a separate, minimal `Encodable`
/// type rather than reusing `ProfileDTO` itself, so this PATCH body only ever contains the one
/// column actually being changed (`id`/`created_at` are never written by the client).
private struct ProfileDisplayNameUpdate: Encodable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

/// The `profiles` table update payload for `uploadAvatar` — mirrors `ProfileDisplayNameUpdate`'s
/// reasoning: only `avatar_url` is ever written by this PATCH.
private struct ProfileAvatarURLUpdate: Encodable {
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case avatarURL = "avatar_url"
    }
}