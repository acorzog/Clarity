import SwiftUI
import SwiftData

/// Plan → Goals' real content (Phase 2N-B) — replaces the `ComingSoonView` placeholder
/// `BudgetContentView` previously showed. Embedded directly in Plan's existing `ScrollView`
/// (`BudgetView.swift`), not a `List` — matches Allocate/Remaining's own container, and Goal rows
/// use the app's manual `.surface(...)` card pattern rather than native list rows, consistent with
/// `CLARITY_GOALS_UX_SPEC.md` §2/§3.
struct GoalsListView: View {
    @Query private var allGoals: [Goal]

    private var activeGoals: [Goal] { GoalPresentation.activeGoals(from: allGoals) }
    private var completedGoals: [Goal] { GoalPresentation.completedGoals(from: allGoals) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if activeGoals.isEmpty && completedGoals.isEmpty {
                EmptyStateView(
                    icon: "target",
                    title: "No Goals Yet",
                    message: "Tap + above to start saving toward something."
                )
            } else {
                if !activeGoals.isEmpty {
                    section(title: "Active", goals: activeGoals)
                }
                if !completedGoals.isEmpty {
                    section(title: "Completed", goals: completedGoals)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 24)
    }

    private func section(title: String, goals: [Goal]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.textSecondary)
            VStack(spacing: 12) {
                ForEach(goals) { goal in
                    NavigationLink {
                        GoalDetailView(goal: goal)
                    } label: {
                        GoalRow(goal: goal)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// One goal in the Active/Completed list — `CLARITY_GOALS_UX_SPEC.md` §5. Kept private/inline
/// here rather than promoted to a shared component: it's screen-specific composition of existing
/// primitives (`BudgetProgress`, `.surface(...)`), not a new reusable visual pattern.
private struct GoalRow: View {
    let goal: Goal

    private var progress: GoalProgress { GoalPresentation.progress(for: goal) }
    private var completed: Bool { GoalCalculator.isCompleted(progress) }
    private var isOver: Bool { GoalPresentation.isOverTarget(progress) }
    private var ringFraction: Double { GoalPresentation.clampedRingFraction(progress.progressFraction) }
    private var color: Color { Color(hex: goal.colorHex) }

    /// "€400 of €1,000 · €600 left" / "· €200 over" / "€1,000 reached" — §5.
    private var subtitle: String {
        if completed {
            return "\(goal.targetAmount.currencyFormatted) reached"
        }
        let comparison = isOver
            ? "\(abs(progress.remainingAmount).currencyFormatted) over"
            : "\(progress.remainingAmount.currencyFormatted) left"
        return "\(progress.currentAmount.currencyFormatted) of \(goal.targetAmount.currencyFormatted) · \(comparison)"
    }

    private var accessibilityValue: String {
        completed ? "Completed. \(goal.targetAmount.currencyFormatted) reached." : "\(GoalPresentation.percentageText(progress.progressFraction)) of \(goal.targetAmount.currencyFormatted) goal. \(subtitle)."
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                BudgetProgress(progress: ringFraction, isOverBudget: false, tintColor: color)
                Image(systemName: goal.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(color)
            }
            .overlay(alignment: .bottomTrailing) {
                if completed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.success)
                        .background(Circle().fill(Color.appBackground))
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(goal.name)
                    .foregroundStyle(.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isOver || completed ? Color.success : .textSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.textTertiary)
        }
        .padding(12)
        .surface(.primary, radius: ClarityRadius.large)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(goal.name)
        .accessibilityValue(accessibilityValue)
    }
}
