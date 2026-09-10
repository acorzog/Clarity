import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Manual cross-device data movement — see `LocalBackupService`'s doc comment for why this
/// exists instead of CloudKit sync. Export writes a JSON snapshot and hands it to `ShareLink`
/// (AirDrop/Files/iCloud Drive — same mechanism `ExportCSVView` already uses); Restore reads one
/// back in and fully replaces the local store.
struct BackupRestoreView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var exportURL: URL?
    @State private var exportErrorMessage: String?
    @State private var showingExportError = false
    @State private var isImporting = false
    @State private var pendingImportData: Data?
    @State private var showingRestoreConfirmation = false
    @State private var restoreErrorMessage: String?
    @State private var showingRestoreError = false
    @State private var didRestore = false

    var body: some View {
        Form {
            Section {
                Button {
                    export()
                } label: {
                    Label("Create Backup", systemImage: "square.and.arrow.up")
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share Backup", systemImage: "square.and.arrow.up.on.square")
                    }
                }
            } header: {
                Text("Export")
            } footer: {
                Text("Creates a full backup of your data as a file you can AirDrop, save to Files, or upload to iCloud Drive — then open and restore on another device.")
            }
            .listRowBackground(Color.white.opacity(0.05))

            Section {
                Button(role: .destructive) {
                    isImporting = true
                } label: {
                    Label("Restore from Backup…", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Restore")
            } footer: {
                Text("Replaces all data currently on this device with the contents of the backup file. This can't be undone.")
            }
            .listRowBackground(Color.white.opacity(0.05))
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            handleImportResult(result)
        }
        .alert("Restore from Backup?", isPresented: $showingRestoreConfirmation, presenting: pendingImportData) { data in
            Button("Cancel", role: .cancel) { pendingImportData = nil }
            Button("Restore", role: .destructive) { restore(from: data) }
        } message: { _ in
            Text("This replaces all data on this device with the backup's contents and can't be undone.")
        }
        .alert("Couldn't Create Backup", isPresented: $showingExportError) {
            Button("OK") {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .alert("Couldn't Restore Backup", isPresented: $showingRestoreError) {
            Button("OK") {}
        } message: {
            Text(restoreErrorMessage ?? "")
        }
        .alert("Backup Restored", isPresented: $didRestore) {
            Button("OK") { dismiss() }
        } message: {
            Text("Your data has been replaced with the backup's contents.")
        }
    }

    private func export() {
        do {
            exportURL = try LocalBackupService.writeToTemporaryFile(context: modelContext)
        } catch {
            exportErrorMessage = error.localizedDescription
            showingExportError = true
        }
    }

    private func handleImportResult(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            restoreErrorMessage = error.localizedDescription
            showingRestoreError = true
        case .success(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                pendingImportData = try Data(contentsOf: url)
                showingRestoreConfirmation = true
            } catch {
                restoreErrorMessage = error.localizedDescription
                showingRestoreError = true
            }
        }
    }

    private func restore(from data: Data) {
        do {
            try LocalBackupService.restore(from: data, context: modelContext)
            pendingImportData = nil
            didRestore = true
        } catch {
            pendingImportData = nil
            restoreErrorMessage = error.localizedDescription
            showingRestoreError = true
        }
    }
}

#Preview {
    NavigationStack {
        BackupRestoreView()
    }
    .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
