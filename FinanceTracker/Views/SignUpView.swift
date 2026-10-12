import SwiftUI

/// Supabase email/password account creation, presented as a sheet from `LoginView`. Styled to
/// match `LoginView`/the Clarity design system rather than introducing a new look for the signed-
/// out flow.
struct SignUpView: View {
    /// Carries the new account's id (when resolvable) so `RootView.establishSignedIn` can run its
    /// Phase 6.1 local-store ownership check and seed local defaults for this genuinely new
    /// account — see `LoginView.onSignUpCompleted`'s doc comment for why this is wired separately
    /// from an ordinary sign-in's `onSignedIn`.
    var onSignedIn: (UUID?) -> Void = { _ in }
    /// Called when the user closes the "check your email" confirmation screen — lets `LoginView`
    /// pre-fill its email field with the address they just signed up with, so they don't have to
    /// retype it once they come back to sign in after confirming.
    var onDismissAfterConfirmationRequired: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isPasswordVisible = false
    @State private var isConfirmPasswordVisible = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var confirmationRequired = false

    @FocusState private var focusedField: Field?

    private enum Field {
        case email, password, confirmPassword
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespaces)
    }

    /// Each check is gated on its own field(s) having content — otherwise, e.g., typing the
    /// first character of an email flashed "Password must be at least 8 characters" before the
    /// user had even reached that field.
    private var validationMessage: String? {
        if !trimmedEmail.isEmpty && !SupabaseAuthService.isValidEmail(trimmedEmail) {
            return "Enter a valid email address."
        }
        if !password.isEmpty && password.count < SupabaseAuthService.minimumPasswordLength {
            return "Password must be at least \(SupabaseAuthService.minimumPasswordLength) characters."
        }
        if !confirmPassword.isEmpty && password != confirmPassword {
            return "Passwords don't match."
        }
        return nil
    }

    private var canSubmit: Bool {
        !trimmedEmail.isEmpty && !password.isEmpty && !confirmPassword.isEmpty
            && validationMessage == nil && !isLoading
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ClaritySpacing.xxxl) {
                    Spacer(minLength: ClaritySpacing.xl)

                    if confirmationRequired {
                        confirmationHeader
                    } else {
                        header

                        VStack(spacing: ClaritySpacing.lg) {
                            emailField
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

                        signUpButton
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
                    Button(confirmationRequired ? "Close" : "Cancel") {
                        if confirmationRequired {
                            onDismissAfterConfirmationRequired(trimmedEmail)
                        }
                        dismiss()
                    }
                    .foregroundStyle(.textSecondary)
                    .disabled(isLoading)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: ClaritySpacing.md) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Create account")
                .font(.pageTitle)
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Sign up to sync your finances")
                .font(.body)
                .foregroundStyle(.textSecondary)
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

            Text("We sent a confirmation link to \(trimmedEmail). Confirm your email, then sign in.")
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
            .focused($focusedField, equals: .email)
            .submitLabel(.next)
            .onSubmit { focusedField = .password }
            .accessibilityLabel("Email")
    }

    private var passwordField: some View {
        HStack(spacing: ClaritySpacing.sm) {
            Group {
                if isPasswordVisible {
                    TextField("", text: $password, prompt: Text("Password").foregroundStyle(.textTertiary))
                } else {
                    SecureField("", text: $password, prompt: Text("Password").foregroundStyle(.textTertiary))
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
            .accessibilityLabel("Password")

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
            .onSubmit { Task { await signUp() } }
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

    private var signUpButton: some View {
        Button {
            Task { await signUp() }
        } label: {
            if isLoading {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Text("Sign Up")
            }
        }
        .buttonStyle(.clarityPrimary)
        .disabled(!canSubmit)
    }

    @MainActor
    private func signUp() async {
        guard canSubmit else { return }

        focusedField = nil
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            let outcome = try await SupabaseAuthService.shared.signUp(
                email: trimmedEmail,
                password: password
            )
            switch outcome {
            case .signedIn:
                // Seeding (and the Phase 6.1 local-store ownership check) now happens in
                // `RootView.establishSignedIn`, the one place every signed-in transition is
                // routed through — not here, so a wipe decided there can never race a seed call
                // made before it ran.
                let userID = try? await SupabaseAuthService.shared.currentUserID()
                onSignedIn(userID)
                dismiss()
            case .confirmationRequired:
                withAnimation { confirmationRequired = true }
            }
        } catch {
            errorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .signUp)
        }
    }
}

#Preview {
    SignUpView()
}
