import SwiftUI
import SwiftData

/// Root screen of the Shared tab — active and completed SharedEvents. This domain never
/// touches personal Expenses/Income/Wallets/Budgets on its own; only an explicit Settlement
/// "Add to Transactions" confirmation does that (see `SharedEventDetailView`/`RecordPaymentView`).
struct SharedHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SharedEvent.createdAt, order: .reverse) private var allEvents: [SharedEvent]

    @State private var showingNewEvent = false

    private var activeEvents: [SharedEvent] { allEvents.filter { $0.status == .active } }
    private var completedEvents: [SharedEvent] { allEvents.filter { $0.status == .completed } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GradientHeader(title: "Shared")
                    .padding(.top, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if allEvents.isEmpty {
                            EmptyStateView(
                                icon: "person.2",
                                title: "No Shared Events",
                                message: "Tap + above to split a trip, dinner, or any group expense."
                            )
                        } else {
                            if !activeEvents.isEmpty {
                                sectionHeader("Active")
                                ForEach(activeEvents) { event in
                                    NavigationLink {
                                        SharedEventDetailView(event: event)
                                    } label: {
                                        SharedEventRow(event: event)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if !completedEvents.isEmpty {
                                sectionHeader("Completed")
                                ForEach(completedEvents) { event in
                                    NavigationLink {
                                        SharedEventDetailView(event: event)
                                    } label: {
                                        SharedEventRow(event: event)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                    .readableContentWidth()
                }
                .refreshable { await DataSyncService.refresh(modelContext) }
            }
            .darkScreenBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewEvent = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(LinearGradient.emeraldSky)
                    }
                    .accessibilityLabel("New shared event")
                }
            }
        }
        .onAppear {
            _ = Person.currentUser(in: modelContext)
        }
        .sheet(isPresented: $showingNewEvent) {
            NewSharedEventView()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.5))
    }
}

#Preview {
    SharedHomeView()
        .modelContainer(for: [Person.self, SharedEvent.self, SharedExpense.self, SharedExpenseParticipant.self, Settlement.self], inMemory: true)
}
