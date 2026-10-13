import SwiftUI

/// Lets an already-signed-in user request a change to their account email. Supabase never applies
/// this immediately — it sends a confirmation link to the new address, and the change only takes
/// effect once that link is opened (`RootView.handleEmailChangeLink`); this view's job ends at
/// "request sent." If the project has "secure email change" enabled, the request throws
/// `reauthenticationNeeded`; this reuses the exact same `ReauthenticationView`/nonce mechanism
/// `ChangePasswordView` already does, rather than a second one.
struct ChangeEmailView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var currentEmail: String?
    @State private var newEmail = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingReauthentication = false
    @State private var changeRequested = false

    @FocusState private var isEmailFocused: Bool

    private var trimmedNewEmail: String {
        newEmail.trimmingCharacters(in: .whitespaces)
    }

    private var canSubmit: Bool {
        SupabaseAuthService.isValidEmail(trimmedNewEmail)
            && trimmedNewEmail.lowercased() != (currentEmail ?? "").lowercased()
            && !isLoading
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ClaritySpacing.xxxl) {
                    Spacer(minLength: ClaritySpacing.xl)

                    if changeRequested {
                        confirmationHeader
                    } else {
                        header

                        VStack(spacing: ClaritySpacing.lg) {
                            newEmailField

                            if let message = errorMessage ?? validationMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.destructive)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .transition(.opacity)
                            }
                        }

                        submitButton
                    }

                    Spacer(minLength: ClaritySpacing.xxxl)
                }
                .padding(.horizontal, ClaritySpacing.xxl)
            }
            .darkScreenBackground()
            .scrollDismissesKeyboard(.interactively)
            .animation(.easeOut(duration: 0.15), value: errorMessage)
            .preferredColorScheme(.dark)
            .navigationTitle("Change Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(changeRequested ? "Close" : "Cancel") { dismiss() }
                        .foregroundStyle(.textSecondary)
                        .disabled(isLoading)
                }
            }
        }
        .task { currentEmail = try? await SupabaseAuthService.shared.currentUserEmail() }
        .sheet(isPresented: $showingReauthentication) {
            ReauthenticationView { code in
                Task { await submitChangeEmail(nonce: code) }
            }
        }
    }

    // Only shown once a new email has actually been entered — otherwise an empty field would
    // flash "enter a valid email" before the user has typed anything.
    private var validationMessage: String? {
        guard !trimmedNewEmail.isEmpty else { return nil }
        if !SupabaseAuthService.isValidEmail(trimmedNewEmail) {
            return "Enter a valid email address."
        }
        if trimmedNewEmail.lowercased() == (currentEmail ?? "").lowercased() {
            return "That's already your current email."
        }
        return nil
    }

    private var header: some View {
        VStack(spacing: ClaritySpacing.md) {
            Image(systemName: "envelope.badge.fill")
                .font(.system(size: 40))
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Change email")
                .font(.pageTitle)
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("We'll send a confirmation link to your new address")
                .font(.body)
                .foregroundStyle(.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var confirmationHeader: some View {
        VStack(spacing: ClaritySpacing.md) {
            Image(systemName: "envelope.badge.fill")
                .font(.system(size: 40))
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Check your email")
                .font(.pageTitle)
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("We sent a confirmation link to \(trimmedNewEmail). Your email won't change until you confirm it.")
                .font(.body)
                .foregroundStyle(.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var newEmailField: some View {
        TextField("", text: $newEmail, prompt: Text("New email").foregroundStyle(.textTertiary))
            .keyboardType(.emailAddress)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(.textPrimary)
            .font(.body)
            .padding(.horizontal, ClaritySpacing.lg)
            .frame(height: 48)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClarityRadius.medium))
            .focused($isEmailFocused)
            .submitLabel(.send)
            .onSubmit { Task { await submit() } }
            .accessibilityLabel("New email")
    }

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            if isLoading {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Text("Send Confirmation Link")
            }
        }
        .buttonStyle(.clarityPrimary)
        .disabled(!canSubmit)
    }

    @MainActor
    private func submit() async {
        guard canSubmit else { return }

        isEmailFocused = false
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            try await SupabaseAuthService.shared.changeEmail(to: trimmedNewEmail)
            withAnimation { changeRequested = true }
        } catch {
            if SupabaseAuthService.requiresReauthentication(error) {
                showingReauthentication = true
            } else {
                errorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .changeEmail)
            }
        }
    }

    @MainActor
    private func submitChangeEmail(nonce: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await SupabaseAuthService.shared.changeEmail(to: trimmedNewEmail, nonce: nonce)
            withAnimation { changeRequested = true }
        } catch {
            errorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .changeEmail)
        }
    }
}

#Preview {
    ChangeEmailView()
}
