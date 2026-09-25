import SwiftUI
import SwiftData

private enum PlanGroupKey: Hashable {
    case income
    case head(PersistentIdentifier)
}

struct PlanView: View {
    let month: Date

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]
    @Query private var allBudgets: [Budget]

    @State private var isPickingNewHeadCategory = false
    @State private var pendingNewHeadCategory: HeadCategory?
    @State private var autoStartAddCategoryFor: PersistentIdentifier?
    @State private var newlyCreatedCategoryID: PersistentIdentifier?
    @State private var collapsedGroups: Set<PlanGroupKey> = []

    private var incomeHeadCategory: HeadCategory? {
        headCategories.first { $0.name == "Income" } ?? headCategories.first { head in
            head.categories.contains { $0.isIncome }
        }
    }

    private var incomeCategories: [Category] {
        (incomeHeadCategory?.categories ?? [])
            .filter { $0.isIncome && !$0.isArchived }
            .sorted { $0.name < $1.name }
    }

    private var visibleIncomeCategories: [Category] {
        incomeCategories.filter { !allBudgets.isHidden(for: $0, month: month) }
    }

    private var hiddenIncomeCategories: [Category] {
        incomeCategories.filter { allBudgets.isHidden(for: $0, month: month) }
    }

    private var expenseHeadCategories: [HeadCategory] {
        headCategories.filter { $0 !== incomeHeadCategory }
    }

    private func expenseCategories(for head: HeadCategory) -> [Category] {
        head.categories.filter { !$0.isIncome && !$0.isArchived }.sorted { $0.name < $1.name }
    }

    private func visibleExpenseCategories(for head: HeadCategory) -> [Category] {
        expenseCategories(for: head).filter { !allBudgets.isHidden(for: $0, month: month) }
    }

    private func hiddenExpenseCategories(for head: HeadCategory) -> [Category] {
        expenseCategories(for: head).filter { allBudgets.isHidden(for: $0, month: month) }
    }

    private func setAmount(_ amount: Decimal, for category: Category) {
        if let existing = allBudgets.budget(for: category, month: month) {
            existing.monthlyLimit = amount
        } else {
            let (m, y) = month.monthYearComponents
            modelContext.insert(Budget(category: category, monthlyLimit: amount, month: m, year: y))
        }
        // Explicit save rather than relying on SwiftData's lazy autosave — see
        // `AddTransactionView.save()`'s identical comment: `RootView` calls `modelContext.
        // rollback()` on every foreground transition and cross-process store change, which
        // silently discards an unsaved insert/mutation. Without this, a Fixed budget set here
        // could vanish (or its carry-forward could silently stop) before the user ever leaves
        // this screen.
        try? modelContext.save()
    }

    /// Marking Fixed when there's no entry yet for `month` locks in whatever amount is currently
    /// shown (this month's own if it exists, otherwise a carried-forward one) as a real row, so
    /// it becomes the anchor later months carry forward from — see `Array<Budget>.amount(for:
    /// month:)`.
    private func setFixed(_ isFixed: Bool, for category: Category) {
        if let existing = allBudgets.budget(for: category, month: month) {
            existing.isFixed = isFixed
        } else {
            let (m, y) = month.monthYearComponents
            modelContext.insert(Budget(
                category: category, monthlyLimit: allBudgets.amount(for: category, month: month),
                month: m, year: y, isFixed: isFixed
            ))
        }
        // See `setAmount`'s comment — same rollback hazard applies here.
        try? modelContext.save()
    }

    private func setHidden(_ hidden: Bool, for category: Category) {
        if let existing = allBudgets.budget(for: category, month: month) {
            existing.isHidden = hidden
        } else if hidden {
            let (m, y) = month.monthYearComponents
            modelContext.insert(Budget(category: category, monthlyLimit: 0, month: m, year: y, isHidden: true))
        }
        // See `setAmount`'s comment — same rollback hazard applies here.
        try? modelContext.save()
    }

    private func addCategory(name: String, to head: HeadCategory, isIncome: Bool) {
        let category = Category(name: name, isIncome: isIncome, headCategory: head)
        modelContext.insert(category)
        newlyCreatedCategoryID = category.persistentModelID
    }

    /// Planning-time totals from the shared calculation layer — see `BudgetCalculator.
    /// plannedBudgetTotals`. Never reads `Entry`; `totalPlannedExpenses`/`leftToBudget` here are
    /// a different concept from Remaining's actual-spending-based "Available to Spend."
    private var plannedTotals: PlannedBudgetTotals {
        BudgetCalculator.plannedBudgetTotals(month: month, budgets: allBudgets, headCategories: headCategories)
    }

    private func expandedBinding(for key: PlanGroupKey) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(key) },
            set: { isExpanded in
                if isExpanded {
                    collapsedGroups.remove(key)
                } else {
                    collapsedGroups.insert(key)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Spacer()
                Button {
                    isPickingNewHeadCategory = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(LinearGradient.emeraldSky)
                }
                .accessibilityLabel("Add category group")
            }

            PlanMetricsRow(totalPlanned: plannedTotals.totalPlannedExpenses, leftToBudget: plannedTotals.leftToBudget)

            CategoryGroupCard(title: "Income", isExpanded: expandedBinding(for: .income)) {
                VStack(spacing: 0) {
                    ForEach(visibleIncomeCategories) { category in
                        PlannedAmountRow(
                            category: category,
                            amount: allBudgets.amount(for: category, month: month),
                            isFixed: allBudgets.isFixed(for: category, month: month),
                            onCommit: { setAmount($0, for: category) },
                            onHide: { setHidden(true, for: category) },
                            onToggleFixed: { setFixed(!allBudgets.isFixed(for: category, month: month), for: category) },
                            autoFocus: category.persistentModelID == newlyCreatedCategoryID,
                            onAutoFocusConsumed: { newlyCreatedCategoryID = nil }
                        )
                        Divider().background(Color.white.opacity(0.08)).padding(.leading, 52)
                    }

                    if let incomeHeadCategory {
                        AddCategoryRow(
                            autoStart: incomeHeadCategory.persistentModelID == autoStartAddCategoryFor,
                            onStarted: { autoStartAddCategoryFor = nil },
                            onCreate: { addCategory(name: $0, to: incomeHeadCategory, isIncome: true) }
                        )
                    }

                    HiddenCategoriesSection(
                        categories: hiddenIncomeCategories,
                        onRestore: { setHidden(false, for: $0) }
                    )
                }
            }

            ForEach(expenseHeadCategories) { head in
                CategoryGroupCard(title: head.name, isExpanded: expandedBinding(for: .head(head.persistentModelID))) {
                    VStack(spacing: 0) {
                        ForEach(visibleExpenseCategories(for: head)) { category in
                            PlannedAmountRow(
                                category: category,
                                amount: allBudgets.amount(for: category, month: month),
                                isFixed: allBudgets.isFixed(for: category, month: month),
                                onCommit: { setAmount($0, for: category) },
                                onHide: { setHidden(true, for: category) },
                                onToggleFixed: { setFixed(!allBudgets.isFixed(for: category, month: month), for: category) },
                                autoFocus: category.persistentModelID == newlyCreatedCategoryID,
                                onAutoFocusConsumed: { newlyCreatedCategoryID = nil }
                            )
                            Divider().background(Color.white.opacity(0.08)).padding(.leading, 52)
                        }

                        AddCategoryRow(
                            autoStart: head.persistentModelID == autoStartAddCategoryFor,
                            onStarted: { autoStartAddCategoryFor = nil },
                            onCreate: { addCategory(name: $0, to: head, isIncome: false) }
                        )

                        HiddenCategoriesSection(
                            categories: hiddenExpenseCategories(for: head),
                            onRestore: { setHidden(false, for: $0) }
                        )
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
        .sheet(isPresented: $isPickingNewHeadCategory) {
            HeadCategoryPickerView(selection: $pendingNewHeadCategory)
        }
        .onChange(of: pendingNewHeadCategory) { _, newValue in
            guard let newValue else { return }
            autoStartAddCategoryFor = newValue.persistentModelID
            pendingNewHeadCategory = nil
        }
    }
}

private struct CategoryGroupCard<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Expanded/collapsed state was previously conveyed only by the chevron's rotation —
            // invisible to VoiceOver. `.accessibilityValue` announces the state; `.combine` reads
            // title + state as one stop instead of two separate, order-ambiguous ones (Phase 2J).
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title) category group")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Double tap to \(isExpanded ? "collapse" : "expand")")

            if isExpanded {
                content
                    .surface(.primary, radius: ClarityRadius.medium, padding: 0)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Lists categories hidden from this month's plan (via the swipe-to-hide row action) behind
/// a collapsed disclosure, with a one-tap way to bring one back into view.
private struct HiddenCategoriesSection: View {
    let categories: [Category]
    let onRestore: (Category) -> Void

    @State private var isExpanded = false

    var body: some View {
        if !categories.isEmpty {
            VStack(spacing: 0) {
                Divider().background(Color.white.opacity(0.08))

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash")
                            .font(.caption)
                        Text("\(categories.count) hidden this month")
                            .font(.caption)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    }
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Double tap to \(isExpanded ? "collapse" : "expand")")

                if isExpanded {
                    ForEach(categories) { category in
                        HStack(spacing: 12) {
                            CategoryIconView(category: category, size: 24)
                                .opacity(0.5)
                            Text(category.name)
                                .foregroundStyle(.white.opacity(0.5))
                            Spacer()
                            Button {
                                onRestore(category)
                            } label: {
                                Image(systemName: "eye")
                                    .foregroundStyle(Color.emerald)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }
}

/// Allocate's top-of-screen summary — Planned Expenses / Available to Allocate. Deliberately
/// borderless (no `.surface()`/card wrapper), mirroring `OverviewSummaryView.SummaryMetricsRow`'s
/// established Tier-1 treatment exactly (Phase 2H-C): two numbers with a self-evident
/// relationship don't need a bounding box. Formerly `PlanSummaryCard` — renamed since it's no
/// longer a card.
private struct PlanMetricsRow: View {
    let totalPlanned: Decimal
    let leftToBudget: Decimal

    private var leftColor: Color { leftToBudget >= 0 ? .emerald : .expenseRed }

    var body: some View {
        HStack {
            FinancialMetric(title: "Planned Expenses", value: totalPlanned.currencyFormatted, color: .textPrimary)
            Spacer()
            FinancialMetric(title: "Available to Allocate", value: leftToBudget.currencyFormatted, color: leftColor, alignment: .trailing)
        }
    }
}

private struct PlannedAmountRow: View {
    let category: Category
    let amount: Decimal
    var isFixed: Bool = false
    let onCommit: (Decimal) -> Void
    var onHide: () -> Void = {}
    /// Swipe-right on this row (see `SwipeToDeleteRow`'s leading action) flips Fixed/Variable
    /// directly — replaces the old tap-into-`CategoryBudgetSettingsView` sheet flow, which added
    /// an extra screen for what's really a one-step toggle.
    var onToggleFixed: () -> Void = {}
    var autoFocus = false
    var onAutoFocusConsumed: () -> Void = {}

    @State private var showingAmountEntry = false

    var body: some View {
        SwipeToDeleteRow(
            canDelete: true,
            onDelete: onHide,
            icon: "eye.slash.fill",
            tint: Color.white.opacity(0.15),
            canLeadingAction: true,
            onLeadingAction: onToggleFixed,
            leadingIcon: isFixed ? "pin.slash.fill" : "pin.fill",
            leadingTint: isFixed ? Color.white.opacity(0.25) : Color.emerald,
            leadingAccessibilityActionName: isFixed ? "Mark Variable" : "Mark Fixed"
        ) {
            rowContent
        }
        .onAppear {
            if autoFocus {
                showingAmountEntry = true
                onAutoFocusConsumed()
            }
        }
        .sheet(isPresented: $showingAmountEntry) {
            AmountEntrySheet(category: category, currentAmount: amount, onSave: onCommit)
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                CategoryIconView(category: category, size: 28)

                Text(category.name)
                    .foregroundStyle(.white)

                // Small at-a-glance marker for a category whose amount carries forward
                // automatically — swipe right on this row to toggle it.
                if isFixed {
                    Image(systemName: "repeat")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(category.name)
            .accessibilityValue(isFixed ? "Fixed" : "Variable")
            .accessibilityHint("Swipe right, or use the rotor, to toggle whether this amount carries over to next month")

            Spacer()

            // A clearly-tappable pill rather than a cramped inline field — see
            // `AmountEntrySheet`, which opens on tap with the value large and legible, and needs
            // an explicit Save before anything changes (no more committing on every keystroke).
            Button {
                showingAmountEntry = true
            } label: {
                Text(amount.currencyFormatted)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(category.name) planned amount")
            .accessibilityValue(amount.currencyFormatted)
            .accessibilityHint("Double tap to change")
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
}

/// Opened by tapping a category's amount pill in Plan → Allocate — a large, legible amount field
/// with an explicit Save action, instead of the small inline field this replaced (which committed
/// silently on every keystroke). Also what a newly-created category auto-opens into, so it's
/// immediately clear where to type its starting amount.
struct AmountEntrySheet: View {
    let category: Category
    let currentAmount: Decimal
    let onSave: (Decimal) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(category: Category, currentAmount: Decimal, onSave: @escaping (Decimal) -> Void) {
        self.category = category
        self.currentAmount = currentAmount
        self.onSave = onSave
        _text = State(initialValue: currentAmount == 0 ? "" : currentAmount.editableText())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                HStack(spacing: 10) {
                    CategoryIconView(category: category, size: 32)
                    Text(category.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                }

                HStack(spacing: 4) {
                    Text(Locale.current.currencySymbol ?? "$")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    TextField("0", text: $text)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .focused($focused)
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 0)
            }
            .padding(.top, 16)
            .padding(.horizontal)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Amount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.6))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onSave(Decimal(decimalInput: text) ?? 0)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.emerald)
                    }
                    .accessibilityLabel("Save amount")
                }
            }
        }
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
        .onAppear { focused = true }
        .onChange(of: text) { _, newValue in
            let filtered = newValue.sanitizedDecimalInput()
            if filtered != newValue { text = filtered }
        }
    }
}

private struct AddCategoryRow: View {
    var autoStart = false
    var onStarted: () -> Void = {}
    let onCreate: (String) -> Void

    @State private var isEditing = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.emerald)
                    TextField("Category name", text: $name)
                        .foregroundStyle(.white)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(commit)
                    Button(action: cancel) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .accessibilityLabel("Cancel")
                    Button(action: commit) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.emerald)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .onAppear { focused = true }
            } else {
                Button {
                    isEditing = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.emerald)
                        Text("Add Category")
                            .foregroundStyle(Color.emerald)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            if autoStart {
                isEditing = true
                onStarted()
            }
        }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        name = ""
        isEditing = false
    }

    private func cancel() {
        focused = false
        name = ""
        isEditing = false
    }
}
