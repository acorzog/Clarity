import SwiftUI
import SwiftData

/// Creation flow for a SharedEvent — a trip, dinner, or any temporary group-spending activity.
/// Kept fast: name, icon, participants, optional dates.
struct NewSharedEventView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var icon = "airplane"
    @State private var colorHex = "#6366F1"
    @State private var participants: [Person] = []
    @State private var hasStartDate = false
    @State private var startDate = Date.now
    @State private var hasEndDate = false
    @State private var endDate = Date.now

    @State private var showingParticipantsPicker = false
    @State private var hasLoaded = false

    /// Curated subset of the existing icon catalog suited to trips/events — not a new icon library.
    private let iconChoices = [
        "airplane", "fork.knife", "gift.fill", "house.fill", "map.fill",
        "bed.double.fill", "car.fill", "beach.umbrella.fill", "birthday.cake.fill",
        "ticket.fill", "suitcase.fill", "person.3.fill"
    ]

    private let colorChoices = ClarityColorPalette.hexValues

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Barcelona Trip", text: $title)
                        .foregroundStyle(.white)
                }
                .listRowBackground(Color.white.opacity(0.05))

                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(iconChoices, id: \.self) { candidate in
                            Button {
                                icon = candidate
                            } label: {
                                Image(systemName: candidate)
                                    .font(.title3)
                                    .foregroundStyle(icon == candidate ? .black : .white)
                                    .frame(width: 38, height: 38)
                                    .background(
                                        icon == candidate ? Color(hex: colorHex) : Color.white.opacity(0.08),
                                        in: Circle()
                                    )
                            }
                            .buttonStyle(.plain)
                            // Selection was previously conveyed only by a fill-color swap — no
                            // signal at all to VoiceOver (Phase 2J).
                            .accessibilityLabel("Icon \(iconChoices.firstIndex(of: candidate).map { $0 + 1 } ?? 0) of \(iconChoices.count)")
                            .accessibilityAddTraits(icon == candidate ? [.isSelected] : [])
                        }
                    }
                    .padding(.vertical, 4)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(colorChoices, id: \.self) { hex in
                                Button {
                                    colorHex = hex
                                } label: {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 28, height: 28)
                                        .overlay {
                                            if colorHex == hex {
                                                Circle().stroke(Color.white, lineWidth: 2)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Color \(colorChoices.firstIndex(of: hex).map { $0 + 1 } ?? 0) of \(colorChoices.count)")
                                .accessibilityAddTraits(colorHex == hex ? [.isSelected] : [])
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))

                Section("Participants") {
                    Button {
                        showingParticipantsPicker = true
                    } label: {
                        HStack {
                            Text("Participants")
                                .foregroundStyle(.white)
                            Spacer()
                            Text(participantsSummary)
                                .foregroundStyle(.white.opacity(0.6))
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))

                Section {
                    Toggle("Start Date", isOn: $hasStartDate)
                        .tint(.emerald)
                    if hasStartDate {
                        DatePicker("", selection: $startDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .tint(.emerald)
                            .labelsHidden()
                    }
                    Toggle("End Date", isOn: $hasEndDate)
                        .tint(.emerald)
                    if hasEndDate {
                        DatePicker("", selection: $endDate, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .tint(.emerald)
                            .labelsHidden()
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("New Shared Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .disabled(!isValid)
                        .fontWeight(.semibold)
                }
            }
            .onAppear(perform: loadInitialState)
            .sheet(isPresented: $showingParticipantsPicker) {
                SharedParticipantsPickerView(selection: $participants)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var participantsSummary: String {
        let count = participants.count + 1 // "You" is always included
        return count == 1 ? "Just You" : "\(count) people"
    }

    private func loadInitialState() {
        guard !hasLoaded else { return }
        hasLoaded = true
        participants = []
    }

    private func create() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let you = Person.currentUser(in: modelContext)
        let event = SharedEvent(
            title: trimmed,
            icon: icon,
            colorHex: colorHex,
            participants: [you] + participants,
            startDate: hasStartDate ? startDate : nil,
            endDate: hasEndDate ? endDate : nil
        )
        modelContext.insert(event)
        dismiss()
    }
}

#Preview {
    NewSharedEventView()
        .modelContainer(for: [Person.self, SharedEvent.self], inMemory: true)
}
