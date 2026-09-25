import SwiftUI
import SwiftData

/// One question/answer exchange in the on-screen conversation.
private struct AskClarityTurn: Identifiable {
    let id = UUID()
    let question: String
    let answer: AskClarityAnswer
}

/// A handful of example questions shown as tappable chips — discovery aids for "what can I ask
/// Clarity," never a restriction on what can be typed. `AskClarityInterpreter`/`AskClarityEngine`
/// understand a much broader, compositional set of questions than this fixed list; see
/// `Models/AskClarityInterpreter.swift`'s header doc comment.
private let exampleQuestions = [
    "How much did I spend this month?",
    "Where am I spending the most?",
    "Am I within my budget?",
    "Which categories are over budget?",
    "Did I spend more this month than last month?",
    "How much do I have left to spend?"
]

/// "Ask Clarity": a local, deterministic Q&A screen over the app's own data. Reuses
/// `AskClarityEngine`, which itself reuses `BudgetCalculator`/`OverviewCalculator`/
/// `ExplainMyMonthCalculator`, so nothing here recomputes spend/budget math. Understands a broad,
/// compositional set of questions (metric + category + time period + ranking + comparison, etc. —
/// see `AskClarityInterpreter`) rather than a fixed list of whole sentences, and keeps lightweight
/// session-only context (last category/metric/period) so follow-ups like "and last month?" work.
/// Still never calls an external AI service, and never guesses past an ambiguous or unmatched
/// category — this is a broader deterministic query system, not an open chatbot.
struct AskClarityView: View {
    @ObservedObject private var budgetSettings = BudgetSettingsStore.shared
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Query private var allBudgets: [Budget]
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]

    @State private var inputText = ""
    @State private var conversation: [AskClarityTurn] = []
    /// Session-only memory of the last resolved subject — reset whenever this view is recreated
    /// (e.g. leaving and reopening More → Ask Clarity). Never written to `UserDefaults`/SwiftData.
    @State private var context = AskClaritySessionContext.empty

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: ClaritySpacing.lg) {
                        if conversation.isEmpty {
                            // Only shown before the first turn — these are examples of what can
                            // be asked, not the limit of it. Once a conversation is underway,
                            // per-answer follow-up chips (contextual to that answer) take over.
                            Text("Ask about your spending, budget, income, or a specific category — for example:")
                                .font(.subheadline)
                                .foregroundStyle(.textSecondary)
                            suggestionsSection(exampleQuestions)
                        }

                        ForEach(conversation) { turn in
                            AskClarityTurnView(turn: turn, onTapFollowUp: ask)
                                .id(turn.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: conversation.count) { _, _ in
                    guard let last = conversation.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            inputBar
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Ask Clarity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !conversation.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // A fresh conversation must never see the old one's category/metric/
                        // period — session context is local `@State`, never persisted, and this
                        // is the explicit "start over" action for it within the same screen visit.
                        withAnimation {
                            conversation = []
                            context = .empty
                        }
                    } label: {
                        Label("New conversation", systemImage: "square.and.pencil")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Start a new conversation")
                }
            }
        }
    }

    private func suggestionsSection(_ questions: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(questions, id: \.self) { question in
                    Button {
                        ask(question)
                    } label: {
                        Text(question)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.surfaceSecondary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about your spending…", text: $inputText)
                .foregroundStyle(.textPrimary)
                .submitLabel(.send)
                .onSubmit(submit)
                .padding(10)
                .background(Color.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSubmit ? AnyShapeStyle(LinearGradient.emeraldSky) : AnyShapeStyle(Color.textDisabled))
            }
            .disabled(!canSubmit)
        }
        .padding(12)
        .background(Color.appBackground)
    }

    private var canSubmit: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ask(text)
        inputText = ""
    }

    private func ask(_ text: String) {
        let result = AskClarityEngine.respond(
            to: text, context: context, entries: allEntries, budgets: allBudgets, headCategories: headCategories,
            settings: BudgetCalculationSettings(from: budgetSettings)
        )
        context = result.updatedContext
        conversation.append(AskClarityTurn(question: text, answer: result.answer))
    }
}

private struct AskClarityTurnView: View {
    let turn: AskClarityTurn
    let onTapFollowUp: (String) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(turn.question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.emerald.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: .infinity, alignment: .trailing)

            answerBubble
                .frame(maxWidth: .infinity, alignment: .leading)

            if !turn.answer.followUpSuggestions.isEmpty {
                followUpChips
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Comparison text is colored to read at a glance — favorable (spending down, within budget)
    /// in the app's positive tint, unfavorable in its warning tint, neutral otherwise. Purely a
    /// presentation choice on data `AskClarityEngine` already computed
    /// (`AskClarityAnswer.comparisonIsFavorable`); no new figure is introduced.
    private var detailColor: Color {
        switch turn.answer.comparisonIsFavorable {
        case true: .emerald
        case false: .expenseRed
        case nil: .textSecondary
        }
    }

    private var answerBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(turn.answer.headline)
                .font(.subheadline.weight(turn.answer.hasSufficientData ? .semibold : .regular))
                .foregroundStyle(turn.answer.hasSufficientData ? .textPrimary : .textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !turn.answer.supportingDetail.isEmpty {
                Text(turn.answer.supportingDetail)
                    .font(.caption)
                    .foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
    }

    /// A couple of directly-relevant next questions, specific to *this* answer — never the same
    /// generic list every turn. Horizontally scrollable so a longer question never gets clipped
    /// or forces the chip row to wrap and crowd the transcript.
    private var followUpChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(turn.answer.followUpSuggestions, id: \.self) { question in
                    Button {
                        onTapFollowUp(question)
                    } label: {
                        Text(question)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.textSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.surfaceSecondary.opacity(0.6), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        AskClarityView()
    }
    .preferredColorScheme(.dark)
    .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
