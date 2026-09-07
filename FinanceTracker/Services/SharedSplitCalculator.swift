import Foundation

/// Pure split math for shared expenses. Both methods round deterministically to cents and hand
/// any leftover cent(s) to earlier participants, so the returned shares always sum back to
/// exactly the original amount — never off by a cent.
enum SharedSplitCalculator {
    /// Splits `total` evenly among `count` participants (e.g. €100 / 3 → €33.34, €33.33, €33.33).
    static func equalSplit(total: Decimal, count: Int) -> [Decimal] {
        guard count > 0 else { return [] }
        let totalCents = cents(from: total)
        let base = totalCents / count
        let remainder = totalCents % count
        return (0..<count).map { index in
            amount(fromCents: base + (index < remainder ? 1 : 0))
        }
    }

    /// Splits `total` proportionally to each entry in `parts` (e.g. [1, 1, 2, 1] gives one
    /// participant double weight), using the largest-remainder method so rounding never drifts
    /// the total.
    static func partsSplit(total: Decimal, parts: [Int]) -> [Decimal] {
        let totalParts = parts.reduce(0, +)
        guard totalParts > 0 else { return parts.map { _ in 0 } }
        let totalCents = cents(from: total)

        let rawShares = parts.map { Double(totalCents) * Double($0) / Double(totalParts) }
        var floorShares = rawShares.map { Int($0) }
        var remainder = totalCents - floorShares.reduce(0, +)

        let byLargestRemainder = rawShares.indices.sorted {
            (rawShares[$0] - Double(floorShares[$0])) > (rawShares[$1] - Double(floorShares[$1]))
        }

        for index in byLargestRemainder where remainder > 0 {
            floorShares[index] += 1
            remainder -= 1
        }

        return floorShares.map { amount(fromCents: $0) }
    }

    private static let roundingHandler = NSDecimalNumberHandler(
        roundingMode: .plain,
        scale: 0,
        raiseOnExactness: false,
        raiseOnOverflow: false,
        raiseOnUnderflow: false,
        raiseOnDivideByZero: false
    )

    private static func cents(from amount: Decimal) -> Int {
        NSDecimalNumber(decimal: amount * 100)
            .rounding(accordingToBehavior: roundingHandler)
            .intValue
    }

    private static func amount(fromCents cents: Int) -> Decimal {
        Decimal(cents) / 100
    }
}
