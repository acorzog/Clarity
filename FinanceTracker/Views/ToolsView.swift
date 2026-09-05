import SwiftUI

private struct ToolItem: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let isAvailable: Bool
}

struct ToolsView: View {
    private let items: [ToolItem] = [
        ToolItem(title: "Categories", icon: "square.grid.2x2.fill", isAvailable: true),
        ToolItem(title: "Export CSV", icon: "square.and.arrow.up.fill", isAvailable: true),
        ToolItem(title: "Widgets", icon: "apps.iphone", isAvailable: true),
        ToolItem(title: "Automations", icon: "wand.and.stars", isAvailable: true),
        ToolItem(title: "App Lock", icon: "lock.fill", isAvailable: true),
        ToolItem(title: "Reminders", icon: "bell.fill", isAvailable: false),
        ToolItem(title: "Bank Connections", icon: "building.columns.fill", isAvailable: false)
    ]

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GradientHeader(title: "Tools")
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
                }
            }
            .darkScreenBackground()
        }
    }

    @ViewBuilder
    private func destination(for item: ToolItem) -> some View {
        switch item.title {
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
        default:
            ComingSoonView(title: item.title, icon: item.icon)
        }
    }
}

private struct ToolCard: View {
    let item: ToolItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: item.icon)
                .font(.title2)
                .foregroundStyle(item.isAvailable ? AnyShapeStyle(LinearGradient.emeraldSky) : AnyShapeStyle(Color.white.opacity(0.3)))

            Spacer(minLength: 20)

            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            Text(item.isAvailable ? " " : "Coming soon")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .frame(height: 120)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }
}

#Preview {
    ToolsView()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
