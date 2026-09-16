import SwiftUI
import SwiftData
import UIKit

/// Thin `NavigationStack` wrapper for standalone use (previews, and anywhere the app needs a
/// fully self-contained Accounts screen). Where this view is embedded inside another screen's
/// own `NavigationStack` — the More container (`ToolsView`), per the Phase 2B-2.2 navigation
/// restructure — use `WalletsContentView` directly instead, to avoid nesting two
/// `NavigationStack`s (which produces a redundant second navigation bar).
struct WalletsView: View {
    var body: some View {
        NavigationStack {
            WalletsContentView()
        }
    }
}

/// The "Accounts" screen's content — formalizes the former "Wallets" tab's UI under its new
/// product-terminology name (`CLARITY_PRODUCT_ARCHITECTURE.md` §13: "Wallet" → "Account" is a
/// UX-terminology decision only; the underlying `Wallet` SwiftData model, `WalletType`, and this
/// struct's own supporting types are deliberately not renamed).
struct WalletsContentView: View {
    @Query(sort: \Wallet.sortOrder) private var allWallets: [Wallet]

    @State private var showingNewWallet = false
    @State private var editingWallet: Wallet? // TEMP default set below for verification, revert
    @State private var showingTransfer = false
    @State private var showingArchived = false
    @State private var showingManageWallets = false

    private var activeWallets: [Wallet] { allWallets.filter { !$0.isArchived } }
    private var archivedWallets: [Wallet] { allWallets.filter { $0.isArchived } }

    // Delegates to the shared calculation now that Home reads the same figure — see
    // `Models/NetWorthCalculator.swift`. Formula and result are unchanged.
    private var netWorth: Decimal {
        NetWorthCalculator.netWorth(wallets: allWallets)
    }

    private func total(for type: WalletType) -> Decimal? {
        let matching = activeWallets.filter { $0.type == type }
        guard !matching.isEmpty else { return nil }
        return matching.reduce(Decimal(0)) { $0 + $1.balance }
    }

    var body: some View {
        VStack(spacing: 16) {
            GradientHeader(title: "Accounts")
                .padding(.top, 8)

            ScrollView {
                VStack(spacing: 16) {
                    SummaryCardCarousel(
                        netWorth: netWorth,
                        spending: total(for: .spending),
                        savings: total(for: .savings),
                        debt: total(for: .debt)
                    )

                    if activeWallets.isEmpty {
                        EmptyStateView(
                            icon: "wallet.pass",
                            title: "No Wallets",
                            message: "Tap + above to add your first wallet."
                        )
                    } else {
                        ForEach(activeWallets) { wallet in
                            Button {
                                editingWallet = wallet
                            } label: {
                                WalletRow(wallet: wallet)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !archivedWallets.isEmpty {
                        archivedSection
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
        .darkScreenBackground()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingManageWallets = true
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.title2)
                        .foregroundStyle(LinearGradient.emeraldSky)
                }
                .accessibilityLabel("Reorder accounts")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingTransfer = true
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.title2)
                        .foregroundStyle(LinearGradient.emeraldSky)
                }
                .accessibilityLabel("Transfer between accounts")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewWallet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(LinearGradient.emeraldSky)
                }
                .accessibilityLabel("Add account")
            }
        }
        .sheet(isPresented: $showingNewWallet) {
            NavigationStack {
                WalletEditorView(wallet: nil)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $editingWallet) { wallet in
            NavigationStack {
                WalletEditorView(wallet: wallet)
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingTransfer) {
            AddTransactionView(initialType: .transfer)
        }
        .sheet(isPresented: $showingManageWallets) {
            ManageWalletsView()
        }
    }

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Archived")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button {
                    showingArchived.toggle()
                } label: {
                    Image(systemName: showingArchived ? "eye.fill" : "eye.slash")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            if showingArchived {
                ForEach(archivedWallets) { wallet in
                    Button {
                        editingWallet = wallet
                    } label: {
                        WalletRow(wallet: wallet, dimmed: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Swipeable pager of summary totals — Net Worth first, then a sum per wallet type that's
/// actually in use (types with no wallets are skipped rather than showing a stray "0,00 €" page).
private struct SummaryCardCarousel: View {
    let netWorth: Decimal
    let spending: Decimal?
    let savings: Decimal?
    let debt: Decimal?

    private var pages: [(title: String, amount: Decimal)] {
        var result = [("Total Net Worth", netWorth)]
        if let spending { result.append(("Total Spending", spending)) }
        if let savings { result.append(("Total Savings", savings)) }
        if let debt { result.append(("Total Debt", debt)) }
        return result
    }

    var body: some View {
        TabView {
            ForEach(pages, id: \.title) { page in
                SummaryCard(title: page.title, amount: page.amount)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never))
        .frame(height: 190)
        .onAppear {
            UIPageControl.appearance().currentPageIndicatorTintColor = .white
            UIPageControl.appearance().pageIndicatorTintColor = UIColor.white.withAlphaComponent(0.3)
        }
    }
}

private struct SummaryCard: View {
    let title: String
    let amount: Decimal

    var body: some View {
        MetricCard(title: title, value: amount.currencyFormattedSummary)
            .padding(.horizontal, 4)
            .padding(.bottom, 24)
    }
}

private struct WalletRow: View {
    let wallet: Wallet
    var dimmed = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(wallet.name.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(wallet.balance.currencyFormatted)
                    .font(.title3.bold())
                    .foregroundStyle(wallet.balance < 0 ? Color.expenseRed : .white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }

            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(hex: wallet.colorHex))
                Image(systemName: wallet.icon)
                    .foregroundStyle(.white)
                    .font(.title3)
            }
            .frame(width: 52, height: 52)
        }
        .padding(20)
        .opacity(dimmed ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(wallet.name) account")
        .accessibilityValue(wallet.balance.currencyFormatted)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }
}

#Preview {
    WalletsView()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
