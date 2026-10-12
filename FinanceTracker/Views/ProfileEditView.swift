import SwiftUI
import PhotosUI
import UIKit

/// Lets a signed-in user set or change their display name and avatar — Phase B (display name) and
/// Phase C (avatar) of the profile roadmap. Unlike `ChangePasswordView`/`ChangeEmailView`, neither
/// is a Supabase "secure change" category, so this never calls `reauthenticate()`/presents
/// `ReauthenticationView` — both are plain, low-risk `profiles` table updates (the avatar upload
/// additionally writes to the `avatars` Storage bucket, gated by its own per-user-folder policies).
struct ProfileEditView: View {
    var onSaved: (String?) -> Void = { _ in }
    var onAvatarChanged: (URL?) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var avatarURL: URL?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isUploadingAvatar = false
    @State private var avatarErrorMessage: String?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    /// Mirrors the `check (char_length(display_name) <= 80)` constraint added on the `profiles`
    /// table — caught locally so a too-long name never round-trips to the server just to fail.
    private static let maxLength = 80

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationMessage: String? {
        guard trimmedName.count > Self.maxLength else { return nil }
        return "Name must be \(Self.maxLength) characters or fewer."
    }

    private var canSave: Bool {
        validationMessage == nil && !isSaving && !isLoading
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ClaritySpacing.xxxl) {
                    Spacer(minLength: ClaritySpacing.xl)

                    header

                    avatarPicker

                    if let avatarErrorMessage {
                        Text(avatarErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.destructive)
                            .transition(.opacity)
                    }

                    VStack(spacing: ClaritySpacing.lg) {
                        nameField

                        if let message = errorMessage ?? validationMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.destructive)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.opacity)
                        }
                    }

                    saveButton

                    Spacer(minLength: ClaritySpacing.xxxl)
                }
                .padding(.horizontal, ClaritySpacing.xxl)
            }
            .darkScreenBackground()
            .scrollDismissesKeyboard(.interactively)
            .animation(.easeOut(duration: 0.15), value: errorMessage)
            .preferredColorScheme(.dark)
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.textSecondary)
                        .disabled(isSaving)
                }
            }
        }
        .task { await loadCurrentProfile() }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task { await uploadAvatar(from: newItem) }
        }
    }

    private var avatarPicker: some View {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            ZStack {
                AvatarCircleView(
                    avatarURL: avatarURL,
                    fallbackInitial: avatarInitial,
                    diameter: 88,
                    isLoading: isUploadingAvatar
                )

                Circle()
                    .fill(Color.appBackground)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "camera.fill")
                            .font(.caption)
                            .foregroundStyle(LinearGradient.emeraldSky)
                    }
                    .offset(x: 30, y: 30)
            }
        }
        .buttonStyle(.plain)
        .disabled(isUploadingAvatar || isLoading)
    }

    private var avatarInitial: String {
        displayName.first.map { String($0).uppercased() } ?? "?"
    }

    private var header: some View {
        VStack(spacing: ClaritySpacing.md) {
            Image(systemName: "person.text.rectangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Edit profile")
                .font(.pageTitle)
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Choose how your name appears in Clarity")
                .font(.body)
                .foregroundStyle(.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var nameField: some View {
        TextField("", text: $displayName, prompt: Text("Display name").foregroundStyle(.textTertiary))
            .textContentType(.name)
            .autocorrectionDisabled()
            .foregroundStyle(.textPrimary)
            .font(.body)
            .padding(.horizontal, ClaritySpacing.lg)
            .frame(height: 48)
            .background(.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClarityRadius.medium))
            .submitLabel(.done)
            .onSubmit { Task { await save() } }
            .accessibilityLabel("Display name")
            .disabled(isLoading)
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            if isSaving || isLoading {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Text("Save")
            }
        }
        .buttonStyle(.clarityPrimary)
        .disabled(!canSave)
    }

    @MainActor
    private func loadCurrentProfile() async {
        if let profile = try? await SupabaseAuthService.shared.fetchCurrentProfile() {
            displayName = profile.displayName ?? ""
            avatarURL = profile.avatarURL.flatMap(URL.init(string:))
        }
        isLoading = false
    }

    /// Resizes the picked photo to a fixed square thumbnail and re-encodes it as JPEG before
    /// handing it to `SupabaseAuthService.uploadAvatar` — avoids uploading a multi-megabyte
    /// original just to display it in a ~90pt circle everywhere it's shown.
    @MainActor
    private func uploadAvatar(from item: PhotosPickerItem) async {
        isUploadingAvatar = true
        avatarErrorMessage = nil
        defer { isUploadingAvatar = false }

        do {
            guard
                let data = try await item.loadTransferable(type: Data.self),
                let image = UIImage(data: data),
                let resizedData = Self.resizedJPEGData(for: image)
            else {
                avatarErrorMessage = "That photo couldn't be used. Try a different one."
                return
            }

            let newURL = try await SupabaseAuthService.shared.uploadAvatar(resizedData)
            // Pre-populates the cache with the image already in hand (`resizedData`'s decoded
            // form) rather than letting `AvatarCircleView` re-download the file it just uploaded.
            if let resizedImage = UIImage(data: resizedData) {
                AvatarImageCache.shared.store(resizedImage, for: newURL)
            }
            avatarURL = newURL
            onAvatarChanged(newURL)
        } catch {
            avatarErrorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .updateAvatar)
        }
    }

    /// Downscales to fit within `maxDimension` (never upscales a smaller original) and encodes as
    /// JPEG at `compressionQuality` — both chosen for a small, fast-loading avatar rather than
    /// preserving source quality.
    private static func resizedJPEGData(
        for image: UIImage,
        maxDimension: CGFloat = 512,
        compressionQuality: CGFloat = 0.8
    ) -> Data? {
        let originalSize = image.size
        let scale = min(1, maxDimension / max(originalSize.width, originalSize.height))
        let targetSize = CGSize(width: originalSize.width * scale, height: originalSize.height * scale)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        return resizedImage.jpegData(compressionQuality: compressionQuality)
    }

    @MainActor
    private func save() async {
        guard canSave else { return }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        // An empty field clears the name (stored as nil) rather than saving an empty string —
        // `AccountView` already falls back to the email-based header when there's no display name.
        let newName = trimmedName.isEmpty ? nil : trimmedName

        do {
            try await SupabaseAuthService.shared.updateDisplayName(newName)
            onSaved(newName)
            dismiss()
        } catch {
            errorMessage = SupabaseAuthService.userFacingMessage(for: error, flow: .updateProfile)
        }
    }
}

#Preview {
    ProfileEditView()
}
