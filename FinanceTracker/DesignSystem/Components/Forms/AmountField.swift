import SwiftUI

/// The consolidated currency-amount entry field — see `CLARITY_DESIGN_SYSTEM.md` §12 ("Inputs")
/// and §29 ("duplication recommended for consolidation").
///
/// Before this component, the "currency symbol + `TextField` + as-you-type sanitization" pattern
/// existed as two genuinely different shapes with real duplication within each:
/// - **Hero style**: `AddTransactionView.amountField` and `AddSharedExpenseView.amountField`
///   were byte-identical (52pt bold digits, 36pt currency symbol, `.fixedSize()`, focus state).
/// - **Compact style**: `RecordPaymentView`'s and `BudgetSettingsView.MonthlyBudgetGoalView`'s
///   inline Form-row fields were near-identical (default-size digits, smaller currency symbol).
///
/// `WalletEditorView`'s balance field (has a unique +/- sign-toggle affordance), `PlanView.
/// PlannedAmountRow` (tightly coupled to its swipe-to-delete row and per-keystroke `onCommit`),
/// and `SetWalletGoalView` (currency symbol as a *suffix*, not prefix, with a different
/// centered/card layout) were deliberately **not** folded into this component — each has a
/// genuinely different shape, and forcing them in would be exactly the kind of unjustified
/// abstraction `CLARITY_DESIGN_SYSTEM.md` §12 warns against. See the Phase 2A-2 implementation
/// report for the full reasoning.
///
/// Preserves exactly: locale-aware decimal-separator sanitization (`String.
/// sanitizedDecimalInput(allowNegative:)`, unchanged, `Views/Theme.swift`), the existing
/// currency-symbol-via-`Locale.current.currencySymbol` convention, and optional external
/// `FocusState` wiring for the hero style's auto-focus-on-appear behavior.
struct AmountField: View {
    enum Style {
        /// 52pt bold digits, 36pt currency symbol — the amount-entry keypad screens.
        case hero
        /// Default-size digits, `.textSecondary` currency symbol — inline Form-row amount entry.
        case compact
    }

    @Binding var text: String
    var style: Style = .compact
    var placeholder: String = "0"
    var allowNegative: Bool = false
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(Locale.current.currencySymbol ?? "$")
                .font(symbolFont)
                .foregroundStyle(symbolColor)
            textField
        }
        .onChange(of: text) { _, newValue in
            let filtered = newValue.sanitizedDecimalInput(allowNegative: allowNegative)
            if filtered != newValue { text = filtered }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Amount")
    }

    @ViewBuilder
    private var textField: some View {
        let base = TextField(placeholder, text: $text)
            .keyboardType(.decimalPad)
            .font(amountFont)
            .foregroundStyle(.textPrimary)

        switch style {
        case .hero:
            if let focus {
                base.fixedSize().focused(focus)
            } else {
                base.fixedSize()
            }
        case .compact:
            if let focus {
                base.focused(focus)
            } else {
                base
            }
        }
    }

    private var symbolFont: Font {
        style == .hero ? .system(size: 36, weight: .semibold) : .body
    }
    private var symbolColor: Color {
        style == .hero ? .white.opacity(0.5) : .textSecondary
    }
    private var amountFont: Font {
        style == .hero ? .display : .body
    }
}
