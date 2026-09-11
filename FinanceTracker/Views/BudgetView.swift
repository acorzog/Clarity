import SwiftUI
import SwiftData

private enum BudgetSubTab: String, CaseIterable {
    case plan = "Allocate"
    case remaining = "Remaining"
    case goals = "Goals"
}

/// The top-level **Plan** tab's `NavigationStack` wrapper — per the Phase 2H-B navigation
/// restructure, Plan opens directly into this Allocate/Remaining/Goals workspace instead of a
/// separate launcher screen. Also used standalone for previews.
struct BudgetView: View {
    var body: some View {
        NavigationStack {
            BudgetContentView()
        }
    }
}

/// Plan's actual content — Allocate / Remaining / Goals sub-tabs, plus Budget Insights (the
/// former third sub-tab) now reached via the "Insights" toolbar action, presented as a sheet.
/// Goals is a `ComingSoonView` placeholder; its engine is not built (Phase 2H-B, Task 4).
struct BudgetContentView: View {
    @ObservedObject private var settings = BudgetSettingsStore.shared
    @State private var subTab: BudgetSubTab = .plan
    @State private var selectedMonth = Date.startOfMonth()
    @State private var showingSettings = false
    @State private var showingInsights = false
    @State private var showingNewGoal = false
    @State private var remainingLayout: RemainingLayout = .compact

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: settings.icon.rawValue)
                    .font(.title2)
                    .foregroundStyle(LinearGradient.emeraldSky)
                GradientHeader(title: settings.name)
            }
            .padding(.top, 8)

            MonthSelector(month: $selectedMonth)
                .padding(.horizontal)

            Picker("View", selection: $subTab) {
                ForEach(BudgetSubTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .tint(.emerald)
            .padding(.horizontal)

            ScrollView {
                Group {
                    switch subTab {
                    case .plan:
                        PlanView(month: selectedMonth)
                    case .remaining:
                        RemainingView(month: selectedMonth, layout: remainingLayout)
                    case .goals:
                        GoalsListView()
                    }
                }
                .readableContentWidth()
            }
            // `.interactively` (the previous choice) ties the first scroll gesture to dragging
            // the keyboard down proportionally to the drag distance — with the amount/category
            // fields on this screen keeping the keyboard up often, that made scrolling feel stuck
            // until the keyboard was fully out of the way. `.immediately` dismisses on the first
            // touch instead, so the same gesture scrolls the list right away.
            .scrollDismissesKeyboard(.immediately)
        }
        .darkScreenBackground()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title2)
                        .foregroundStyle(LinearGradient.emeraldSky)
                }
                .accessibilityLabel("Plan settings")
            }
            if subTab == .remaining {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            remainingLayout = remainingLayout.other
                        }
                    } label: {
                        Image(systemName: remainingLayout.other.icon)
                            .font(.title2)
                            .foregroundStyle(LinearGradient.emeraldSky)
                    }
                    .accessibilityLabel(remainingLayout.other == .compact ? "Switch to grid layout" : "Switch to list layout")
                }
            }
            if subTab == .goals {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewGoal = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(LinearGradient.emeraldSky)
                    }
                    .accessibilityLabel("New goal")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingInsights = true
                } label: {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.title2)
                        .foregroundStyle(.textSecondary)
                }
                .accessibilityLabel("Insights")
            }
        }
        .sheet(isPresented: $showingSettings) {
            BudgetSettingsView()
        }
        .sheet(isPresented: $showingInsights) {
            InsightsSheetView(month: selectedMonth)
        }
        .sheet(isPresented: $showingNewGoal) {
            GoalEditorView(goal: nil)
        }
    }
}

/// Smallest possible wrapper to present the existing `InsightsView` (Planned vs. Actual,
/// Spending Pace — unchanged content/calculations) as a sheet from Plan's "Insights" toolbar
/// action, per Phase 2H-B Task 5. `InsightsView` itself has no `NavigationStack`/dismiss affordance
/// of its own since it was previously embedded inline as a segmented sub-tab, not presented modally.
private struct InsightsSheetView: View {
    let month: Date

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                InsightsView(month: month)
            }
            .darkScreenBackground()
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }
}

#Preview {
    BudgetView()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self, Goal.self, GoalContribution.self], inMemory: true)
}
