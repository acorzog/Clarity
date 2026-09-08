import SwiftUI

/// Single-select picker restricted to a fixed candidate list — used for "who paid" and for
/// settlement counterparties, where the choice must be one of the event's own participants
/// rather than every Person record in the app.
struct SharedPersonPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [Person]
    @Binding var selection: Person?
    var title = "Who Paid"
    /// When set (the collaborative Add Expense flow), labels use the event-scoped "You"
    /// resolution instead of `Person.isCurrentUser` — see `SharedEvent.displayName(for:currentUserRecordID:)`.
    /// Both default to nil so this view's existing behavior is unchanged wherever they aren't supplied.
    var event: SharedEvent?
    var currentUserRecordID: String?

    private func label(for person: Person) -> String {
        event?.displayName(for: person, currentUserRecordID: currentUserRecordID) ?? (person.isCurrentUser ? "You" : person.displayName)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(candidates) { person in
                    Button {
                        selection = person
                        dismiss()
                    } label: {
                        HStack {
                            PersonAvatar(person: person)
                            Text(label(for: person))
                                .foregroundStyle(.white)
                            Spacer()
                            if selection === person {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.emerald)
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
