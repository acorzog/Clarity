import SwiftUI
import SwiftData
import CoreData
import WidgetKit

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @AppStorage("appLockEnabled") private var lockEnabled = false
    @State private var isUnlocked = false
    @State private var showingAddTransaction = false
    @State private var showingSplash = true

    var body: some View {
        ZStack {
            MainTabView()

            if lockEnabled && !isUnlocked {
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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                isUnlocked = false
                WidgetCenter.shared.reloadAllTimelines()
            } else if newPhase == .active {
                // Transactions logged from the widget, Siri, or a Shortcut write through a
                // separate ModelContext in another process, so entries/sums touching a wallet
                // can look stale in this app's context until it's nudged to re-fetch.
                modelContext.rollback()
            }
        }
        // Same nudge when the shared store changes while this app is already in the foreground.
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            modelContext.rollback()
        }
        .onOpenURL { url in
            guard url.scheme == "financetracker", url.host == "add-transaction" else { return }
            showingAddTransaction = true
        }
        .sheet(isPresented: $showingAddTransaction) {
            AddTransactionView()
        }
    }
}

#Preview {
    RootView()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
