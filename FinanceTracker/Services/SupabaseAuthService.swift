import Foundation
import Supabase

@MainActor
final class SupabaseAuthService {

    static let shared = SupabaseAuthService()

    private let client = SupabaseManager.shared.client

    private init() {}

    func signIn(email: String, password: String) async throws {
        try await client.auth.signIn(
            email: email,
            password: password
        )
    }

    func currentUserID() async throws -> UUID? {
        try await client.auth.session.user.id
    }

    func fetchCurrentProfile() async throws -> ProfileDTO {
        guard let userID = try await currentUserID() else {
            throw SupabaseAuthError.notAuthenticated
        }

        return try await client
            .from("profiles")
            .select()
            .eq("id", value: userID.uuidString)
            .single()
            .execute()
            .value
    }

    /// Whether a Supabase session already exists (and is valid, refreshing it if needed) —
    /// used by `RootView` at launch to decide between `LoginView` and `MainTabView` without
    /// forcing a fresh sign-in on every app start. `client.auth.session` throws `AuthError.
    /// sessionMissing` when there's none, which this collapses to `false`.
    func hasActiveSession() async -> Bool {
        (try? await client.auth.session) != nil
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }
}

enum SupabaseAuthError: Error {
    case notAuthenticated
}

struct ProfileDTO: Decodable {
    let id: UUID
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
    }
}