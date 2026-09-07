import SwiftUI

/// Single-select picker restricted to a fixed candidate list — used for "who paid" and for
/// settlement counterparties, where the choice must be one of the event's own participants
/// rather than every Person record in the app.
struct SharedPersonPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [Person]
    @Binding var selection: Person?
    var title = "Who Paid"

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
                            Text(person.isCurrentUser ? "You" : person.displayName)
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
