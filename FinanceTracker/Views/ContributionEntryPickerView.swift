import SwiftUI
import SwiftData

/// Lists `Entry`s eligible to back a new `GoalContribution` — the secondary "link a transaction"
/// path inside `AddGoalMoneyView` (`CLARITY_GOALS_UX_SPEC.md` §12). Eligibility: `entry.
/// goalContribution == nil` — an `Entry` can back at most one `GoalContribution`, ever
/// (`CLARITY_GOALS_ARCHITECTURE.md` §6, unchanged/still closed). Transfers are not filtered out —
/// any supported `Entry` direction is a valid link (§14).
struct ContributionEntryPickerView: View {
    let onSelect: (Entry) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]

    private var eligibleEntries: [Entry] {
        allEntries.filter { $0.goalContribution == nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                if eligibleEntries.isEmpty {
                    EmptyStateView(
                        icon: "tray",
                        title: "No Transactions",
                        message: "Every transaction is already linked to a goal, or none exist yet."
                    )
                } else {
                    List {
                        ForEach(eligibleEntries) { entry in
                            Button {
                                onSelect(entry)
                                dismiss()
                            } label: {
                                EntryRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.surfacePrimary)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Select Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
