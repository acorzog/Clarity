import SwiftUI

/// The signed-in user's account screen — reachable from `ToolsView`'s Account section. Owns the
/// sign-out confirmation/error flow directly (moved here from `ToolsView`) now that there's a
/// dedicated screen for it.
struct AccountView: View {
    @Environment(\.signOutAction) private var signOutAction
    @Environment(\.modelContext) private var modelContext

    @State private var email: String?
    @State private var displayName: String?
    @State private var avatarURL: URL?
    @State private var isLoadingEmail = true
    @State private var showingSignOutConfirmation = false
    @State private var isSigningOut = false
    @State private var signOutErrorMessage: String?
    /// Phase 6.1 — shown only when `signOut()`'s own flush attempt couldn't clear every pending
    /// local change (offline, or the attempt genuinely failed), so the destructive discard is
    /// never silent.
    @State private var showingUnsyncedChangesWarning = false
    @State private var showingChangePassword = false
    @State private var showingChangeEmail = false
    @State private var showingEditProfile = false
    @State private var showingDeleteAccountConfirmation = false
    @State private var showingDeletePasswordConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deleteAccountErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: ClaritySpacing.xxl) {
                profileHeader

                VStack(alignment: .leading, spacing: ClaritySpacing.xxl) {
                    accountSettingsSection
                    signOutSection
                    deleteAccountSection
                }
            }
            .padding(ClaritySpacing.lg)
        }
        .darkScreenBackground()
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadProfile() }
        .alert("Sign Out", isPresented: $showingSignOutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                Task { await signOut() }
            }
        } message: {
            Text("Are you sure you want to sign out?")
        }
        .alert(
            "Couldn't Sign Out",
            isPresented: Binding(
                get: { signOutErrorMessage != nil },
                set: { isPresented in if !isPresented { signOutErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(signOutErrorMessage ?? "")
        }
        .alert("Unsynced Changes", isPresented: $showingUnsyncedChangesWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out Anyway", role: .destructive) {
                Task { await performSignOut() }
            }
        } message: {
            Text("Some changes haven't finished syncing. Signing out now will discard them from this device.")
        }
        .sheet(isPresented: $showingChangePassword) {
            ChangePasswordView()
        }
        .sheet(isPresented: $showingChangeEmail) {
            ChangeEmailView()
        }
        .sheet(isPresented: $showingEditProfile) {
            ProfileEditView(
                onSaved: { newName in displayName = newName },
                onAvatarChanged: { newURL in avatarURL = newURL }
            )
        }
        .alert("Delete Account", isPresented: $showingDeleteAccountConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Account", role: .destructive) {
                showingDeletePasswordConfirmation = true
            }
        } message: {
            Text("This permanently deletes your account and all its data. This cannot be undone.")
        }
        .sheet(isPresented: $showingDeletePasswordConfirmation) {
            DeleteAccountConfirmationView { password in
                Task { await deleteAccount(password: password) }
            }
        }
        .alert(
            "Couldn't Delete Account",
            isPresented: Binding(
                get: { deleteAccountErrorMessage != nil },
                set: { isPresented in if !isPresented { deleteAccountErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteAccountErrorMessage ?? "")
        }
    }

    /// A centered avatar + name/email, matching the "Welcome back"/"Create account" header style
    /// `LoginView`/`SignUpView` already use elsewhere in the auth flow. The avatar is the display
    /// name's (or, absent one, the email's) first letter in a gradient circle — no real profile
    /// photo exists yet (Phase C of the profile roadmap).
    private var profileHeader: some View {
        VStack(spacing: ClaritySpacing.md) {
            AvatarCircleView(
                avatarURL: avatarURL,
                fallbackInitial: avatarInitial,
                diameter: 76,
                isLoading: isLoadingEmail
            )

            Group {
                if let displayName, !displayName.isEmpty {
                    VStack(spacing: ClaritySpacing.xs) {
                        Text(displayName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.textPrimary)
                        Text(email ?? "")
                            .font(.caption)
                            .foregroundStyle(.textSecondary)
                    }
                } else {
                    VStack(spacing: ClaritySpacing.xs) {
                        Text("Signed in as")
                            .font(.caption)
                            .foregroundStyle(.textSecondary)
                        Text(email ?? "Unavailable")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.textPrimary)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            Button("Edit Profile") {
                showingEditProfile = true
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(LinearGradient.emeraldSky)
        }
        .padding(.top, ClaritySpacing.lg)
    }

    private var avatarInitial: String {
        if let displayName, let first = displayName.first {
            return String(first).uppercased()
        }
        guard let first = email?.first else { return "?" }
        return String(first).uppercased()
    }

    /// Both rows grouped into one card with a divider — the standard grouped-settings look,
    /// rather than each action getting its own full-width card.
    private var accountSettingsSection: some View {
        SectionCard(padding: 0) {
            VStack(spacing: 0) {
                accountSettingsRow(title: "Change Email", icon: "envelope.fill") {
                    showingChangeEmail = true
                }

                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.leading, ClaritySpacing.lg + 36 + ClaritySpacing.md)

                accountSettingsRow(title: "Change Password", icon: "key.fill") {
                    showingChangePassword = true
                }
            }
        }
    }

    private func accountSettingsRow(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: ClaritySpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: ClarityRadius.medium)
                        .fill(Color.white.opacity(0.08))
                    Image(systemName: icon)
                        .font(.subheadline)
                        .foregroundStyle(LinearGradient.emeraldSky)
                }
                .frame(width: 36, height: 36)

                Text(title)
                    .foregroundStyle(.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.textTertiary)
            }
            .padding(.horizontal, ClaritySpacing.lg)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var signOutSection: some View {
        SectionCard {
            Button {
                showingSignOutConfirmation = true
            } label: {
                if isSigningOut {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    Text("Sign Out")
                }
            }
            .buttonStyle(.clarityDestructive)
            .disabled(isSigningOut)
        }
    }

    /// Phase 6.0.5 — deliberately its own `SectionCard` below `signOutSection` rather than grouped
    /// with it, so the irreversible action never sits one tap away from the recoverable one.
    private var deleteAccountSection: some View {
        SectionCard {
            Button {
                showingDeleteAccountConfirmation = true
            } label: {
                if isDeletingAccount {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    Text("Delete Account")
                }
            }
            .buttonStyle(.clarityDestructive)
            .disabled(isDeletingAccount)
        }
    }

    @MainActor
    private func loadProfile() async {
        email = try? await SupabaseAuthService.shared.currentUserEmail()
        if let profile = try? await SupabaseAuthService.shared.fetchCurrentProfile() {
            displayName = profile.displayName
            avatarURL = profile.avatarURL.flatMap(URL.init(string:))
        }
        isLoadingEmail = false
    }

    /// Phase 6.1 — always tries the existing sync mechanism first (the same one pull-to-refresh
    /// uses), so a user with unsynced local changes doesn't silently lose them just by signing
    /// out. Only if real changes are still pending afterward — offline, or the attempt genuinely
    /// failed — does `showingUnsyncedChangesWarning` ask for an explicit, destructive confirmation
    /// before `performSignOut()` discards them.
    @MainActor
    private func signOut() async {
        isSigningOut = true
        defer { isSigningOut = false }

        await SyncCoordinator.shared.refresh(modelContext: modelContext)
        guard !SyncCoordinator.shared.hasPendingLocalChanges else {
            showingUnsyncedChangesWarning = true
            return
        }

        await performSignOut()
    }

    @MainActor
    private func performSignOut() async {
        isSigningOut = true
        defer { isSigningOut = false }

        do {
            try await SupabaseAuthService.shared.signOut()
            // SwiftData, CloudKit sync, and every other financial data store are untouched here —
            // signing out only affects the Supabase session; `RootView.authState` is the sole
            // source of truth for what's shown next. The local-store ownership marker (Phase 6.1)
            // is also left as-is: it only matters at the *next* sign-in, to detect whether that's
            // the same user coming back or a different one.
            signOutAction()
        } catch {
            signOutErrorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .signOut)
        }
    }

    /// Phase 6.0.5 (hardened). Unlike `signOut()`, this never checks for unsynced changes first —
    /// an account being permanently deleted has nothing left to sync to.
    ///
    /// Verifies `password` the same way `ChangePasswordView` verifies a current password: a real
    /// `signIn(email:password:)` call against GoTrue's own endpoint — never sent to the
    /// delete-account Edge Function itself, whose own request body the Supabase Dashboard logs in
    /// full by default (see `SupabaseAuthService.deleteAccount`'s doc comment). Only on success
    /// does it call `deleteAccount()`, which independently confirms server-side that this sign-in
    /// was recent before doing anything irreversible.
    @MainActor
    private func deleteAccount(password: String) async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        guard let email else {
            deleteAccountErrorMessage = SupabaseAuthService.userFacingMessage(for: SupabaseAuthError.notAuthenticated, flow: .deleteAccount)
            return
        }

        do {
            try await SupabaseAuthService.shared.signIn(email: email, password: password)
        } catch {
            // A wrong password surfaces through the ordinary sign-in error mapping — the account
            // is obviously untouched, nothing deletion-specific happened yet.
            deleteAccountErrorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .signIn)
            return
        }

        do {
            let response = try await SupabaseAuthService.shared.deleteAccount()
            if response.avatarCleanupFailed {
                // Non-fatal — the account itself is already gone, this is just a leftover Storage
                // blob. Logged the same way `SyncCoordinator`'s own diagnostics are, so it's visible
                // in device logs if this account's deletion is ever investigated; the authoritative
                // record is the Edge Function's own server-side log (Dashboard → Edge Functions →
                // delete-account → Logs), since nothing survives locally past `finishAccountDeletion()`.
                print("[AccountDeletion] avatar cleanup failed server-side — the avatars bucket is public for reads, so this blob stays publicly viewable until removed manually")
            }
            await finishAccountDeletion()
        } catch {
            if (error as? AccountDeletionError) == .ambiguous {
                // The ONE structured outcome meaning "may already be deleted" — GoTrue's own
                // `user_not_found` code, distinct from a merely invalid/expired/revoked session
                // (`.sessionInvalid`, handled in the branch below). Cleaning up locally and
                // signing out is the safe move either way; a user whose account wasn't actually
                // deleted just signs in again.
                await finishAccountDeletion()
            } else if error is AccountDeletionError {
                // Every other structured failure — a stale-but-otherwise-valid sign-in
                // (`.reauthenticationRequired`), a genuinely invalid/revoked session
                // (`.sessionInvalid`), a wallet conflict, or a hard failure — just surfaces its
                // message, same as `ChangeEmailView`/`ChangePasswordView` do for their own
                // verification failures. None of these may ever be treated as even possible
                // success: only `.ambiguous` above may.
                deleteAccountErrorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .deleteAccount)
            } else {
                // Not a structured response at all — a transport-level failure (dropped
                // connection, timeout) on the delete-account call itself (the preceding `signIn`
                // already succeeded, so the password is confirmed correct). This is
                // indistinguishable, from here, from "the Edge Function already succeeded and
                // only the response was lost," so local data and the session are deliberately
                // left untouched rather than guessing either way. Retrying is always safe: if
                // deletion already happened, the retry's `getUser()` call fails with GoTrue's
                // `user_not_found` code, which resolves via the `.ambiguous` branch above; if it
                // didn't, signing in again and retrying just tries again normally.
                deleteAccountErrorMessage = "We couldn't confirm whether this completed. Check your connection, then tap Delete Account again — retrying is always safe."
            }
        }
    }

    /// Only reached once the remote account deletion is confirmed (or ambiguously may already
    /// have happened) — wipes local data best-effort, then signs out unconditionally even if that
    /// wipe failed, since there's no account left server-side for an active session to protect.
    @MainActor
    private func finishAccountDeletion() async {
        LocalAccountTransition.wipeAfterAccountDeletion(
            modelContext: modelContext,
            ownerStore: UserDefaultsLocalStoreOwnerStore(),
            syncCoordinator: SyncCoordinator.shared
        )
        try? await SupabaseAuthService.shared.signOut()
        signOutAction()
    }
}

#Preview {
    NavigationStack {
        AccountView()
    }
}
