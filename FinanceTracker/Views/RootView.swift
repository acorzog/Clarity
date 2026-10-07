import SwiftUI
import SwiftData
import CoreData
import WidgetKit
import os

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
    @State private var isUnlocked = false
    @State private var showingAddTransaction = false
    @State private var showingSplash = true
    @State private var authState: RootAuthState = .loading

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
            authState = resolvedState
            // Seeding moved here from `FinanceTrackerApp.init()` (Phase 4A) — see
            // `RootAuthState.shouldSeedLocalDefaults`'s doc comment for why this must only run
            // for a signed-out/local-only user, never unconditionally at launch.
            if resolvedState.shouldSeedLocalDefaults {
                do {
                    try SeedData.seedIfNeeded(context: modelContext)
                } catch {
                    // Logged, not swallowed silently — a failed save here must never be mistaken
                    // for a successful seed. Non-fatal: the empty-store gate will simply try again
                    // on the next launch, exactly as it does today for a genuinely fresh install.
                    SyncDiagnosticLog.log("SeedData.seedIfNeeded failed to save: \(error)")
                }
            }
            // Automatic sync trigger 1 (Phase 4G.3B) — the first authenticated activation, right
            // here at launch (scenePhase's own `.active` case below never fires for the *initial*
            // value, only on later transitions). `.loading`/`.signedOut` never reach here, since
            // `shouldSeedLocalDefaults`'s sibling check below is really "is this a signed-in
            // session" — see `handleAppBecameActive`'s own doc comment for why a stale-or-never
            // last-sync timestamp still lets this one through.
            if resolvedState == .signedIn {
                SyncCoordinator.shared.handleAppBecameActive(modelContext: modelContext)
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
            modelContext.rollback()
            SyncCoordinator.shared.handleCrossProcessChange()
        }
        // Automatic sync trigger 4 (Phase 4G.3B) — fires after every successful local save,
        // regardless of which mutation call site performed it (`AddTransactionView`,
        // `WalletEditorView`, `PlanView`'s budget editing, the soft-delete sites, etc.). No longer
        // schedules a network sync itself — it only marks that a sync-relevant change happened,
        // via `SyncCoordinator.handleDidSave`'s own filtering (only the five sync-relevant model
        // types; an unrelated save, e.g. `SpendingInsight`/`GoalContribution`, marks nothing).
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { notification in
            // TEMPORARY — see SyncDiagnosticLog's doc comment.
            let userInfoKeys = notification.userInfo?.keys.map { "\($0)" } ?? []
            SyncDiagnosticLog.log("RootView received ModelContext.didSave — userInfo keys: \(userInfoKeys)")
            SyncCoordinator.shared.handleDidSave(notification, modelContext: modelContext)
        }
        .onOpenURL { url in
            guard
                url.scheme == "financetracker",
                url.host == "add-transaction" || url.host == "voice-expense"
            else { return }
            showingAddTransaction = true
        }
        .sheet(isPresented: $showingAddTransaction) {
            AddTransactionView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch authState {
        case .loading:
            RootAuthLoadingView()
        case .signedOut:
            LoginView { authState = .signedIn }
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
