import SwiftUI

private struct ToolItem: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let isAvailable: Bool
}

/// The "More" tab — a container for Shared plus the existing utility screens. Formerly "Tools";
/// Wallets is now back to being a top-level tab (see `MainTab`'s doc comment), and Shared — not
/// yet fully developed — moved here in its place. The Swift type name is left as `ToolsView` —
/// it's an internal identifier, not user-facing — to avoid an unrelated rename.
struct ToolsView: View {
    @Environment(\.modelContext) private var modelContext

    private let items: [ToolItem] = [
        ToolItem(title: "Ask Clarity", icon: "bubble.left.and.bubble.right.fill", isAvailable: true),
        ToolItem(title: "Shared", icon: "person.2.fill", isAvailable: true),
        ToolItem(title: "Categories", icon: "square.grid.2x2.fill", isAvailable: true),
        ToolItem(title: "Export CSV", icon: "square.and.arrow.up.fill", isAvailable: true),
        ToolItem(title: "Widgets", icon: "apps.iphone", isAvailable: true),
        ToolItem(title: "Automations", icon: "wand.and.stars", isAvailable: true),
        ToolItem(title: "App Lock", icon: "lock.fill", isAvailable: true),
        ToolItem(title: "Backup & Restore", icon: "arrow.triangle.2.circlepath", isAvailable: true),
        ToolItem(title: "Reminders", icon: "bell.fill", isAvailable: false),
        ToolItem(title: "Bank Connections", icon: "building.columns.fill", isAvailable: false)
    ]

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GradientHeader(title: "More")
                    .padding(.top, 8)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items) { item in
                            NavigationLink {
                                destination(for: item)
                            } label: {
                                ToolCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                    .readableContentWidth()
                }
                .refreshable { await DataSyncService.refresh(modelContext) }
            }
            .darkScreenBackground()
        }
    }

    @ViewBuilder
    private func destination(for item: ToolItem) -> some View {
        switch item.title {
        case "Ask Clarity":
            AskClarityView()
        case "Shared":
            // `SharedContentView`-style embedding isn't available here — `SharedHomeView` wraps
            // its own `NavigationStack`, so this nests a second navigation bar. Acceptable for
            // now since Shared is a "not yet fully developed" placement in More, not its
            // permanent home.
            SharedHomeView()
        case "Categories":
            CategoriesView()
        case "Export CSV":
            ExportCSVView()
        case "Widgets":
            WidgetsInfoView()
        case "Automations":
            AutomationsHelpView()
        case "App Lock":
            AppLockSettingsView()
        case "Backup & Restore":
            BackupRestoreView()
        default:
            ComingSoonView(title: item.title, icon: item.icon)
        }
    }
}

private struct ToolCard: View {
    let item: ToolItem

    var body: some View {
        SectionCard(padding: ClaritySpacing.lg) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(item.isAvailable ? 0.08 : 0.05))
                    Image(systemName: item.icon)
                        .font(.title2)
                        .foregroundStyle(item.isAvailable ? AnyShapeStyle(LinearGradient.emeraldSky) : AnyShapeStyle(Color.white.opacity(0.3)))
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    if !item.isAvailable {
                        Text("Coming soon")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            // `.leading` centers vertically by default (it's leading + center), so the icon/text
            // block sits centered in the card's height instead of pinned to the top edge.
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        }
    }
}

#Preview {
    ToolsView()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
