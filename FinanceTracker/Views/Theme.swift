import SwiftUI
import UIKit

extension Color {
    static let appBackground = Color(red: 0.039, green: 0.039, blue: 0.047)
    static let emerald = Color(red: 0.063, green: 0.725, blue: 0.506)
    static let skyBlue = Color(red: 0.055, green: 0.647, blue: 0.914)
    /// Semantic color for expenses/overspending, used alongside the brand palette.
    static let expenseRed = Color(red: 0.937, green: 0.267, blue: 0.267)
}

extension LinearGradient {
    static let emeraldSky = LinearGradient(
        colors: [.emerald, .skyBlue],
        startPoint: .leading,
        endPoint: .trailing
    )
}

extension Color {
    /// Builds a color from a "#RRGGBB" hex string, as stored on HeadCategory/Category/Wallet.
    init(hex: String) {
        var hexValue: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)).scanHexInt64(&hexValue)

        self.init(
            red: Double((hexValue & 0xFF0000) >> 16) / 255,
            green: Double((hexValue & 0x00FF00) >> 8) / 255,
            blue: Double(hexValue & 0x0000FF) / 255
        )
    }

    /// The reverse of `init(hex:)`, for round-tripping a `ColorPicker` selection back into
    /// storage as "#RRGGBB".
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(
            format: "#%02X%02X%02X",
            Int((r * 255).rounded()),
            Int((g * 255).rounded()),
            Int((b * 255).rounded())
        )
    }
}

/// Reusable gradient header for a screen's top section.
struct GradientHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.largeTitle.bold())
            .foregroundStyle(LinearGradient.emeraldSky)
    }
}

private struct DarkScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appBackground.ignoresSafeArea())
            .foregroundStyle(.white)
    }
}

extension View {
    func darkScreenBackground() -> some View {
        modifier(DarkScreenBackground())
    }
}

private struct ReadableContentWidth: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Caps and centers content at a comfortable reading width on wide screens (iPad's sidebar
    /// detail column, iPad landscape) — a no-op on narrow ones (iPhone, iPad Split View) since
    /// 700pt already exceeds their width.
    func readableContentWidth() -> some View {
        modifier(ReadableContentWidth())
    }
}

extension Decimal {
    var doubleValue: Double { (self as NSDecimalNumber).doubleValue }

    var currencyFormatted: String {
        let store = AppPreferencesStore.shared
        let base = Decimal.FormatStyle.Currency.currency(code: store.currency.rawValue)
        return formatted(store.showDoubleDecimals ? base.precision(.fractionLength(2)) : base)
    }

    /// Same as `currencyFormatted` but additionally respects "Round decimals in summaries" —
    /// use this for headline totals (Income/Expenses/Left, Net Worth, wallet-type sums), not
    /// itemized transaction amounts, which should always keep their real precision.
    var currencyFormattedSummary: String {
        let store = AppPreferencesStore.shared
        guard store.roundDecimalsInSummaries else { return currencyFormatted }
        return formatted(.currency(code: store.currency.rawValue).precision(.fractionLength(0)))
    }

    /// Plain numeric string (no currency symbol/grouping) for editing in a `.decimalPad` field,
    /// using the current locale's decimal separator so it matches what typing produces.
    func editableText(locale: Locale = .current) -> String {
        guard self != 0 else { return "" }
        let separator = locale.decimalSeparator ?? "."
        return "\(self)".replacingOccurrences(of: ".", with: separator)
    }

    /// Parses text typed on a `.decimalPad`, which emits the locale's decimal separator
    /// (e.g. "," in many European locales) rather than always ".".
    init?(decimalInput text: String, locale: Locale = .current) {
        self.init(string: text, locale: locale)
    }
}

extension String {
    /// Keeps only digits and the current locale's decimal separator, dropping any characters
    /// typed after a second separator so only the first one survives. When `allowNegative` is
    /// true, a leading "-" is preserved (and any other "-" characters are stripped).
    func sanitizedDecimalInput(locale: Locale = .current, allowNegative: Bool = false) -> String {
        let separator = locale.decimalSeparator ?? "."
        let isNegative = allowNegative && first == "-"
        var seenSeparator = false
        var result = ""
        for character in self {
            if character.isNumber {
                result.append(character)
            } else if String(character) == separator, !seenSeparator {
                seenSeparator = true
                result.append(character)
            }
        }
        return isNegative ? "-" + result : result
    }
}
