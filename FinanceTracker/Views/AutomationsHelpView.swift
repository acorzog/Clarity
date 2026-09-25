import SwiftUI

/// Purely instructional — explains how to wire Clarity's App Intents into Shortcuts
/// Automations. The automation itself is configured manually in the Shortcuts app;
/// this screen documents that setup rather than attempting to create it from here.
struct AutomationsHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Two actions are available in Shortcuts")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))

                    ActionSummaryRow(
                        icon: "plus.circle.fill",
                        title: "New Transaction",
                        detail: "Always asks for an amount and a merchant/note — Shortcuts prompts for whichever one an automation didn't already provide, the same reliable way it prompts for the amount, so this works even with Ask Before Running turned off. If you don't pick an exact category, the note is matched to the closest real category — instantly if it already resembles a category name, otherwise with an AI guess. Works from Siri, the Shortcuts app, an Automation, or the Action Button — Clarity doesn't need to be open."
                    )
                    ActionSummaryRow(
                        icon: "text.bubble.fill",
                        title: "Transaction from Message",
                        detail: "Takes a block of text (a forwarded bank SMS or notification), uses AI to pull out the amount, merchant, and category, then walks you through confirming each one before it saves."
                    )
                }
                .padding(20)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 16) {
                    Text("Auto-log from a bank notification")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))

                    Text("This part is set up manually in the Shortcuts app — Clarity can't create it for you, but here's exactly how:")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))

                    HowToStep(number: 1, text: "Open the Shortcuts app, go to Automation, then tap + → Create Personal Automation.")
                    HowToStep(number: 2, text: "Choose App, pick your bank or wallet app, and set the trigger to Notifications Received.")
                    HowToStep(number: 3, text: "Add an action: Get Text from Input (or Get Contents of Notification), so the notification's text is captured.")
                    HowToStep(number: 4, text: "Add another action: Run Clarity, choose Transaction from Message, and set its Message Text input to the text from step 3.")
                    HowToStep(number: 5, text: "Turn off Ask Before Running if you want it fully hands-off — Clarity will still prompt you to confirm the amount, note, and category before saving anything.")
                }
                .padding(20)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 16) {
                    Text("Trigger from an Apple Pay payment")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))

                    HowToStep(number: 1, text: "In Shortcuts → Automation → + → Create Personal Automation, choose Apple Pay and pick a card.")
                    HowToStep(number: 2, text: "Add an action: Run Clarity, choose New Transaction or Transaction from Message depending on what text the automation gives you.")
                    HowToStep(number: 3, text: "If no text is available, use New Transaction — Shortcuts will prompt for the amount and a merchant/note itself, even with Ask Before Running off.")
                }
                .padding(20)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 16) {
                    Text("Assign to the Action Button")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))

                    HowToStep(number: 1, text: "Open Settings → Action Button, and choose Shortcut.")
                    HowToStep(number: 2, text: "Pick New Transaction (or a Shortcut you built around Transaction from Message) as the shortcut to run.")
                }
                .padding(20)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Automations")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ActionSummaryRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(LinearGradient.emeraldSky)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    NavigationStack {
        AutomationsHelpView()
    }
    .preferredColorScheme(.dark)
}
