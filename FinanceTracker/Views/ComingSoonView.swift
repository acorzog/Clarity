import SwiftUI

struct ComingSoonView: View {
    let title: String
    var icon: String = "hourglass"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(LinearGradient.emeraldSky)

            Text("Coming Soon")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text("\(title) isn't available yet, but it's on the way.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
