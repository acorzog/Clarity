import SwiftUI

/// Requests a password-reset email, presented as a sheet from `LoginView`. The emailed link
/// deep-links back into the app (`RootView.onOpenURL`), which presents `SetNewPasswordView` to
/// finish the flow — this view's job ends at "email sent."
struct ForgotPasswordView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var emailSent = false

    @FocusState private var isEmailFocused: Bool

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespaces)
    }

    private var canSubmit: Bool {
        SupabaseAuthService.isValidEmail(trimmedEmail) && !isLoading
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ClaritySpacing.xxxl) {
                    Spacer(minLength: ClaritySpacing.xl)

                    if emailSent {
                        confirmationHeader
                    } else {
                        header

                        VStack(spacing: ClaritySpacing.lg) {
                            emailField

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.destructive)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .transition(.opacity)
                            }
                        }

                        sendButton
                    }

                    Spacer(minLength: ClaritySpacing.xxxl)
                }
                .padding(.horizontal, ClaritySpacing.xxl)
            }
            .darkScreenBackground()
            .scrollDismissesKeyboard(.interactively)
            .animation(.easeOut(duration: 0.15), value: errorMessage)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(emailSent ? "Close" : "Cancel") { dismiss() }
                        .foregroundStyle(.textSecondary)
                        .disabled(isLoading)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: ClaritySpacing.md) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Reset password")
                .font(.pageTitle)
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Enter your email and we'll send you a reset link")
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

            Text("If an account exists for \(trimmedEmail), a password reset link is on its way.")
                .font(.body)
                .foregroundStyle(.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var emailField: some View {
        TextField("", text: $email, prompt: Text("Email").foregroundStyle(.textTertiary))
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
            .onSubmit { Task { await sendResetEmail() } }
            .accessibilityLabel("Email")
    }

    private var sendButton: some View {
        Button {
            Task { await sendResetEmail() }
        } label: {
            if isLoading {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Text("Send Reset Link")
            }
        }
        .buttonStyle(.clarityPrimary)
        .disabled(!canSubmit)
    }

    @MainActor
    private func sendResetEmail() async {
        guard canSubmit else { return }

        isEmailFocused = false
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            try await SupabaseAuthService.shared.resetPassword(email: trimmedEmail)
            withAnimation { emailSent = true }
        } catch {
            errorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .resetPassword)
        }
    }
}

#Preview {
    ForgotPasswordView()
}
