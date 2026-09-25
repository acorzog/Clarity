import SwiftUI

private struct PlanItem: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let isAvailable: Bool
}

/// A container for Budget, Goals, and Forecast, originally the "Plan" tab's root per the
/// Phase 2B-2.2 navigation restructure (`CLARITY_PRODUCT_ARCHITECTURE.md` §3/§4). Mirrors
/// `ToolsView`'s existing grid-of-destinations pattern for visual/structural consistency with the
/// other container tab (More).
///
/// **Phase 2H-B revision:** no longer wired into `MainTabView` — Plan now opens directly into
/// `BudgetView` (Allocate/Remaining/Goals), and Budget Insights moved to a sheet action there.
/// This view is kept, unused, specifically to preserve Forecast's placeholder tile/route
/// (`ComingSoonView`) for future reintroduction once a forecasting engine exists — see Task 6 of
/// the Phase 2H-B brief and `CLARITY_PRODUCT_ARCHITECTURE.md`'s Plan section. Do not delete.
///
/// Goals and Forecast have no implementation yet — this phase explicitly does not build them
/// (`CLARITY_PRODUCT_ARCHITECTURE.md` §22/§25 Open Decisions 5/6 remain open). They route to the
/// same `ComingSoonView` placeholder `ToolsView` already uses for its own not-yet-built
/// destinations (Reminders, Bank Connections), so their tab entries exist without pretending a
/// feature is there.
struct PlanContainerView: View {
    private let items: [PlanItem] = [
        PlanItem(title: "Budget", icon: "chart.bar.fill", isAvailable: true),
        PlanItem(title: "Goals", icon: "target", isAvailable: false),
        PlanItem(title: "Forecast", icon: "chart.line.uptrend.xyaxis", isAvailable: false)
    ]

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GradientHeader(title: "Plan")
                    .padding(.top, 8)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items) { item in
                            NavigationLink {
                                destination(for: item)
                            } label: {
                                PlanCard(item: item)
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
    private func destination(for item: PlanItem) -> some View {
        switch item.title {
        case "Budget":
            // `BudgetContentView`, not `BudgetView` — avoids nesting a second `NavigationStack`
            // inside this one. See `BudgetView`'s doc comment.
            BudgetContentView()
        default:
            ComingSoonView(title: item.title, icon: item.icon)
        }
    }
}

private struct PlanCard: View {
    let item: PlanItem

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
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        }
    }
}

#Preview {
    PlanContainerView()
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
