import SwiftUI
import WidgetKit

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLockEnabled") private var lockEnabled = false
    @State private var isUnlocked = false
    @State private var showingAddTransaction = false

    var body: some View {
        ZStack {
            MainTabView()

            if lockEnabled && !isUnlocked {
                LockScreenView { isUnlocked = true }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isUnlocked)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                isUnlocked = false
                WidgetCenter.shared.reloadAllTimelines()
            }
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
