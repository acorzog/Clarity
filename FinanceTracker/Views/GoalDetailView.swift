import SwiftUI
import SwiftData

/// Reached via `NavigationLink` push from a Goal row (`CLARITY_GOALS_UX_SPEC.md` §7) — a drill-down
/// into one item from a list, matching the app's existing push-vs-sheet rule
/// (`CategoryEntriesDetailView`/`SharedEventDetailView`'s exact precedent).
///
/// Phase 2N-B added progress/remaining/target-date/required-contribution display plus
/// Edit/Archive/Delete. Phase 2N-C1 adds the real Add Money flow and contribution history — see
/// `CLARITY_GOALS_UX_SPEC.md` §12-§17 (revised, Phase 2N-C).
struct GoalDetailView: View {
    let goal: Goal

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditor = false
    @State private var showingDeleteConfirmation = false
    @State private var showingAddMoney = false
    @State private var editingContribution: GoalContribution?
    @State private var pendingDeleteContribution: GoalContribution?

    private var progress: GoalProgress { GoalPresentation.progress(for: goal) }
    private var completed: Bool { GoalCalculator.isCompleted(progress) }
    private var isOver: Bool { GoalPresentation.isOverTarget(progress) }
    private var ringFraction: Double { GoalPresentation.clampedRingFraction(progress.progressFraction) }
    private var color: Color { Color(hex: goal.colorHex) }
    private var pastDue: Bool { GoalPresentation.isPastDue(targetDate: goal.targetDate, isCompleted: completed) }

    private var requirement: GoalContributionRequirement? {
        GoalCalculator.contributionRequirement(remainingAmount: progress.remainingAmount, targetDate: goal.targetDate)
    }
    private var showsRequirement: Bool {
        GoalPresentation.shouldShowContributionRequirement(requirement, isCompleted: completed)
    }

    /// "€600 left" / "€200 over" / "€1,000 reached" — §7/§9. A net-negative `currentAmount`
    /// (withdrawals exceeding deposits) still uses the ordinary "left" phrasing (arithmetically
    /// correct — `remainingAmount` already reflects it) plus an extra honest callout below so the
    /// larger-than-target "left" figure isn't a silent mystery (§9).
    private var remainingText: String {
        if completed {
            return "\(goal.targetAmount.currencyFormatted) reached"
        }
        return isOver ? "\(abs(progress.remainingAmount).currencyFormatted) over" : "\(progress.remainingAmount.currencyFormatted) left"
    }

    private var progressAccessibilityValue: String {
        completed
            ? "Completed. \(goal.targetAmount.currencyFormatted) reached."
            : "\(GoalPresentation.percentageText(progress.progressFraction)) of \(goal.targetAmount.currencyFormatted) goal. \(remainingText)."
    }

    private var contributions: [GoalContribution] { GoalPresentation.sortedContributions(for: goal) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                progressCard
                detailCard
                addMoneyButton
                if let contextWallet = goal.contextWallet {
                    contextAccountRow(contextWallet)
                }
                contributionHistory
            }
            .padding()
        }
        .darkScreenBackground()
        .navigationTitle(goal.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingEditor = true
                    } label: {
                        Label("Edit Goal", systemImage: "pencil")
                    }
                    Button {
                        archive()
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete Goal", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.textPrimary)
                }
                .accessibilityLabel("Goal options")
            }
        }
        .sheet(isPresented: $showingEditor) {
            GoalEditorView(goal: goal)
        }
        .sheet(isPresented: $showingAddMoney) {
            AddGoalMoneyView(goal: goal)
        }
        .sheet(item: $editingContribution) { contribution in
            AddGoalMoneyView(goal: goal, contribution: contribution)
        }
        .alert("Delete Goal?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("This can't be undone. Contribution records for this goal will be deleted — your transactions will not.")
        }
        .alert("Remove this contribution?", isPresented: Binding(get: { pendingDeleteContribution != nil }, set: { if !$0 { pendingDeleteContribution = nil } })) {
            Button("Cancel", role: .cancel) { pendingDeleteContribution = nil }
            Button("Remove", role: .destructive, action: deletePendingContribution)
        } message: {
            Text("The transaction itself won't be deleted.")
        }
    }

    private var progressCard: some View {
        VStack(spacing: 12) {
            ZStack {
                BudgetProgress(progress: ringFraction, isOverBudget: false, lineWidth: 8, diameter: 96, tintColor: color)
                Image(systemName: completed ? "checkmark" : goal.icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(color)
            }
            .accessibilityLabel(goal.name)
            .accessibilityValue(progressAccessibilityValue)

            Text("\(progress.currentAmount.currencyFormatted) of \(goal.targetAmount.currencyFormatted)")
                .font(.subheadline)
                .foregroundStyle(.textSecondary)

            Text(GoalPresentation.percentageText(progress.progressFraction))
                .font(.heroAmount)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(isOver || completed ? Color.success : .textPrimary)

            if progress.currentAmount < 0 {
                Text("Currently \(progress.currentAmount.currencyFormatted)")
                    .font(.caption)
                    .foregroundStyle(.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ClaritySpacing.xxl)
        .surface(.primary, radius: ClarityRadius.extraLarge)
    }

    private var detailCard: some View {
        VStack(spacing: 12) {
            row(label: "Remaining", value: remainingText)

            if let targetDate = goal.targetDate {
                Divider().overlay(Color.surfaceSecondary)
                HStack {
                    Text("Target date").foregroundStyle(.textPrimary)
                    if pastDue {
                        Text("Past due")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.surfaceSecondary, in: Capsule())
                    }
                    Spacer()
                    Text(targetDate.formatted(.dateTime.month(.abbreviated).year()))
                        .foregroundStyle(.textSecondary)
                }
            }

            if showsRequirement, let requirement {
                Divider().overlay(Color.surfaceSecondary)
                HStack(alignment: .firstTextBaseline) {
                    Text("You need").foregroundStyle(.textPrimary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(requirement.requiredMonthly.currencyFormatted)/month")
                            .foregroundStyle(.textSecondary)
                        Text("(\(requirement.requiredWeekly.currencyFormatted)/week)")
                            .font(.caption)
                            .foregroundStyle(.textTertiary)
                    }
                }
            }
        }
        .padding(ClaritySpacing.xl)
        .surface(.primary, radius: ClarityRadius.large, padding: 0)
    }

    private var addMoneyButton: some View {
        Button {
            showingAddMoney = true
        } label: {
            Label("Add Money", systemImage: "plus")
        }
        .buttonStyle(.clarityPrimary)
    }

    @ViewBuilder
    private var contributionHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CONTRIBUTION HISTORY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.textSecondary)

            if contributions.isEmpty {
                Text("No contributions yet. Add one above.")
                    .font(.caption)
                    .foregroundStyle(.textTertiary)
            } else {
                VStack(spacing: 8) {
                    ForEach(contributions) { contribution in
                        SwipeToDeleteRow(canDelete: true, onDelete: { pendingDeleteContribution = contribution }) {
                            Button {
                                editingContribution = contribution
                            } label: {
                                contributionRow(contribution)
                            }
                            .buttonStyle(.plain)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: ClarityRadius.medium))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contributionRow(_ contribution: GoalContribution) -> some View {
        let isWithdrawal = contribution.amount < 0
        // A deposit's sign is implicit in a plain positive Decimal — made explicit here with a
        // leading "+" (matching EntryRow's income convention); a withdrawal's Decimal is already
        // negative, so `.currencyFormatted` already renders its own leading "−".
        let amountText = isWithdrawal ? contribution.amount.currencyFormatted : "+\(contribution.amount.currencyFormatted)"
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(GoalPresentation.contributionContextLabel(contribution))
                    .foregroundStyle(.textPrimary)
                Text(contribution.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.textTertiary)
            }
            Spacer()
            Text(amountText)
                .foregroundStyle(isWithdrawal ? Color.textSecondary : Color.income)
        }
        .padding(ClaritySpacing.lg)
        .surface(.primary, radius: ClarityRadius.medium, padding: 0)
        .accessibilityElement(children: .combine)
    }

    private func contextAccountRow(_ wallet: Wallet) -> some View {
        HStack(spacing: 12) {
            Image(systemName: wallet.icon)
                .foregroundStyle(Color(hex: wallet.colorHex))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(wallet.name).foregroundStyle(.textPrimary)
                Text("Goal lives in this account (display only)")
                    .font(.caption2)
                    .foregroundStyle(.textTertiary)
            }
            Spacer()
        }
        .padding(ClaritySpacing.lg)
        .surface(.primary, radius: ClarityRadius.large, padding: 0)
        .accessibilityElement(children: .combine)
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.textPrimary)
            Spacer()
            Text(value).foregroundStyle(isOver || completed ? Color.success : .textSecondary)
        }
    }

    private func archive() {
        goal.isArchived = true
        dismiss()
    }

    private func delete() {
        modelContext.delete(goal)
        dismiss()
    }

    /// Deletes only the `GoalContribution` row — its linked `Entry`, if any, is untouched, since
    /// `.nullify` (not cascade) governs that direction (`CLARITY_GOALS_MODEL_REPORT.md` §4).
    private func deletePendingContribution() {
        guard let contribution = pendingDeleteContribution else { return }
        modelContext.delete(contribution)
        pendingDeleteContribution = nil
    }
}
