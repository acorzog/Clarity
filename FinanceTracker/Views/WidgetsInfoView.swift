import SwiftUI

/// Purely instructional — shows what the app's home-screen widgets look like and
/// how to add them. No WidgetKit extension exists in this project yet, so the
/// previews below are static mockups styled to match the in-app palette rather
/// than live widget snapshots.
struct WidgetsInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Available Widgets")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))

                    HStack(spacing: 16) {
                        BudgetGaugeWidgetPreview()
                        QuickLogWidgetPreview()
                    }
                    .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("How to Add a Widget")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))

                    VStack(alignment: .leading, spacing: 14) {
                        HowToStep(number: 1, text: "Touch and hold an empty area on your Home Screen until the apps jiggle.")
                        HowToStep(number: 2, text: "Tap the + button in the top corner.")
                        HowToStep(number: 3, text: "Search for Clarity, choose a widget, and tap Add Widget.")
                    }
                }
                .padding(20)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))

                Button {
                    dismiss()
                } label: {
                    Text("Got it")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(LinearGradient.emeraldSky, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Widgets")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BudgetGaugeWidgetPreview: View {
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: 0.75 * 0.62)
                    .stroke(Color.emerald, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(135))
                VStack(spacing: 2) {
                    Text("Left")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("620€")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 70, height: 70)

            Text("Budget")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(width: 155, height: 155)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.08)))
    }
}

private struct QuickLogWidgetPreview: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(LinearGradient.emeraldSky)
            Text("Add Expense")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text("Quick Log")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(width: 155, height: 155)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.08)))
    }
}

private struct HowToStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(LinearGradient.emeraldSky, in: Circle())
            Text(text)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    NavigationStack {
        WidgetsInfoView()
    }
    .preferredColorScheme(.dark)
}
