import SwiftUI

/// Reusable "confirm it's you" step for sensitive account operations (password/email change,
/// account deletion) — not yet wired to any of those from Phase 6.0.1. Sends a one-time code to
/// the signed-in user's email on appearing (`SupabaseAuthService.reauthenticate()`), then hands
/// the code the user enters back to the caller as a nonce via `onCodeConfirmed`. There's no
/// separate "verify code" step here: Supabase only actually validates that nonce when the caller
/// attaches it (`UserAttributes.nonce`) to whichever sensitive request follows — a wrong or
/// expired code only ever surfaces as an error from that later call, not from this screen.
struct ReauthenticationView: View {
    var onCodeConfirmed: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var isSendingCode = true
    @State private var codeWasSent = false
    @State private var sendErrorMessage: String?

    @FocusState private var isCodeFocused: Bool

    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespaces)
    }

    // Only enabled once a code has actually been sent successfully — not merely attempted —
    // so a failed send can't be worked around by continuing with a code that was never issued.
    private var canSubmit: Bool {
        !trimmedCode.isEmpty && codeWasSent && !isSendingCode
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ClaritySpacing.xxxl) {
                    Spacer(minLength: ClaritySpacing.xl)

                    header

                    VStack(spacing: ClaritySpacing.lg) {
                        codeField

                        if let sendErrorMessage {
                            Text(sendErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.destructive)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.opacity)
                        }
                    }

                    VStack(spacing: ClaritySpacing.md) {
                        continueButton

                        Button("Resend code") {
                            Task { await sendCode() }
                        }
                        .font(.footnote)
                        .foregroundStyle(.textSecondary)
                        .disabled(isSendingCode)
                    }

                    Spacer(minLength: ClaritySpacing.xxxl)
                }
                .padding(.horizontal, ClaritySpacing.xxl)
            }
            .darkScreenBackground()
            .scrollDismissesKeyboard(.interactively)
            .animation(.easeOut(duration: 0.15), value: sendErrorMessage)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.textSecondary)
                }
            }
        }
        .task { await sendCode() }
    }

    private var header: some View {
        VStack(spacing: ClaritySpacing.md) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Confirm it's you")
                .font(.pageTitle)
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Enter the code we sent to your email to continue.")
                .font(.body)
                .foregroundStyle(.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var codeField: some View {
        TextField("", text: $code, prompt: Text("Confirmation code").foregroundStyle(.textTertiary))
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .foregroundStyle(.textPrimary)
            .font(.body)
            .padding(.horizontal, ClaritySpacing.lg)
            .frame(height: 48)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClarityRadius.medium))
            .focused($isCodeFocused)
            .submitLabel(.done)
            .onSubmit(submit)
            .accessibilityLabel("Confirmation code")
    }

    private var continueButton: some View {
        Button(action: submit) {
            if isSendingCode {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Text("Continue")
            }
        }
        .buttonStyle(.clarityPrimary)
        .disabled(!canSubmit)
    }

    private func submit() {
        guard canSubmit else { return }
        isCodeFocused = false
        onCodeConfirmed(trimmedCode)
        dismiss()
    }

    @MainActor
    private func sendCode() async {
        isSendingCode = true
        sendErrorMessage = nil

        defer { isSendingCode = false }

        do {
            try await SupabaseAuthService.shared.reauthenticate()
            codeWasSent = true
        } catch {
            sendErrorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .reauthenticate)
        }
    }
}

#Preview {
    ReauthenticationView()
}
