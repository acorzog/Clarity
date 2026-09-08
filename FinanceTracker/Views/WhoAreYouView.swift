import SwiftUI
import SwiftData

/// Event-scoped identity selection — "Who are you?" A recipient picks which of THIS event's
/// unclaimed participants they are, associating their CloudKit user identity with that one
/// `EventParticipant`. Never shows participants from any other event, contacts, or unrelated
/// `Person` records (see `SharedEvent.unclaimedParticipants`).
struct WhoAreYouView: View {
    let event: SharedEvent
    let currentUserRecordID: String

    @Environment(\.dismiss) private var dismiss

    @State private var selected: EventParticipant?
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var candidates: [EventParticipant] {
        event.unclaimedParticipants
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    EmptyStateView(
                        icon: "person.crop.circle.badge.questionmark",
                        title: "No One Left to Claim",
                        message: "Every participant in this event is already linked to an iCloud account."
                    )
                } else {
                    List {
                        Section {
                            ForEach(candidates, id: \.persistentModelID) { participant in
                                Button {
                                    selected = participant
                                } label: {
                                    HStack {
                                        if let person = participant.person {
                                            PersonAvatar(person: person)
                                            Text(person.displayName)
                                                .foregroundStyle(.white)
                                        } else {
                                            Text("Unknown participant")
                                                .foregroundStyle(.white.opacity(0.6))
                                        }
                                        Spacer()
                                        if selected === participant {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(Color.emerald)
                                        }
                                    }
                                }
                                .listRowBackground(Color.white.opacity(0.05))
                            }
                        } header: {
                            Text("Which participant are you in this event?")
                        } footer: {
                            Text("This only identifies you in \(event.title). It has no effect on any other Shared Event.")
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Who Are You?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Continue", action: claim)
                            .fontWeight(.semibold)
                            .disabled(selected == nil)
                    }
                }
            }
            .alert(
                "Couldn't Confirm Identity",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { isPresented in if !isPresented { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func claim() {
        guard let selected, let service = CollaborationSyncService.shared else { return }
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            let result = await service.claimParticipant(selected, in: event, as: currentUserRecordID)
            switch result {
            case .claimed:
                dismiss()
            case .alreadyClaimedByAnother:
                errorMessage = "Someone already claimed this participant. Please choose another."
            case .failed(let error):
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't confirm your identity. Please try again."
            }
        }
    }
}
