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
            try? await Task.sleep(for: .seconds(1.3))
            withAnimation(.easeInOut(duration: 0.4)) {
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
