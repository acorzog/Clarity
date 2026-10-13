import SwiftUI

/// Phase 6.0.2 — pure validation for the in-app change-password form, extracted from the view so
/// it's unit-testable without SwiftUI (mirrors `LocalStoreOwnership.decide`'s own reasoning).
/// Each check is gated on its own field(s) having content, same as `SignUpView`/
/// `SetNewPasswordView`'s inline validation — an error about one field must never flash while the
/// user is still typing another.
enum ChangePasswordValidation {
    static func validationMessage(currentPassword: String, newPassword: String, confirmPassword: String) -> String? {
        if !newPassword.isEmpty && newPassword.count < SupabaseAuthService.minimumPasswordLength {
            return "Password must be at least \(SupabaseAuthService.minimumPasswordLength) characters."
        }
        if !confirmPassword.isEmpty && newPassword != confirmPassword {
            return "Passwords don't match."
        }
        // Checked locally before ever hitting the network — Supabase's own `samePassword` error
        // code covers the same case server-side (see `userFacingMessage`), but there's no reason
        // to wait for a round trip when the form already has both values.
        if !currentPassword.isEmpty && !newPassword.isEmpty && currentPassword == newPassword {
            return "New password must be different from your current password."
        }
        return nil
    }

    static func canSubmit(currentPassword: String, newPassword: String, confirmPassword: String) -> Bool {
        !currentPassword.isEmpty && !newPassword.isEmpty && !confirmPassword.isEmpty
            && validationMessage(currentPassword: currentPassword, newPassword: newPassword, confirmPassword: confirmPassword) == nil
    }
}

/// Lets an already-signed-in user change their password without going through the forgot-
/// password/recovery flow. "Current password" isn't a field Supabase's own update-user API takes
/// (`UserAttributes` has no old-password parameter) — it's verified here by calling the existing
/// `SupabaseAuthService.signIn(email:password:)` again with it, the standard way to confirm a
/// password client-side against Supabase. If the project has "secure password change" enabled,
/// the subsequent `updatePassword` call throws `reauthenticationNeeded`; this reuses the exact
/// same `ReauthenticationView`/nonce mechanism Phase 6.0.1 built, rather than a second one.
struct ChangePasswordView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isCurrentPasswordVisible = false
    @State private var isNewPasswordVisible = false
    @State private var isConfirmPasswordVisible = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingReauthentication = false
    @State private var showingSuccessAlert = false

    @FocusState private var focusedField: Field?

    private enum Field {
        case currentPassword, newPassword, confirmPassword
    }

    private var validationMessage: String? {
        ChangePasswordValidation.validationMessage(
            currentPassword: currentPassword, newPassword: newPassword, confirmPassword: confirmPassword
        )
    }

    private var canSubmit: Bool {
        ChangePasswordValidation.canSubmit(
            currentPassword: currentPassword, newPassword: newPassword, confirmPassword: confirmPassword
        ) && !isLoading
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ClaritySpacing.xxxl) {
                    Spacer(minLength: ClaritySpacing.xl)

                    header

                    VStack(spacing: ClaritySpacing.lg) {
                        currentPasswordField
                        newPasswordField
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
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.textSecondary)
                        .disabled(isLoading)
                }
            }
        }
        .sheet(isPresented: $showingReauthentication) {
            ReauthenticationView { code in
                Task { await submitUpdate(nonce: code) }
            }
        }
        .alert("Password Updated", isPresented: $showingSuccessAlert) {
            Button("OK") { dismiss() }
        } message: {
            Text("Your password has been changed.")
        }
    }

    private var header: some View {
        VStack(spacing: ClaritySpacing.md) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Change password")
                .font(.pageTitle)
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Enter your current password and choose a new one")
                .font(.body)
                .foregroundStyle(.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var currentPasswordField: some View {
        HStack(spacing: ClaritySpacing.sm) {
            Group {
                if isCurrentPasswordVisible {
                    TextField("", text: $currentPassword, prompt: Text("Current password").foregroundStyle(.textTertiary))
                } else {
                    SecureField("", text: $currentPassword, prompt: Text("Current password").foregroundStyle(.textTertiary))
                }
            }
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(.textPrimary)
            .font(.body)
            .focused($focusedField, equals: .currentPassword)
            .submitLabel(.next)
            .onSubmit { focusedField = .newPassword }
            .accessibilityLabel("Current password")

            Button {
                isCurrentPasswordVisible.toggle()
            } label: {
                Image(systemName: isCurrentPasswordVisible ? "eye.slash.fill" : "eye.fill")
                    .foregroundStyle(.textTertiary)
            }
            .accessibilityLabel(isCurrentPasswordVisible ? "Hide password" : "Show password")
        }
        .padding(.horizontal, ClaritySpacing.lg)
        .frame(height: 48)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClarityRadius.medium))
    }

    private var newPasswordField: some View {
        HStack(spacing: ClaritySpacing.sm) {
            Group {
                if isNewPasswordVisible {
                    TextField("", text: $newPassword, prompt: Text("New password").foregroundStyle(.textTertiary))
                } else {
                    SecureField("", text: $newPassword, prompt: Text("New password").foregroundStyle(.textTertiary))
                }
            }
            .textContentType(.newPassword)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(.textPrimary)
            .font(.body)
            .focused($focusedField, equals: .newPassword)
            .submitLabel(.next)
            .onSubmit { focusedField = .confirmPassword }
            .accessibilityLabel("New password")

            Button {
                isNewPasswordVisible.toggle()
            } label: {
                Image(systemName: isNewPasswordVisible ? "eye.slash.fill" : "eye.fill")
                    .foregroundStyle(.textTertiary)
            }
            .accessibilityLabel(isNewPasswordVisible ? "Hide password" : "Show password")
        }
        .padding(.horizontal, ClaritySpacing.lg)
        .frame(height: 48)
        .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClarityRadius.medium))
    }

    private var confirmPasswordField: some View {
        HStack(spacing: ClaritySpacing.sm) {
            Group {
                if isConfirmPasswordVisible {
                    TextField("", text: $confirmPassword, prompt: Text("Confirm new password").foregroundStyle(.textTertiary))
                } else {
                    SecureField("", text: $confirmPassword, prompt: Text("Confirm new password").foregroundStyle(.textTertiary))
                }
            }
            .textContentType(.newPassword)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(.textPrimary)
            .font(.body)
            .focused($focusedField, equals: .confirmPassword)
            .submitLabel(.go)
            .onSubmit { Task { await submit() } }
            .accessibilityLabel("Confirm new password")

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
            Task { await submit() }
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
    private func submit() async {
        guard canSubmit else { return }

        focusedField = nil
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            guard let email = try await SupabaseAuthService.shared.currentUserEmail() else {
                errorMessage = SupabaseAuthService.userFacingMessage(for: SupabaseAuthError.notAuthenticated, flow: .updatePassword)
                return
            }
            // Confirms the current password is actually correct by re-signing-in with it — there
            // is no dedicated "verify password" endpoint, and this is the standard way to check
            // one client-side against Supabase. Same user, so this never touches Phase 6.1's
            // local-store ownership marker (that only reacts to `RootView.establishSignedIn`,
            // never a bare `signIn` call elsewhere).
            try await SupabaseAuthService.shared.signIn(email: email, password: currentPassword)
            await submitUpdate(nonce: nil)
        } catch {
            errorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .updatePassword)
        }
    }

    @MainActor
    private func submitUpdate(nonce: String?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await SupabaseAuthService.shared.updatePassword(newPassword, nonce: nonce)
            showingSuccessAlert = true
        } catch {
            if SupabaseAuthService.requiresReauthentication(error) {
                showingReauthentication = true
            } else {
                errorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .updatePassword)
            }
        }
    }
}

#Preview {
    ChangePasswordView()
}
