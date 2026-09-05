import SwiftUI
import SwiftData

struct WalletPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Wallet.name) private var wallets: [Wallet]
    @Binding var selection: Wallet?

    /// Excluded so a transfer can't pick the same wallet as both source and destination.
    var excluding: Wallet?

    private var selectableWallets: [Wallet] {
        wallets.filter { $0 !== excluding && !$0.isArchived }
    }

    var body: some View {
        NavigationStack {
            Group {
                if selectableWallets.isEmpty {
                    EmptyStateView(
                        icon: "wallet.pass",
                        title: "No Wallets",
                        message: "Add a wallet before recording transactions."
                    )
                } else {
                    List {
                        ForEach(selectableWallets) { wallet in
                            Button {
                                selection = wallet
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: wallet.icon)
                                        .foregroundStyle(Color(hex: wallet.colorHex))
                                        .frame(width: 24)
                                    Text(wallet.name)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    if selection === wallet {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.emerald)
                                    }
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.05))
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
