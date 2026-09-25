import SwiftUI
import SwiftData

/// Drag-to-reorder list for `Wallet.sortOrder` — mirrors `OverviewSettingsView`'s reorder
/// pattern (`.onMove` + a pinned edit mode) rather than introducing a new one.
struct ManageWalletsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Wallet.sortOrder) private var wallets: [Wallet]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(wallets) { wallet in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(hex: wallet.colorHex))
                                Image(systemName: wallet.icon)
                                    .foregroundStyle(.white)
                                    .font(.subheadline)
                            }
                            .frame(width: 36, height: 36)
                            .opacity(wallet.isArchived ? 0.4 : 1)

                            Text(wallet.name)
                                .foregroundStyle(.white.opacity(wallet.isArchived ? 0.4 : 1))

                            if wallet.isArchived {
                                Text("Archived")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.3))
                            }

                            Spacer()
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                    }
                    .onMove(perform: move)
                } header: {
                    Text("Accounts Order")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Manage Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func move(from source: IndexSet, to destination: Int) {
        var reordered = wallets
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, wallet) in reordered.enumerated() {
            wallet.sortOrder = index
        }
    }
}

#Preview {
    ManageWalletsView()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
