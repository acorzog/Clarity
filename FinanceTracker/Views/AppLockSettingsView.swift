import SwiftUI

struct AppLockSettingsView: View {
    @AppStorage("appLockEnabled") private var lockEnabled = false
    @AppStorage("appLockUseBiometrics") private var useBiometrics = true
    @State private var isPINSet = AppLockService.isPINSet
    @State private var showingSetPIN = false
    @State private var showingChangePIN = false

    var body: some View {
        Form {
            Section {
                Toggle("Require Passcode", isOn: Binding(
                    get: { lockEnabled },
                    set: { newValue in
                        if newValue && !isPINSet {
                            // Must set a PIN before the lock can be turned on.
                            showingSetPIN = true
                        } else {
                            lockEnabled = newValue
                            if !newValue {
                                AppLockService.clearPIN()
                                isPINSet = false
                            }
                        }
                    }
                ))
                .tint(.emerald)
            } footer: {
                Text("Require Face ID or a PIN to open Clarity.")
                    .foregroundStyle(.white.opacity(0.4))
            }
            .listRowBackground(Color.white.opacity(0.05))

            if lockEnabled {
                if AppLockService.biometricsAvailable {
                    Section {
                        Toggle(
                            AppLockService.biometricType == .faceID ? "Use Face ID" : "Use Touch ID",
                            isOn: $useBiometrics
                        )
                        .tint(.emerald)
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                }

                Section {
                    Button {
                        showingChangePIN = true
                    } label: {
                        Text("Change PIN")
                            .foregroundStyle(.white)
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("App Lock")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingSetPIN) {
            SetPINView {
                isPINSet = true
                lockEnabled = true
            }
        }
        .sheet(isPresented: $showingChangePIN) {
            SetPINView {
                isPINSet = true
            }
        }
    }
}
