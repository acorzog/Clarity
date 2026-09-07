import SwiftUI
import SwiftData

/// Multi-select picker for a SharedEvent's participants. People are simple Clarity records
/// (no Contacts integration in V1) — frequently-used people surface first, and new ones can be
/// added inline without leaving the sheet.
struct SharedParticipantsPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allPeople: [Person]

    @Binding var selection: [Person]

    @State private var newName = ""
    @FocusState private var newNameFocused: Bool

    private var people: [Person] {
        allPeople
            .filter { !$0.isCurrentUser }
            .sorted {
                if $0.isFrequent != $1.isFrequent { return $0.isFrequent }
                return $0.displayName < $1.displayName
            }
    }

    private func isSelected(_ person: Person) -> Bool {
        selection.contains { $0 === person }
    }

    private func toggle(_ person: Person) {
        if let index = selection.firstIndex(where: { $0 === person }) {
            selection.remove(at: index)
        } else {
            selection.append(person)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Add a person", text: $newName)
                            .foregroundStyle(.white)
                            .focused($newNameFocused)
                            .onSubmit(addPerson)
                        Button("Add", action: addPerson)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))

                if !people.isEmpty {
                    Section("People") {
                        ForEach(people) { person in
                            Button {
                                toggle(person)
                            } label: {
                                HStack {
                                    PersonAvatar(person: person)
                                    Text(person.displayName)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    if isSelected(person) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.emerald)
                                    }
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.05))
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Participants")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func addPerson() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let person = Person(displayName: trimmed, isFrequent: true)
        modelContext.insert(person)
        selection.append(person)
        newName = ""
        newNameFocused = true
    }
}

/// Small colored initial badge used wherever a Person needs a lightweight visual identity.
struct PersonAvatar: View {
    let person: Person
    var size: CGFloat = 28

    private var color: Color {
        person.colorHex.map { Color(hex: $0) } ?? .skyBlue
    }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.25))
            Text(person.displayName.prefix(1).uppercased())
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    SharedParticipantsPickerView(selection: .constant([]))
        .modelContainer(for: [Person.self, SharedEvent.self], inMemory: true)
}
