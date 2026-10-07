import SwiftUI

/// Supabase email/password sign-in, styled to match the app's existing auth-adjacent screens
/// (`SetPINView`, `LockScreenView`) and the Clarity design system tokens.
struct LoginView: View {
    var onSignedIn: () -> Void = {}

    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    @FocusState private var focusedField: Field?

    private enum Field {
        case email, password
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !isLoading
    }

    var body: some View {
        ScrollView {
            VStack(spacing: ClaritySpacing.xxxl) {
                Spacer(minLength: ClaritySpacing.xxxl)

                header

                VStack(spacing: ClaritySpacing.lg) {
                    emailField
                    passwordField

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.destructive)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }
                }

                signInButton

                Spacer(minLength: ClaritySpacing.xxxl)
            }
            .padding(.horizontal, ClaritySpacing.xxl)
        }
        .darkScreenBackground()
        .scrollDismissesKeyboard(.interactively)
        .animation(.easeOut(duration: 0.15), value: errorMessage)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: ClaritySpacing.md) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Welcome back")
                .font(.pageTitle)
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Sign in to sync your finances")
                .font(.body)
                .foregroundStyle(.textSecondary)
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
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(.textPrimary)
            .font(.body)
            .focused($focusedField, equals: .password)
            .submitLabel(.go)
            .onSubmit { Task { await signIn() } }

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

    private var signInButton: some View {
        Button {
            Task { await signIn() }
        } label: {
            if isLoading {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Text("Sign In")
            }
        }
        .buttonStyle(.clarityPrimary)
        .disabled(!canSubmit)
    }

    @MainActor
    private func signIn() async {
        guard canSubmit else { return }

        focusedField = nil
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            try await SupabaseAuthService.shared.signIn(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
            )
            onSignedIn()
        } catch {
            errorMessage = "Couldn't sign in. Check your email and password and try again."
        }
    }
}

#Preview {
    LoginView()
}
