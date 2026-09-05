import SwiftUI

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

extension Decimal {
    var doubleValue: Double { (self as NSDecimalNumber).doubleValue }

    var currencyFormatted: String {
        formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }
}
