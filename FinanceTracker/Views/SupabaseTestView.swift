import SwiftUI
import SwiftData
import Supabase
import os

struct SupabaseTestView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var email = ""
    @State private var password = ""

    @State private var status = "Not connected"
    @State private var isLoading = false

    @State private var syncStatus = "Not run"
    @State private var isSyncing = false

    @State private var pullStatus = "Not run"
    @State private var isPulling = false

    @State private var entrySyncStatus = "Not run"
    @State private var isSyncingEntries = false

    @State private var combinedSyncStatus = "Not run"
    @State private var isSyncingAll = false

    @State private var diagnosticsOutput = "Not run"

    /// Phase 2C manual-trigger logging only — mirrors `CollaborationLog`'s existing convention
    /// (structural facts only, never financial amounts) rather than introducing a new shared
    /// logging type for what's explicitly a temporary/manual validation surface.
    private static let syncLogger = Logger(subsystem: "com.andreacorzo.FinanceTracker", category: "SupabaseSync")

    var body: some View {
        Form {
            Section("Supabase Test") {
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)

                Button {
                    Task {
                        await testSupabase()
                    }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Sign in")
                    }
                }

                Text(status)
                    .font(.footnote)
            }

            Section("Reference Data Sync") {
                Text("Uploads the current user's HeadCategories, Categories, and Wallets to Supabase. Requires an active session — sign in above first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        await runReferenceDataSync()
                    }
                } label: {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Text("Sync Reference Data")
                    }
                }
                .disabled(isSyncing)

                Text(syncStatus)
                    .font(.footnote)
            }

            Section("Pull Reference Data (temporary — Phase 4B)") {
                Text("Downloads this user's HeadCategories, Categories, and Wallets from Supabase and merges them into the local store (remoteID as the merge key, last-write-wins by updatedAt). Requires an active session — sign in above first. Does not push, and does not touch automatic sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        await runPullReferenceData()
                    }
                } label: {
                    if isPulling {
                        ProgressView()
                    } else {
                        Text("Pull Reference Data")
                    }
                }
                .disabled(isPulling)

                Text(pullStatus)
                    .font(.footnote)
            }

            Section("Entry Sync") {
                Text("Uploads every local Entry (including soft-deleted ones) to Supabase in one batch. Assumes reference data was already synced — run \"Sync Reference Data\" above first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        await runEntrySync()
                    }
                } label: {
                    if isSyncingEntries {
                        ProgressView()
                    } else {
                        Text("Sync Entries")
                    }
                }
                .disabled(isSyncingEntries)

                Text(entrySyncStatus)
                    .font(.footnote)
            }

            Section("Combined Validation") {
                Text("Runs Sync Reference Data, then Sync Entries, in that order. If reference data fails, entries are never attempted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        await runCombinedSync()
                    }
                } label: {
                    if isSyncingAll {
                        ProgressView()
                    } else {
                        Text("Sync All Data")
                    }
                }
                .disabled(isSyncingAll)

                Text(combinedSyncStatus)
                    .font(.footnote)
            }

            Section("Diagnostics (temporary — Phase 3B-4)") {
                Text("Dumps every local Entry (including soft-deleted) to the Xcode console — persistentModelID, remoteID, amount, date, note, type, wallet, isSoftDeleted — and flags groups of entries sharing amount/type/wallet/note (ignoring exact date), which would indicate the same transaction was recorded locally more than once. To be removed once the duplicate/date investigation concludes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Dump Local Entries") {
                    dumpLocalEntries()
                }

                Text("Generates a ready-to-paste Supabase SQL Editor query (printed in full to the Xcode console) that lists every `entries` row whose `id` is NOT among this device's current local Entry remoteIDs — candidate orphan rows from an earlier sync/test. Read-only: SELECT statements only, nothing is executed against Supabase from the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Generate Orphan-Check SQL") {
                    generateOrphanCheckSQL()
                }

                Text("Prints full detail for only the local duplicate groups already identified by \"Dump Local Entries\" (same amount + type + wallet + note, ignoring exact date) — one block per group, every field needed to tell a genuine double-entry apart from two legitimately similar transactions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Print Duplicate Groups Detail") {
                    printDuplicateGroupsDetail()
                }

                Text(diagnosticsOutput)
                    .font(.footnote)
            }
        }
        .navigationTitle("Supabase Test")
    }

    /// TEMPORARY — Phase 3B-4 diagnosis only (section 2 of the investigation: "are the duplicates
    /// already present locally?"). Reads local state only — makes no network call, mutates
    /// nothing. Full per-entry detail goes to the console via `EntrySyncDiagnosticLog`; only
    /// aggregate counts are shown in the UI, since a full dump wouldn't fit legibly in a `Text`.
    @MainActor
    private func dumpLocalEntries() {
        let entries = (try? modelContext.fetch(FetchDescriptor<Entry>())) ?? []
        let nonDeleted = entries.filter { !$0.isSoftDeleted }
        let nilRemoteIDCount = entries.filter { $0.remoteID == nil }.count

        EntrySyncDiagnosticLog.log("=== Local Entry dump: \(entries.count) total, \(nonDeleted.count) non-soft-deleted, \(nilRemoteIDCount) with nil remoteID ===")

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for entry in entries {
            EntrySyncDiagnosticLog.log(
                "local=\(entry.persistentModelID) remoteID=\(entry.remoteID?.uuidString ?? "nil") "
                + "amount=\(entry.amount) date=\(isoFormatter.string(from: entry.date)) note=\"\(entry.note)\" "
                + "type=\(entry.type.rawValue) wallet=\(entry.wallet.name) isSoftDeleted=\(entry.isSoftDeleted) "
                + "createdAt=\(isoFormatter.string(from: entry.createdAt)) updatedAt=\(isoFormatter.string(from: entry.updatedAt))"
            )
        }

        // Groups entries that likely represent the same real-world transaction — same amount,
        // type, wallet, and note — regardless of exact date/remoteID, since the symptom being
        // investigated is "same amount, nearly identical (not exactly identical) dates, different
        // UUIDs."
        struct DuplicateKey: Hashable {
            let amount: Decimal
            let type: EntryType
            let walletID: PersistentIdentifier
            let note: String
        }
        let grouped = Dictionary(grouping: nonDeleted) {
            DuplicateKey(amount: $0.amount, type: $0.type, walletID: $0.wallet.persistentModelID, note: $0.note)
        }
        let suspiciousGroups = grouped.filter { $0.value.count > 1 }

        for (key, group) in suspiciousGroups {
            let dates = group.map { isoFormatter.string(from: $0.date) }.joined(separator: ", ")
            let remoteIDs = group.map { $0.remoteID?.uuidString ?? "nil" }.joined(separator: ", ")
            EntrySyncDiagnosticLog.log(
                "POSSIBLE LOCAL DUPLICATE: amount=\(key.amount) type=\(key.type.rawValue) note=\"\(key.note)\" "
                + "— \(group.count) entries, dates=[\(dates)], remoteIDs=[\(remoteIDs)]"
            )
        }

        diagnosticsOutput = """
        Total local entries: \(entries.count)
        Non-soft-deleted: \(nonDeleted.count)
        Entries with nil remoteID: \(nilRemoteIDCount)
        Possible duplicate groups (same amount/type/wallet/note): \(suspiciousGroups.count)

        Full detail logged to console — filter for "EntrySyncDiagnostics".
        """
    }

    /// TEMPORARY — Phase 3B-5 orphan diagnosis. Reads local state only (no network call, no
    /// Supabase write) and generates read-only SQL for the user to run manually in Supabase's SQL
    /// Editor. Includes soft-deleted entries' remoteIDs in the "current local" set deliberately —
    /// a soft-deleted entry that's already been synced is a legitimate row (`is_deleted = true`),
    /// not an orphan, so excluding it would misclassify it as one.
    @MainActor
    private func generateOrphanCheckSQL() {
        let entries = (try? modelContext.fetch(FetchDescriptor<Entry>())) ?? []
        let localRemoteIDs = Set(entries.compactMap(\.remoteID))
        let nilRemoteIDCount = entries.count - localRemoteIDs.count

        let idList = localRemoteIDs
            .map { "  '\($0.uuidString.lowercased())'" }
            .sorted()
            .joined(separator: ",\n")

        let generatedAt = ISO8601DateFormatter().string(from: .now)
        let sql = """
        -- Phase 3B-5 orphan diagnosis — generated \(generatedAt)
        -- Local Entry rows: \(entries.count); local entries with a non-nil remoteID: \(localRemoteIDs.count); with nil remoteID: \(nilRemoteIDCount)
        -- Read-only: SELECT/count statements only. Does not delete or modify anything.

        -- 1. Total rows currently in Supabase `entries`
        select count(*) as total_supabase_entries from entries;

        -- 2. Rows whose id matches a current local remoteID
        select count(*) as matching_local_ids
        from entries
        where id in (
        \(idList)
        );

        -- 3. Candidate orphan rows — present in Supabase but NOT in the current local remoteID set
        select id, amount, date, wallet_id, category_id, created_at, updated_at, is_deleted
        from entries
        where id not in (
        \(idList)
        )
        order by created_at asc;

        -- 4. Count of candidate orphan rows
        select count(*) as candidate_orphans
        from entries
        where id not in (
        \(idList)
        );
        """

        EntrySyncDiagnosticLog.log("=== Orphan-check SQL generated: \(localRemoteIDs.count) local remoteIDs embedded (from \(entries.count) local Entry rows, \(nilRemoteIDCount) with nil remoteID) ===")
        // Printed directly (not via EntrySyncDiagnosticLog/os.Logger) so the full multi-hundred-line
        // SQL text is never truncated by os_log's message-length limit — plain `print` has none.
        print(sql)

        diagnosticsOutput = """
        Local Entry rows: \(entries.count)
        Local entries with non-nil remoteID: \(localRemoteIDs.count)
        Local entries with nil remoteID: \(nilRemoteIDCount)

        Orphan-check SQL printed in full to the Xcode console — search for "Phase 3B-5 orphan diagnosis", copy from there into Supabase's SQL Editor.
        """
    }

    /// TEMPORARY — Phase 3B-6 diagnosis only. Re-derives exactly the same duplicate groups
    /// `dumpLocalEntries` already flags (same amount + type + wallet + note, ignoring exact date —
    /// no broader/fuzzier matching), then prints full per-entry detail for only those groups, so
    /// each one can be read end-to-end without scrolling through the full 80-entry dump. Read-only:
    /// no network call, no mutation, no deletion.
    @MainActor
    private func printDuplicateGroupsDetail() {
        let entries = (try? modelContext.fetch(FetchDescriptor<Entry>())) ?? []
        let nonDeleted = entries.filter { !$0.isSoftDeleted }

        struct DuplicateKey: Hashable {
            let amount: Decimal
            let type: EntryType
            let walletID: PersistentIdentifier
            let note: String
        }
        let grouped = Dictionary(grouping: nonDeleted) {
            DuplicateKey(amount: $0.amount, type: $0.type, walletID: $0.wallet.persistentModelID, note: $0.note)
        }
        // Sorted for a stable, reproducible print order across runs — grouping order from a
        // Dictionary is otherwise unspecified.
        let suspiciousGroups = grouped
            .filter { $0.value.count > 1 }
            .sorted { lhs, rhs in
                if lhs.key.amount != rhs.key.amount { return lhs.key.amount < rhs.key.amount }
                return lhs.key.note < rhs.key.note
            }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        EntrySyncDiagnosticLog.log("=== Duplicate groups detail: \(suspiciousGroups.count) group(s) ===")

        for (index, element) in suspiciousGroups.enumerated() {
            let (key, group) = element
            let groupNumber = index + 1
            EntrySyncDiagnosticLog.log(
                "--- Group \(groupNumber)/\(suspiciousGroups.count): amount=\(key.amount) type=\(key.type.rawValue) note=\"\(key.note)\" — \(group.count) entries ---"
            )
            for entry in group.sorted(by: { $0.date < $1.date }) {
                EntrySyncDiagnosticLog.log(
                    "  persistentModelID=\(entry.persistentModelID) "
                    + "remoteID=\(entry.remoteID?.uuidString ?? "nil") "
                    + "amount=\(entry.amount) "
                    + "date=\(isoFormatter.string(from: entry.date)) "
                    + "note=\"\(entry.note)\" "
                    + "type=\(entry.type.rawValue) "
                    + "wallet.persistentModelID=\(entry.wallet.persistentModelID) "
                    + "wallet.remoteID=\(entry.wallet.remoteID?.uuidString ?? "nil") "
                    + "category.persistentModelID=\(entry.category.map { String(describing: $0.persistentModelID) } ?? "nil") "
                    + "category.remoteID=\(entry.category?.remoteID?.uuidString ?? "nil") "
                    + "isSoftDeleted=\(entry.isSoftDeleted) "
                    + "createdAt=\(isoFormatter.string(from: entry.createdAt)) "
                    + "updatedAt=\(isoFormatter.string(from: entry.updatedAt))"
                )
            }
        }

        diagnosticsOutput = """
        Duplicate groups: \(suspiciousGroups.count)

        Full per-entry detail for each group logged to console — filter for "EntrySyncDiagnostics".
        """
    }

    @MainActor
    private func testSupabase() async {
        isLoading = true
        status = "Connecting..."

        defer {
            isLoading = false
        }

        do {
            let auth = SupabaseAuthService.shared

            try await auth.signIn(
                email: email,
                password: password
            )

            let userID = try await auth.currentUserID()

            let profile = try await auth.fetchCurrentProfile()

            status = """
            ✅ Connected

            User:
            \(userID?.uuidString ?? "unknown")

            Profile:
            \(profile.id.uuidString)
            """

        } catch {
            status = """
            ❌ Error

            \(error.localizedDescription)
            """
        }
    }

    /// The manual trigger for `SupabaseSyncService.shared.syncReferenceData(modelContext:)` — this
    /// view only invokes that one existing method and maps its `onProgress` callback to a display
    /// string; all remote-ID assignment, dependency ordering, and batching logic stays entirely
    /// inside `SupabaseSyncService`. Requires the session already established via "Sign in" above
    /// — the service itself throws `SupabaseSyncError.notAuthenticated` rather than crashing if
    /// there isn't one, which this surfaces in `syncStatus` like any other error.
    @MainActor
    private func runReferenceDataSync() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            try await SupabaseSyncService.shared.syncReferenceData(modelContext: modelContext) { progress in
                Self.logProgress(progress)
                syncStatus = Self.statusText(for: progress)
            }
        } catch {
            Self.syncLogger.error("Reference data sync failed: \(Self.detailedDescription(for: error), privacy: .public)")
            syncStatus = """
            ❌ Sync failed

            \(Self.detailedDescription(for: error))
            """
        }
    }

    /// The manual trigger for `SupabaseSyncService.shared.pullReferenceData(modelContext:)` —
    /// Phase 4B. `pullReferenceData` itself reports no progress callback (unlike the push methods),
    /// so this reports the local table counts *after* the pull completes rather than a per-table
    /// progress stream — a reasonable proxy for "how much landed," without changing that method's
    /// signature just for this manual test surface. Never touches `SyncCoordinator`/automatic sync.
    @MainActor
    private func runPullReferenceData() async {
        isPulling = true
        defer { isPulling = false }

        do {
            try await SupabaseSyncService.shared.pullReferenceData(modelContext: modelContext)
            let headCategoryCount = (try? modelContext.fetchCount(FetchDescriptor<HeadCategory>())) ?? 0
            let categoryCount = (try? modelContext.fetchCount(FetchDescriptor<Category>())) ?? 0
            let walletCount = (try? modelContext.fetchCount(FetchDescriptor<Wallet>())) ?? 0
            Self.syncLogger.log("Pull reference data completed — local totals: \(headCategoryCount, privacy: .public) head categories, \(categoryCount, privacy: .public) categories, \(walletCount, privacy: .public) wallets")
            pullStatus = """
            ✅ Pull completed

            Local totals after pull:
            \(headCategoryCount) head categories
            \(categoryCount) categories
            \(walletCount) wallets
            """
        } catch {
            Self.syncLogger.error("Pull reference data failed: \(Self.detailedDescription(for: error), privacy: .public)")
            pullStatus = """
            ❌ Pull failed

            \(Self.detailedDescription(for: error))
            """
        }
    }

    /// The manual trigger for `SupabaseSyncService.shared.syncEntries(modelContext:)` — Phase
    /// 3B-3. Assumes reference data was already synced via "Sync Reference Data" above (see
    /// `syncEntries`'s own doc comment); if a wallet/category hasn't been synced yet, the service
    /// throws `EntryDTOMappingError`, surfaced here like any other error via `detailedDescription`.
    @MainActor
    private func runEntrySync() async {
        isSyncingEntries = true
        defer { isSyncingEntries = false }

        do {
            try await SupabaseSyncService.shared.syncEntries(modelContext: modelContext) { progress in
                Self.logProgress(progress)
                entrySyncStatus = Self.statusText(for: progress)
            }
        } catch {
            Self.syncLogger.error("Entry sync failed: \(Self.detailedDescription(for: error), privacy: .public)")
            entrySyncStatus = """
            ❌ Sync failed

            \(Self.detailedDescription(for: error))
            """
        }
    }

    /// Runs `syncReferenceData`, then `syncBudgets`, then `syncEntries`, strictly in sequence —
    /// `syncBudgets` sits between the two (Phase 3C) since a `Budget` references a `Category` by
    /// remote id but nothing downstream depends on `Budget` itself. This is plain sequential
    /// `try await`: if an earlier call throws, the next is never reached and the error is shown
    /// below — no extra orchestration code was added to `SupabaseSyncService` itself for this.
    @MainActor
    private func runCombinedSync() async {
        isSyncingAll = true
        defer { isSyncingAll = false }

        do {
            try await SupabaseSyncService.shared.syncReferenceData(modelContext: modelContext) { progress in
                Self.logProgress(progress)
                combinedSyncStatus = Self.statusText(for: progress)
            }
            try await SupabaseSyncService.shared.syncBudgets(modelContext: modelContext) { progress in
                Self.logProgress(progress)
                combinedSyncStatus = Self.statusText(for: progress)
            }
            try await SupabaseSyncService.shared.syncEntries(modelContext: modelContext) { progress in
                Self.logProgress(progress)
                combinedSyncStatus = Self.statusText(for: progress)
            }
            combinedSyncStatus = "✅ All data synced"
        } catch {
            Self.syncLogger.error("Combined sync failed: \(Self.detailedDescription(for: error), privacy: .public)")
            combinedSyncStatus = """
            ❌ Sync failed

            \(Self.detailedDescription(for: error))
            """
        }
    }

    /// Shared by all three sync actions above — maps a `SupabaseSyncProgress` case to the status
    /// text shown in that action's own `Text(...)` row. One mapping, reused three times, rather
    /// than three copies of the same switch drifting apart.
    private static func statusText(for progress: SupabaseSyncProgress) -> String {
        switch progress {
        case .preparing(let headCategories, let categories, let wallets):
            "Preparing \(headCategories) head categories, \(categories) categories, \(wallets) wallets..."
        case .uploadingHeadCategories(let count):
            "Uploading \(count) head categories..."
        case .uploadingCategories(let count):
            "Uploading \(count) categories..."
        case .uploadingWallets(let count):
            "Uploading \(count) wallets..."
        case .preparingBudgets(let count):
            "Preparing \(count) budgets..."
        case .uploadingBudgets(let count):
            "Uploading \(count) budgets..."
        case .preparingEntries(let count):
            "Preparing \(count) entries..."
        case .uploadingEntries(let count):
            "Uploading \(count) entries..."
        case .completed:
            "Sync completed"
        }
    }

    private static func logProgress(_ progress: SupabaseSyncProgress) {
        switch progress {
        case .preparing(let headCategories, let categories, let wallets):
            syncLogger.log(
                "Preparing — HeadCategories: \(headCategories, privacy: .public), Categories: \(categories, privacy: .public), Wallets: \(wallets, privacy: .public)"
            )
        case .uploadingHeadCategories(let count):
            syncLogger.log("Uploading \(count, privacy: .public) head categories")
        case .uploadingCategories(let count):
            syncLogger.log("Uploading \(count, privacy: .public) categories")
        case .uploadingWallets(let count):
            syncLogger.log("Uploading \(count, privacy: .public) wallets")
        case .preparingBudgets(let count):
            syncLogger.log("Preparing \(count, privacy: .public) budgets")
        case .uploadingBudgets(let count):
            syncLogger.log("Uploading \(count, privacy: .public) budgets")
        case .preparingEntries(let count):
            syncLogger.log("Preparing \(count, privacy: .public) entries")
        case .uploadingEntries(let count):
            syncLogger.log("Uploading \(count, privacy: .public) entries")
        case .completed:
            syncLogger.log("Sync completed")
        }
    }

    /// Surfaces the real Supabase/PostgREST error rather than a generic "something went wrong" —
    /// `PostgrestError.localizedDescription` alone is just its `message`; `code`/`details`/`hint`
    /// are exactly what's needed to tell an RLS rejection apart from a missing-column/schema
    /// mismatch while validating the schema this phase is meant to validate.
    private static func detailedDescription(for error: Error) -> String {
        if let authError = error as? SupabaseSyncError, authError == .notAuthenticated {
            return "Not signed in — use \"Sign in\" above first."
        }
        if let mappingError = error as? EntryDTOMappingError {
            switch mappingError {
            case .missingEntryRemoteID:
                return "Mapping error: an entry has no remoteID yet (unexpected — syncEntries should have assigned one)."
            case .missingWalletRemoteID:
                return "Mapping error: an entry's wallet has no remoteID yet — run \"Sync Reference Data\" first."
            case .missingDestinationWalletRemoteID:
                return "Mapping error: a transfer's destination wallet has no remoteID yet — run \"Sync Reference Data\" first."
            case .missingCategoryRemoteID:
                return "Mapping error: an entry's category has no remoteID yet — run \"Sync Reference Data\" first."
            }
        }
        guard let postgrestError = error as? PostgrestError else {
            return error.localizedDescription
        }
        var parts = [postgrestError.message]
        if let code = postgrestError.code { parts.append("code: \(code)") }
        if let details = postgrestError.details { parts.append("details: \(details)") }
        if let hint = postgrestError.hint { parts.append("hint: \(hint)") }
        return parts.joined(separator: "\n")
    }
}