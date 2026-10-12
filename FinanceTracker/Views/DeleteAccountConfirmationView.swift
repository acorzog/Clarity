import SwiftUI

/// Phase 6.0.5 — collects the caller's current password to confirm permanent account deletion.
/// Deliberately its own password-entry sheet rather than reusing `ReauthenticationView`'s
/// email-OTP flow other sensitive changes share: that nonce has no GoTrue-supported way to be
/// verified independently of a password mutation (see `SupabaseAuthService.deleteAccount`'s doc
/// comment). The password is verified by `AccountView.deleteAccount` via an ordinary
/// `signIn(email:password:)` call — never sent to the delete-account Edge Function itself, whose
/// own request body the Supabase Dashboard would otherwise log in full. This view's only job is
/// collecting it, same as `ReauthenticationView` only collects a code and leaves verification to
/// whichever request attaches it.
struct DeleteAccountConfirmationView: View {
    var onPasswordConfirmed: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var isPasswordVisible = false

    @FocusState private var isPasswordFocused: Bool

    private var canSubmit: Bool {
        !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ClaritySpacing.xxxl) {
                    Spacer(minLength: ClaritySpacing.xl)

                    header

                    passwordField

                    continueButton

                    Spacer(minLength: ClaritySpacing.xxxl)
                }
                .padding(.horizontal, ClaritySpacing.xxl)
            }
            .darkScreenBackground()
            .scrollDismissesKeyboard(.interactively)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.textSecondary)
                }
            }
        }
        .onAppear { isPasswordFocused = true }
    }

    private var header: some View {
        VStack(spacing: ClaritySpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Confirm it's you")
                .font(.pageTitle)
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Enter your password to permanently delete your account.")
                .font(.body)
                .foregroundStyle(.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var passwordField: some View {
        HStack(spacing: ClaritySpacing.sm) {
            Group {
                if isPasswordVisible {
                    TextField("", text: $password, prompt: Text("Current password").foregroundStyle(.textTertiary))
                } else {
                    SecureField("", text: $password, prompt: Text("Current password").foregroundStyle(.textTertiary))
                }
            }
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(.textPrimary)
            .font(.body)
            .focused($isPasswordFocused)
            .submitLabel(.go)
            .onSubmit(submit)
            .accessibilityLabel("Current password")

            Button {
                isPasswordVisible.toggle()
            } label: {
                Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                    .foregroundStyle(.textTertiary)
            }
            .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
        }
        .padding(.horizontal, ClaritySpacing.lg)
        .frame(height: 48)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClarityRadius.medium))
    }

    private var continueButton: some View {
        Button("Delete Account", action: submit)
            .buttonStyle(.clarityDestructive)
            .disabled(!canSubmit)
    }

    // Dismisses immediately on submit, same as `ReauthenticationView.submit` — verification and
    // any resulting error are the caller's responsibility, surfaced after this sheet is gone.
    private func submit() {
        guard canSubmit else { return }
        isPasswordFocused = false
        onPasswordConfirmed(password)
        dismiss()
    }
}

#Preview {
    DeleteAccountConfirmationView()
}
