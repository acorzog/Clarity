import SwiftUI
import SwiftData

struct PlanView: View {
    let month: Date

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]
    @Query private var allBudgets: [Budget]

    @State private var isPickingNewHeadCategory = false
    @State private var pendingNewHeadCategory: HeadCategory?
    @State private var autoStartAddCategoryFor: PersistentIdentifier?
    @State private var newlyCreatedCategoryID: PersistentIdentifier?

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

    private var expenseHeadCategories: [HeadCategory] {
        headCategories.filter { $0 !== incomeHeadCategory }
    }

    private func expenseCategories(for head: HeadCategory) -> [Category] {
        head.categories.filter { !$0.isIncome && !$0.isArchived }.sorted { $0.name < $1.name }
    }

    private func setAmount(_ amount: Decimal, for category: Category) {
        if let existing = allBudgets.budget(for: category, month: month) {
            existing.monthlyLimit = amount
        } else {
            let (m, y) = month.monthYearComponents
            modelContext.insert(Budget(category: category, monthlyLimit: amount, month: m, year: y))
        }
    }

    private func deleteBudget(for category: Category) {
        guard let existing = allBudgets.budget(for: category, month: month) else { return }
        modelContext.delete(existing)
    }

    private func addCategory(name: String, to head: HeadCategory, isIncome: Bool) {
        let category = Category(name: name, isIncome: isIncome, headCategory: head)
        modelContext.insert(category)
        newlyCreatedCategoryID = category.persistentModelID
    }

    private var totalPlannedIncome: Decimal {
        incomeCategories.reduce(Decimal(0)) { $0 + allBudgets.amount(for: $1, month: month) }
    }

    private var totalPlannedExpenses: Decimal {
        expenseHeadCategories
            .flatMap { expenseCategories(for: $0) }
            .reduce(Decimal(0)) { $0 + allBudgets.amount(for: $1, month: month) }
    }

    private var leftToBudget: Decimal { totalPlannedIncome - totalPlannedExpenses }

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
            }

            PlanSummaryCard(totalPlanned: totalPlannedExpenses, leftToBudget: leftToBudget)

            CategoryGroupCard(title: "Income") {
                VStack(spacing: 0) {
                    ForEach(incomeCategories) { category in
                        PlannedAmountRow(
                            category: category,
                            amount: allBudgets.amount(for: category, month: month),
                            hasBudget: allBudgets.budget(for: category, month: month) != nil,
                            onCommit: { setAmount($0, for: category) },
                            onDelete: { deleteBudget(for: category) },
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
                }
            }

            ForEach(expenseHeadCategories) { head in
                CategoryGroupCard(title: head.name) {
                    VStack(spacing: 0) {
                        ForEach(expenseCategories(for: head)) { category in
                            PlannedAmountRow(
                                category: category,
                                amount: allBudgets.amount(for: category, month: month),
                                hasBudget: allBudgets.budget(for: category, month: month) != nil,
                                onCommit: { setAmount($0, for: category) },
                                onDelete: { deleteBudget(for: category) },
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
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))

            content
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct PlanSummaryCard: View {
    let totalPlanned: Decimal
    let leftToBudget: Decimal

    private var leftColor: Color { leftToBudget >= 0 ? .emerald : .expenseRed }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Planned Expenses")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                Text(totalPlanned.currencyFormatted)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("Left to Budget")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                Text(leftToBudget.currencyFormatted)
                    .font(.title3.bold())
                    .foregroundStyle(leftColor)
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct PlannedAmountRow: View {
    let category: Category
    let amount: Decimal
    var hasBudget = false
    let onCommit: (Decimal) -> Void
    var onDelete: () -> Void = {}
    var autoFocus = false
    var onAutoFocusConsumed: () -> Void = {}

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        SwipeToDeleteRow(canDelete: hasBudget, onDelete: onDelete) {
            rowContent
        }
        .onAppear {
            text = amount == 0 ? "" : "\(amount)"
            if autoFocus {
                focused = true
                onAutoFocusConsumed()
            }
        }
        .onChange(of: amount) { _, newValue in
            guard !focused else { return }
            text = newValue == 0 ? "" : "\(newValue)"
        }
        .onChange(of: text) { _, newValue in
            let filtered = newValue.filter { $0.isNumber || $0 == "." }
            if filtered != newValue {
                text = filtered
                return
            }
            onCommit(Decimal(string: filtered) ?? 0)
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            CategoryIconView(category: category, size: 28)

            Text(category.name)
                .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 2) {
                Text(Locale.current.currencySymbol ?? "$")
                    .foregroundStyle(.white.opacity(0.4))
                TextField("0", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.white)
                    .frame(width: 70)
                    .focused($focused)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
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
}
