import SwiftUI
import SwiftData
import CoreData
import WidgetKit
import os
import Supabase

/// Diagnoses the automatic-sync trigger chain (`ModelContext.didSave`, `scheduleSync`,
/// `performSync`'s step-by-step progress) — originally added to debug why sync didn't appear to
/// trigger after creating a new Wallet, kept on as the same debugging aid for the equivalent Entry
/// investigation (Phase 4G). Phase 4G.1 — gated entirely behind `#if DEBUG`: every call site
/// still reads as plain `SyncDiagnosticLog.log("...")`, but in a Release build the `message`
/// argument is an `@autoclosure` that's never even evaluated, and the function body is empty — so
/// none of the string-interpolation work building these (sometimes quite detailed) messages, nor
/// the `Logger`/`print` calls themselves, costs anything outside of DEBUG builds. This is purely a
/// debugging aid; it is never the place real failures are reported — see `SyncCoordinator`'s own
/// `Logger` for that.
enum SyncDiagnosticLog {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.andreacorzo.FinanceTracker", category: "SyncDiagnostics")
    #endif

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        let resolved = message()
        logger.log("\(resolved, privacy: .public)")
        print("[SYNC-DIAG] \(resolved)")
        #endif
    }
}

/// The root-level auth gate — which of {checking for an existing Supabase session, signed out,
/// signed in} content `RootView` shows beneath its lock-screen/launch-splash overlays. Pure and
/// dependency-free (no Supabase client access) so the resolution rule can be unit-tested without
/// a live session — see `RootAuthStateTests`.
enum RootAuthState: Equatable {
    case loading
    case signedOut
    case signedIn

    /// What `RootView`'s launch check resolves `.loading` to once it knows whether a session
    /// already exists.
    static func resolved(hasActiveSession: Bool) -> RootAuthState {
        hasActiveSession ? .signedIn : .signedOut
    }

    /// Whether `RootView`'s launch `.task` should call `SeedData.seedIfNeeded` for this resolved
    /// state — Phase 4A. Only ever true for `.signedOut`: a local-only user with no Supabase
    /// account has nothing else to populate the store with. `.signedIn` deliberately seeds
    /// nothing (seeding unconditionally at launch used to mean an existing Supabase user on a
    /// fresh install got a generic starter set inserted locally with no `remoteID`, which
    /// automatic sync would then push to Supabase as duplicate data); `.loading` never reaches
    /// this check in practice, since `RootView` only calls `SeedData.seedIfNeeded` in the same
    /// `.task` that resolves `.loading` away, but is included for exhaustiveness.
    var shouldSeedLocalDefaults: Bool {
        self == .signedOut
    }

    /// What `authState` becomes once `ToolsView`'s Sign Out action confirms a successful
    /// `SupabaseAuthService.signOut()` call — unconditionally `.signedOut`, regardless of which
    /// state sign-out was initiated from. Named (rather than inlining `.signedOut` at the call
    /// site) so the transition reads the same way `resolved(hasActiveSession:)` does, and so it's
    /// covered by `RootAuthStateTests` alongside it.
    static var signedOutByUser: RootAuthState { .signedOut }

    /// What `authState` becomes when `RootView`'s auth-state-change listener (Phase 6.0.4)
    /// detects the session was invalidated out from under the app — revoked server-side, or its
    /// own refresh token expiring — while the app still believed it was signed in. Resolves to
    /// the same `.signedOut` value as `signedOutByUser`; kept as its own named case purely so each
    /// transition's trigger stays unambiguous at its call site and in `RootAuthStateTests`, not
    /// because the two states actually differ.
    static var signedOutBySessionInvalidation: RootAuthState { .signedOut }

    /// Pure decision for `RootView`'s auth-state-change listener: whether a given
    /// `AuthChangeEvent` arriving while `authState` is `currentState` should transition it to
    /// `.signedOut`. Dependency-free (no Supabase client, no live `Session`) so it's
    /// unit-testable without a real auth stream — see `RootAuthStateTests`.
    ///
    /// Only `.signedOut` ever transitions, and only from `.signedIn` — this is what prevents a
    /// redundant/duplicate transition from the app's own explicit sign-out (which already flips
    /// `authState` itself, through `signOutAction`, independently of this listener) and ignores
    /// every other event (`.initialSession`, `.signedIn`, `.tokenRefreshed`, `.userUpdated`,
    /// `.passwordRecovery`, `.mfaChallengeVerified`, `.userDeleted`) entirely — this listener's
    /// one job is noticing an externally-invalidated session, nothing else.
    static func shouldTransitionToSignedOut(for event: AuthChangeEvent, currentState: RootAuthState) -> Bool {
        event == .signedOut && currentState == .signedIn
    }
}

/// Lets `ToolsView`'s Sign Out action (a descendant of `MainTabView`, several levels below
/// `RootView`) flip `authState` back to `.signedOut` after a successful `SupabaseAuthService.
/// signOut()` call — without giving `ToolsView` its own copy of the auth state. `RootView`
/// injects the real closure only while `authState == .signedIn`; the default no-op is never
/// exercised outside of previews/tests that render `ToolsView` on its own.
private struct SignOutActionKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var signOutAction: () -> Void {
        get { self[SignOutActionKey.self] }
        set { self[SignOutActionKey.self] = newValue }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @AppStorage("appLockEnabled") private var lockEnabled = false
    /// Whether the one-time "turn on Face ID/Touch ID?" nudge (see `maybeSuggestAppLock`) has
    /// already been shown — persisted so it's shown at most once ever, not once per sign-in.
    @AppStorage("hasSeenAppLockSuggestion") private var hasSeenAppLockSuggestion = false
    @State private var showingAppLockSuggestion = false
    @State private var showingAppLockSuggestionSetPIN = false
    @State private var isUnlocked = false
    @State private var showingAddTransaction = false
    @State private var showingSplash = true
    @State private var authState: RootAuthState = .loading
    @State private var showingSetNewPassword = false
    @State private var recoveryLinkErrorMessage: String?
    @State private var showingEmailConfirmedAlert = false
    @State private var emailConfirmationErrorMessage: String?
    @State private var showingEmailChangedAlert = false
    @State private var emailChangeErrorMessage: String?
    /// Phase 6.1 — not `@State`: a plain reference-type service, same reasoning as `SyncCoordinator
    /// .shared` being read directly rather than stored as state.
    private let localStoreOwnerStore: LocalStoreOwnerStoring = UserDefaultsLocalStoreOwnerStore()

    var body: some View {
        ZStack {
            content

            // Gated to `.signedIn`: locking the login screen itself behind the app-lock would
            // strand a signed-out user who enabled app lock during a previous session.
            if lockEnabled && !isUnlocked && authState == .signedIn {
                LockScreenView { isUnlocked = true }
                    .transition(.opacity)
                    .zIndex(1)
            }

            if showingSplash {
                LaunchScreenView()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isUnlocked)
        .animation(.easeInOut(duration: 0.2), value: authState)
        .task {
            // `LaunchScreenView`'s own intro (3 staggered bar springs + wordmark fade) finishes
            // playing out around ~0.82s in (last bar starts its 0.45s spring at a 0.24s delay;
            // the wordmark's 0.4s fade starts at 0.42s) — this hold was 1.3s, nearly 0.5s of pure
            // idle time after the animation had already finished. Trimmed to just past that
            // completion point instead of an arbitrary round number, so the splash still reads as
            // deliberate (nothing gets cut off mid-animation) rather than merely faster.
            try? await Task.sleep(for: .seconds(1))
            withAnimation(.easeInOut(duration: 0.7)) {
                showingSplash = false
            }
        }
        .task {
            // Runs concurrently with the splash timer above — resolving the session doesn't wait
            // on (or block) the splash animation.
            let hasActiveSession = await SupabaseAuthService.shared.hasActiveSession()
            let resolvedState = RootAuthState.resolved(hasActiveSession: hasActiveSession)

            if resolvedState == .signedIn {
                // Phase 6.1 — routed through the same centralized path every other signed-in
                // transition uses, so a restored launch-time session can't bypass the local-store
                // ownership check either. Never seeds here: an existing signed-in user's data
                // comes from sync, not a generic starter set (see `establishSignedIn`'s own
                // doc comment).
                let userID = try? await SupabaseAuthService.shared.currentUserID()
                await establishSignedIn(userID: userID, seedIfNewAccount: false)
            } else {
                authState = resolvedState
                // Seeding moved here from `FinanceTrackerApp.init()` (Phase 4A) — see
                // `RootAuthState.shouldSeedLocalDefaults`'s doc comment for why this must only run
                // for a signed-out/local-only user, never unconditionally at launch.
                if resolvedState.shouldSeedLocalDefaults {
                    do {
                        try SeedData.seedIfNeeded(context: modelContext)
                    } catch {
                        // Logged, not swallowed silently — a failed save here must never be
                        // mistaken for a successful seed. Non-fatal: the empty-store gate will
                        // simply try again on the next launch, exactly as it does today for a
                        // genuinely fresh install.
                        SyncDiagnosticLog.log("SeedData.seedIfNeeded failed to save: \(error)")
                    }
                }
            }
            // Automatic sync trigger 1 (Phase 4G.3B) — the first authenticated activation, right
            // here at launch (scenePhase's own `.active` case below never fires for the *initial*
            // value, only on later transitions). `.loading`/`.signedOut` never reach here. Runs
            // after `establishSignedIn` above has already resolved any local-store wipe, so this
            // can never sync against a store that still needs clearing.
            if resolvedState == .signedIn {
                SyncCoordinator.shared.handleAppBecameActive(modelContext: modelContext)
            }
        }
        // Phase 6.0.4 — the single centralized listener for Supabase auth state changing out from
        // under the app (session revoked server-side, or its refresh token itself expiring) while
        // the app is running, not just at launch or through the app's own explicit sign-in/out
        // calls. Runs for `RootView`'s entire lifetime (the app's whole lifetime, in practice,
        // since it's the `WindowGroup`'s root) and independently of the two `.task`s above —
        // subscribing never blocks on, or waits for, the launch-time session check.
        .task {
            for await (event, _) in SupabaseAuthService.shared.authStateChanges {
                guard RootAuthState.shouldTransitionToSignedOut(for: event, currentState: authState) else { continue }
                // Deliberately touches nothing else — no local-store wipe, no owner-marker
                // change, no SyncCoordinator reset. Exactly like the app's own explicit sign-out
                // (`AccountView.performSignOut`), losing the Supabase session must never imply
                // losing local data; the user's own local store is left untouched so it's ready
                // to sync again the moment they sign back in.
                authState = .signedOutBySessionInvalidation
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                isUnlocked = false
                WidgetCenter.shared.reloadAllTimelines()
                // Stops the periodic timer (Phase 4G.3B, trigger 3) — it only ever ticks while
                // the app is actually active.
                SyncCoordinator.shared.handleAppDidEnterBackground()
            } else if newPhase == .active {
                // Transactions logged from the widget, Siri, or a Shortcut write through a
                // separate ModelContext in another process, so entries/sums touching a wallet
                // can look stale in this app's context until it's nudged to re-fetch.
                modelContext.rollback()
                // Automatic sync trigger 1 (Phase 4G.3B) — gated on sync staleness/pending
                // changes, not unconditional; also (re)starts the periodic timer (trigger 3).
                SyncCoordinator.shared.handleAppBecameActive(modelContext: modelContext)
            }
        }
        // Same local nudge when the shared store changes while this app is already in the
        // foreground. The network-sync decision itself is deferred to one of the four real
        // triggers (Phase 4G.3B) — this only marks a pending change, exactly like a same-process
        // `ModelContext.didSave` does below, since a cross-process write is no different from an
        // ordinary local save for sync-scheduling purposes.
        //
        // Phase 4H — `.NSPersistentStoreRemoteChange` is documented to arrive on an arbitrary
        // background queue (unlike `ModelContext.didSave` below, which fires synchronously on the
        // saving thread — always the main thread here, since every save site is `@MainActor`).
        // Without `.receive(on:)`, `modelContext.rollback()` ran on whatever background thread
        // posted the notification, mutating a main-actor-confined `ModelContext` that `@Query`
        // views observe — exactly what produced "Publishing changes from background threads is
        // not allowed." This hops delivery to the main thread first; the `ModelContext` itself
        // still only ever gets touched on the main thread, same as every other call site.
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange).receive(on: DispatchQueue.main)) { _ in
            // Skipped while our own sync pass is running — see `SyncCoordinator.
            // isSyncPassInProgress`'s doc comment for why rolling back here on every one of a
            // pass's six intermediate saves (rather than once, which the pass itself now does at
            // its own end) was invalidating objects a `@Query` view could be mid-computation over.
            // A genuinely different process's write (widget/Shortcuts) still rolls back
            // immediately here, same as always — this flag is only ever true during our own pass.
            if !SyncCoordinator.shared.isSyncPassInProgress {
                modelContext.rollback()
            }
            SyncCoordinator.shared.handleCrossProcessChange()
        }
        // Automatic sync trigger 4 (Phase 4G.3B) — fires after every successful local save,
        // regardless of which mutation call site performed it (`AddTransactionView`,
        // `WalletEditorView`, `PlanView`'s budget editing, the soft-delete sites, etc.). No longer
        // schedules a network sync itself — it only marks that a sync-relevant change happened,
        // via `SyncCoordinator.handleDidSave`'s own filtering (only the five sync-relevant model
        // types; an unrelated save, e.g. `SpendingInsight`/`GoalContribution`, marks nothing).
        //
        // `.receive(on: DispatchQueue.main)` — same reasoning as the identical hop on the
        // `.NSPersistentStoreRemoteChange` listener above: `BackgroundSyncExecutor`'s own saves
        // (an automatic sync pass now runs off the Main Actor so it can't freeze the UI) post this
        // exact notification from a background thread, and `handleDidSave` below touches
        // `modelContext`, a main-actor-confined `ModelContext` `@Query` views observe. Without
        // this hop that was "Publishing changes from background threads is not allowed."
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave).receive(on: DispatchQueue.main)) { notification in
            // TEMPORARY — see SyncDiagnosticLog's doc comment.
            let userInfoKeys = notification.userInfo?.keys.map { "\($0)" } ?? []
            SyncDiagnosticLog.log("RootView received ModelContext.didSave — userInfo keys: \(userInfoKeys)")
            SyncCoordinator.shared.handleDidSave(notification, modelContext: modelContext)
        }
        .onOpenURL { url in
            // Checked by host only (not scheme) — `financetracker`/`financetrackerdev` both
            // route here, and `SupabaseManager.passwordRecoveryRedirectURL`/
            // `emailConfirmationRedirectURL`/`emailChangeRedirectURL` already determine which one
            // a given build registers.
            if url.host == "reset-password" {
                Task { await handlePasswordRecoveryLink(url) }
                return
            }
            if url.host == "email-confirmed" {
                Task { await handleEmailConfirmationLink(url) }
                return
            }
            if url.host == "email-changed" {
                Task { await handleEmailChangeLink(url) }
                return
            }
            guard
                url.scheme == "financetracker",
                url.host == "add-transaction" || url.host == "voice-expense"
            else { return }
            showingAddTransaction = true
        }
        .sheet(isPresented: $showingAddTransaction) {
            AddTransactionView()
        }
        .sheet(isPresented: $showingSetNewPassword) {
            SetNewPasswordView { userID in
                // An existing user who just reset their password — never seeds local defaults,
                // same as any other sign-in (see `establishSignedIn`'s own doc comment).
                Task { await establishSignedIn(userID: userID, seedIfNewAccount: false) }
            }
        }
        .alert(
            "Couldn't Reset Password",
            isPresented: Binding(
                get: { recoveryLinkErrorMessage != nil },
                set: { isPresented in if !isPresented { recoveryLinkErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recoveryLinkErrorMessage ?? "")
        }
        .alert("Email Confirmed", isPresented: $showingEmailConfirmedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your email is confirmed and you're signed in.")
        }
        .alert(
            "Couldn't Confirm Email",
            isPresented: Binding(
                get: { emailConfirmationErrorMessage != nil },
                set: { isPresented in if !isPresented { emailConfirmationErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(emailConfirmationErrorMessage ?? "")
        }
        .alert("Email Updated", isPresented: $showingEmailChangedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your account email has been updated.")
        }
        .alert(
            AppLockService.biometricType == .faceID
                ? "Use Face ID to Unlock Clarity?"
                : "Use Touch ID to Unlock Clarity?",
            isPresented: $showingAppLockSuggestion
        ) {
            Button("Not Now", role: .cancel) {}
            Button("Enable") { showingAppLockSuggestionSetPIN = true }
        } message: {
            Text("Open Clarity faster next time instead of typing your password. You can turn this off anytime in Tools → App Lock.")
        }
        .sheet(isPresented: $showingAppLockSuggestionSetPIN) {
            // App Lock always requires a PIN as its fallback (see `AppLockSettingsView`) — a
            // biometric-only lock was never supported, so accepting this suggestion routes through
            // the same `SetPINView` that screen's own "Require Passcode" toggle does.
            SetPINView {
                lockEnabled = true
            }
        }
        .alert(
            "Couldn't Confirm Email Change",
            isPresented: Binding(
                get: { emailChangeErrorMessage != nil },
                set: { isPresented in if !isPresented { emailChangeErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(emailChangeErrorMessage ?? "")
        }
    }

    /// Exchanges a password-recovery deep link for a session, then shows `SetNewPasswordView` —
    /// or, if the link was already used/expired/tampered with, a friendly error instead of
    /// silently doing nothing. Runs regardless of `authState`, since the common case is a
    /// signed-out user who forgot their password.
    @MainActor
    private func handlePasswordRecoveryLink(_ url: URL) async {
        do {
            try await SupabaseAuthService.shared.completePasswordRecovery(url: url)
            showingSetNewPassword = true
        } catch {
            recoveryLinkErrorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .recoveryLink)
        }
    }

    /// Exchanges a "confirm your signup" deep link for a session, seeds local defaults exactly
    /// like `SignUpView`'s immediate-session path (same idempotent `SeedData` guard, now routed
    /// through the same centralized `establishSignedIn` — this is just that same fresh account
    /// finishing confirmation a moment later instead of right away), then shows an in-app
    /// confirmation rather than leaving the browser tab that opened the link on a bare blank page
    /// as the only feedback.
    @MainActor
    private func handleEmailConfirmationLink(_ url: URL) async {
        do {
            let session = try await SupabaseAuthService.shared.completeEmailConfirmation(url: url)
            await establishSignedIn(userID: session.user.id, seedIfNewAccount: true)
            showingEmailConfirmedAlert = true
        } catch {
            emailConfirmationErrorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .emailConfirmationLink)
        }
    }

    /// Exchanges a "confirm your email change" deep link for a session reflecting the now-updated
    /// email (Phase 6.0.3). Always an existing, already-authenticated user — never a brand-new
    /// signup (that's `handleEmailConfirmationLink`, a deliberately distinct host/handler/alert) —
    /// so this never seeds local defaults. Still routed through `establishSignedIn` for
    /// consistency: the user id never changes on an email change, so the Phase 6.1 ownership
    /// check is always a harmless no-op here, but routing through it keeps "every signed-in
    /// transition goes through one place" actually true rather than carving out an exception.
    @MainActor
    private func handleEmailChangeLink(_ url: URL) async {
        do {
            let session = try await SupabaseAuthService.shared.completeEmailChange(url: url)
            await establishSignedIn(userID: session.user.id, seedIfNewAccount: false)
            showingEmailChangedAlert = true
        } catch {
            emailChangeErrorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .emailChangeLink)
        }
    }

    /// Phase 6.1 — the single place every signed-in transition (launch-time session restore,
    /// ordinary sign-in, fresh sign-up, password-recovery completion, email-confirmation
    /// completion) is routed through, so none of them can bypass the local-store ownership check:
    /// a different authenticated user than whoever the local store currently belongs to must have
    /// the store wiped — via `LocalAccountTransition.establishOwnership` — before anything else
    /// (seeding, sync) touches it. `userID` is `nil` only if resolving it right after a successful
    /// auth call itself unexpectedly failed; in that rare case the ownership check is skipped
    /// rather than risking a wrong decision, and only logged.
    ///
    /// `seedIfNewAccount` is `true` only for the two genuinely-new-account completions (fresh
    /// sign-up, email confirmation) — never for an ordinary sign-in or a password reset, so an
    /// existing user is never seeded just because a wipe left their store momentarily empty (see
    /// `RootAuthState.shouldSeedLocalDefaults`'s doc comment for the original reasoning this
    /// preserves). Seeding always runs after the ownership check, never before — a seed that ran
    /// first would just be erased by a wipe decided afterward.
    @MainActor
    private func establishSignedIn(userID: UUID?, seedIfNewAccount: Bool) async {
        if let userID {
            do {
                try LocalAccountTransition.establishOwnership(
                    userID: userID,
                    modelContext: modelContext,
                    ownerStore: localStoreOwnerStore,
                    syncCoordinator: .shared
                )
            } catch {
                SyncDiagnosticLog.log("establishSignedIn — failed to establish local store ownership: \(error)")
            }
        } else {
            SyncDiagnosticLog.log("establishSignedIn — couldn't resolve the authenticated user id; skipping the local-store ownership check")
        }

        if seedIfNewAccount {
            do {
                try SeedData.seedIfNeeded(context: modelContext)
            } catch {
                SyncDiagnosticLog.log("establishSignedIn — SeedData.seedIfNeeded failed to save: \(error)")
            }
        }

        authState = .signedIn
    }

    /// Nudges a user who just typed their password interactively — ordinary sign-in or a sign-up
    /// that lands straight in a session — to turn on the Face ID/Touch ID App Lock that already
    /// exists (`AppLockSettingsView`) but is opt-in and easy to never discover. Deliberately not
    /// called from `establishSignedIn` itself, so a launch-time session restore (the user didn't
    /// just do anything) never triggers it. Shown at most once ever, and only when biometrics are
    /// actually available on the device and the lock isn't already on.
    @MainActor
    private func maybeSuggestAppLock() {
        guard Self.shouldSuggestAppLock(
            hasSeenSuggestion: hasSeenAppLockSuggestion,
            lockEnabled: lockEnabled,
            biometricsAvailable: AppLockService.biometricsAvailable
        ) else { return }
        hasSeenAppLockSuggestion = true
        showingAppLockSuggestion = true
    }

    /// The pure gating rule behind `maybeSuggestAppLock`, pulled out so it's testable without a
    /// live `AppLockService`/`@AppStorage` — see `RootViewTests`.
    nonisolated static func shouldSuggestAppLock(
        hasSeenSuggestion: Bool,
        lockEnabled: Bool,
        biometricsAvailable: Bool
    ) -> Bool {
        !hasSeenSuggestion && !lockEnabled && biometricsAvailable
    }

    @ViewBuilder
    private var content: some View {
        switch authState {
        case .loading:
            RootAuthLoadingView()
        case .signedOut:
            LoginView(
                onSignedIn: { userID in
                    Task {
                        await establishSignedIn(userID: userID, seedIfNewAccount: false)
                        maybeSuggestAppLock()
                    }
                },
                onSignUpCompleted: { userID in
                    Task {
                        await establishSignedIn(userID: userID, seedIfNewAccount: true)
                        maybeSuggestAppLock()
                    }
                }
            )
        case .signedIn:
            MainTabView()
                .environment(\.signOutAction) { authState = .signedOutByUser }
        }
    }
}

/// Shown beneath the launch splash while `RootView` asks Supabase whether a session already
/// exists — deliberately minimal (no logo/copy of its own) since the splash is what's actually
/// visible on top of it for most of that check in the common case.
private struct RootAuthLoadingView: View {
    var body: some View {
        ProgressView()
            .tint(.white)
            .darkScreenBackground()
    }
}

#Preview {
    RootView()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
