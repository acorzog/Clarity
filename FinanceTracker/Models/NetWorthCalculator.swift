import Foundation

/// The single "assets minus liabilities" calculation — formalizes `WalletsView.netWorth`'s
/// existing, correct formula (sum of active wallets' balances where `includeInNetWorth == true`)
/// as a reusable, testable function now that Home reads it alongside More → Accounts
/// (`CLARITY_HOME_SPEC.md` §9 / §22 Open Decision 1). Pure — takes an already-fetched `[Wallet]`,
/// returns a plain `Decimal`; no historical/trend component (that remains a documented data gap,
/// see the spec).
enum NetWorthCalculator {
    static func netWorth(wallets: [Wallet]) -> Decimal {
        Wallet.active(in: wallets)
            .filter { $0.includeInNetWorth }
            .reduce(Decimal(0)) { $0 + $1.balance }
    }
}
