import SwiftUI

/// Supabase email/password sign-in, styled to match the app's existing auth-adjacent screens
/// (`SetPINView`, `LockScreenView`) and the Clarity design system tokens.
struct LoginView: View {
    /// Carries the signed-in user's id (when resolvable) so `RootView.establishSignedIn` can run
    /// its Phase 6.1 local-store ownership check — never bypassable, since this is the one path
    /// an ordinary sign-in reaches `RootView` through.
    var onSignedIn: (UUID?) -> Void = { _ in }
    /// Separate from `onSignedIn` (rather than reused for both) because `RootView` needs to tell
    /// "an existing user signed in" apart from "a brand-new account finished signing up" — only
    /// the latter should ever seed local defaults.
    var onSignUpCompleted: (UUID?) -> Void = { _ in }

    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingSignUp = false
    @State private var showingForgotPassword = false

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

                VStack(spacing: ClaritySpacing.md) {
                    Button("Forgot password?") {
                        showingForgotPassword = true
                    }
                    .font(.footnote)
                    .foregroundStyle(.textSecondary)

                    Button("Don't have an account? Sign Up") {
                        showingSignUp = true
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LinearGradient.emeraldSky)
                }

                Spacer(minLength: ClaritySpacing.xxxl)
            }
            .padding(.horizontal, ClaritySpacing.xxl)
        }
        .darkScreenBackground()
        .scrollDismissesKeyboard(.interactively)
        .animation(.easeOut(duration: 0.15), value: errorMessage)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSignUp) {
            SignUpView(onSignedIn: onSignUpCompleted) { signedUpEmail in
                email = signedUpEmail
            }
        }
        .sheet(isPresented: $showingForgotPassword) {
            ForgotPasswordView()
        }
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
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(.textPrimary)
            .font(.body)
            .focused($focusedField, equals: .password)
            .submitLabel(.go)
            .onSubmit { Task { await signIn() } }
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
            let userID = try? await SupabaseAuthService.shared.currentUserID()
            onSignedIn(userID)
        } catch {
            errorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .signIn)
        }
    }
}

#Preview {
    LoginView()
}
