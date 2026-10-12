import SwiftUI

/// The last step of in-app password recovery — presented by `RootView` once `onOpenURL` has
/// already exchanged the emailed recovery link for a session via `completePasswordRecovery`.
/// Styled to match `SignUpView`'s password fields.
struct SetNewPasswordView: View {
    /// Carries the authenticated user's id (when resolvable) so `RootView.establishSignedIn` can
    /// run its Phase 6.1 local-store ownership check — this is always an existing user (the
    /// recovery session itself proves that), never seeded.
    var onPasswordUpdated: (UUID?) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isPasswordVisible = false
    @State private var isConfirmPasswordVisible = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    @FocusState private var focusedField: Field?

    private enum Field {
        case password, confirmPassword
    }

    /// Each check is gated on its own field(s) having content, so an error about one field never
    /// flashes while the user is still typing in the other.
    private var validationMessage: String? {
        if !password.isEmpty && password.count < SupabaseAuthService.minimumPasswordLength {
            return "Password must be at least \(SupabaseAuthService.minimumPasswordLength) characters."
        }
        if !confirmPassword.isEmpty && password != confirmPassword {
            return "Passwords don't match."
        }
        return nil
    }

    private var canSubmit: Bool {
        !password.isEmpty && !confirmPassword.isEmpty && validationMessage == nil && !isLoading
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ClaritySpacing.xxxl) {
                    Spacer(minLength: ClaritySpacing.xl)

                    header

                    VStack(spacing: ClaritySpacing.lg) {
                        passwordField
                        confirmPasswordField

                        if let message = errorMessage ?? validationMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.destructive)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.opacity)
                        }
                    }

                    submitButton

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
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.textSecondary)
                        .disabled(isLoading)
                }
            }
        }
        // The recovery session is only good for this one change — backing out mid-flow (rather
        // than completing or cancelling) would otherwise leave it sitting around unused.
        .interactiveDismissDisabled(isLoading)
    }

    private var header: some View {
        VStack(spacing: ClaritySpacing.md) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Set a new password")
                .font(.pageTitle)
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Choose a new password for your account")
                .font(.body)
                .foregroundStyle(.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var passwordField: some View {
        HStack(spacing: ClaritySpacing.sm) {
            Group {
                if isPasswordVisible {
                    TextField("", text: $password, prompt: Text("New password").foregroundStyle(.textTertiary))
                } else {
                    SecureField("", text: $password, prompt: Text("New password").foregroundStyle(.textTertiary))
                }
            }
            .textContentType(.newPassword)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(.textPrimary)
            .font(.body)
            .focused($focusedField, equals: .password)
            .submitLabel(.next)
            .onSubmit { focusedField = .confirmPassword }
            .accessibilityLabel("New password")

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

    private var confirmPasswordField: some View {
        HStack(spacing: ClaritySpacing.sm) {
            Group {
                if isConfirmPasswordVisible {
                    TextField("", text: $confirmPassword, prompt: Text("Confirm password").foregroundStyle(.textTertiary))
                } else {
                    SecureField("", text: $confirmPassword, prompt: Text("Confirm password").foregroundStyle(.textTertiary))
                }
            }
            .textContentType(.newPassword)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(.textPrimary)
            .font(.body)
            .focused($focusedField, equals: .confirmPassword)
            .submitLabel(.go)
            .onSubmit { Task { await updatePassword() } }
            .accessibilityLabel("Confirm password")

            Button {
                isConfirmPasswordVisible.toggle()
            } label: {
                Image(systemName: isConfirmPasswordVisible ? "eye.slash.fill" : "eye.fill")
                    .foregroundStyle(.textTertiary)
            }
            .accessibilityLabel(isConfirmPasswordVisible ? "Hide password" : "Show password")
        }
        .padding(.horizontal, ClaritySpacing.lg)
        .frame(height: 48)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClarityRadius.medium))
    }

    private var submitButton: some View {
        Button {
            Task { await updatePassword() }
        } label: {
            if isLoading {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Text("Update Password")
            }
        }
        .buttonStyle(.clarityPrimary)
        .disabled(!canSubmit)
    }

    @MainActor
    private func updatePassword() async {
        guard canSubmit else { return }

        focusedField = nil
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            try await SupabaseAuthService.shared.updatePassword(password)
            let userID = try? await SupabaseAuthService.shared.currentUserID()
            onPasswordUpdated(userID)
            dismiss()
        } catch {
            errorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .updatePassword)
        }
    }
}

#Preview {
    SetNewPasswordView()
}
