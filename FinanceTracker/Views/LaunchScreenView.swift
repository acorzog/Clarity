import SwiftUI

/// Branded splash shown for a beat right after launch, on top of the system's static native
/// launch screen (a plain dark background — see `UILaunchScreen` in project.yml/Info.plist).
/// Recreates the app icon's bar-chart mark with a growth animation, then fades into the app.
struct LaunchScreenView: View {
    @State private var barScales: [CGFloat] = [0, 0, 0]
    @State private var wordmarkOpacity = 0.0
    @State private var wordmarkOffset: CGFloat = 8

    private let barHeights: [CGFloat] = [44, 74, 104]
    private let barWidth: CGFloat = 34

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            RadialGradient(
                colors: [Color.emerald.opacity(0.16), Color.appBackground.opacity(0)],
                center: .center,
                startRadius: 10,
                endRadius: 220
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(0..<3, id: \.self) { index in
                        RoundedRectangle(cornerRadius: barWidth / 2)
                            .fill(LinearGradient.emeraldSky)
                            .frame(width: barWidth, height: barHeights[index])
                            .scaleEffect(y: barScales[index], anchor: .bottom)
                    }
                }

                Text("Clarity")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient.emeraldSky)
                    .opacity(wordmarkOpacity)
                    .offset(y: wordmarkOffset)
            }
        }
        .onAppear(perform: animate)
    }

    private func animate() {
        for index in 0..<3 {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.65).delay(Double(index) * 0.12)) {
                barScales[index] = 1
            }
        }
        withAnimation(.easeOut(duration: 0.4).delay(0.42)) {
            wordmarkOpacity = 1
            wordmarkOffset = 0
        }
    }
}

#Preview {
    LaunchScreenView()
}
