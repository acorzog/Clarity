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

/// "Ask Clarity": a Q&A screen over the app's own data, local-first by design. Reuses
/// `AskClarityEngine`, which itself reuses `BudgetCalculator`/`OverviewCalculator`/
/// `ExplainMyMonthCalculator`, so nothing here — local or Claude-assisted — ever recomputes
/// spend/budget math; every number always comes from `AskClarityPlanner`/`AskClarityExecutor`.
/// Understands a broad, compositional set of questions (metric + category + time period + ranking
/// + comparison, etc. — see `AskClarityInterpreter`) rather than a fixed list of whole sentences,
/// and keeps lightweight session-only context (last category/metric/period) so follow-ups like
/// "and last month?" work, whether or not a previous turn used Claude.
///
/// Claude is consulted in two narrow, optional, fail-safe roles — never to compute a figure, never
/// as an open chatbot — see `performAsk`'s doc comment for the full pipeline:
///  - **Semantic interpretation fallback**, only when the local deterministic interpreter finds no
///    signal at all in a question — it still never guesses past an ambiguous or unmatched category.
///  - **Response phrasing**, an optional wording pass over an already-fully-verified answer, kept
///    honest by `AskClarityPhrasingFidelity`.
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
    /// True only while a question is awaiting `AskClarityEngine.respondWithSemanticFallback` — the
    /// local deterministic pass is synchronous and never sets this; it's set right before that call
    /// and cleared right after, purely to drive the typing indicator and prevent overlapping asks.
    @State private var isAsking = false
    /// Caps LLM calls across this whole conversation — both interpretation and phrasing calls
    /// share this single budget, not just per question — reset alongside `context` by "New
    /// conversation" so a fresh session gets a fresh budget.
    @State private var callBudget = AskClaritySemanticCallBudget()
    /// The one Anthropic provider in the app, conforming to both `AskClaritySemanticProviding`
    /// (interpretation fallback) and `AskClarityPhrasingProviding` (response phrasing) — genuinely
    /// one instance serving both purposes, not two, so the two calls a single question can trigger
    /// share the same networking/session underneath. Declared as the concrete type so it can be
    /// passed directly wherever either protocol is expected; kept as one `private let` so it can be
    /// swapped for stubs in tests without touching this view (tests drive `AskClarityEngine`'s
    /// functions directly with `StubSemanticProvider`/`StubPhrasingProvider` instead).
    private let anthropicProvider = AnthropicClaritySemanticProvider()

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

                        if isAsking {
                            typingIndicator
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
                .onChange(of: isAsking) { _, nowAsking in
                    guard nowAsking else { return }
                    withAnimation { proxy.scrollTo("askClarityTypingIndicator", anchor: .bottom) }
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
                            callBudget = AskClaritySemanticCallBudget()
                        }
                    } label: {
                        Label("New conversation", systemImage: "square.and.pencil")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Start a new conversation")
                    .disabled(isAsking)
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
                    .disabled(isAsking)
                }
            }
        }
    }

    /// Shown only while `isAsking` is true, appended after the last real turn — a lightweight
    /// "Clarity is thinking…" affordance covering `performAsk`'s whole round-trip, which may
    /// include a semantic interpretation call, a phrasing call, both, or neither (the fully local
    /// deterministic pass alone never takes long enough to need this indicator).
    private var typingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(.textSecondary)
            Text("Clarity is thinking…")
                .font(.caption)
                .foregroundStyle(.textSecondary)
        }
        .padding(14)
        .background(Color.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .id("askClarityTypingIndicator")
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about your spending…", text: $inputText)
                .foregroundStyle(.textPrimary)
                .submitLabel(.send)
                .onSubmit(submit)
                .disabled(isAsking)
                .padding(10)
                .background(Color.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))

            Button(action: submit) {
                if isAsking {
                    ProgressView()
                        .font(.title2)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSubmit ? AnyShapeStyle(LinearGradient.emeraldSky) : AnyShapeStyle(Color.textDisabled))
                }
            }
            .disabled(!canSubmit || isAsking)
        }
        .padding(12)
        .background(Color.appBackground)
    }

    private var canSubmit: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAsking else { return }
        ask(text)
        inputText = ""
    }

    /// Fires the async ask flow from a synchronous SwiftUI action closure (button taps, `onSubmit`,
    /// follow-up chips). `performAsk` itself guards against overlap, so a stray double-tap here
    /// just no-ops on the second call rather than firing a second request.
    private func ask(_ text: String) {
        Task { await performAsk(text) }
    }

    /// The full pipeline, in order:
    ///  1. **Local interpretation** — `AskClarityEngine.respondWithSemanticFallback` always tries
    ///     the fully local, deterministic `AskClarityInterpreter` first, synchronously, at zero API
    ///     cost.
    ///  2. **Claude semantic fallback**, only if step 1 found no signal at all in the question — at
    ///     most one call, gated by `callBudget`.
    ///  3. **Planner → Executor**, unchanged either way — the same calculators produce the same
    ///     kind of verified `AskClarityAnswer` regardless of which interpreter (local or Claude)
    ///     recognized the question. Step 1 already does this internally once a query exists.
    ///  4. **Claude response phrasing** (`AskClarityEngine.phrasedNaturally`) — takes the answer
    ///     from step 3 and optionally rewords it, at most one further call, sharing the exact same
    ///     `callBudget` as step 2. It receives *only* that answer's own display text and the
    ///     question — never a transaction, `Category`/`Entry` object, or any other raw financial
    ///     data (see `AskClarityPhrasingContext`).
    ///  5. **Fidelity validation** — every candidate rephrasing is checked by
    ///     `AskClarityPhrasingFidelity.preservesFacts` before ever being shown; a failure (or a
    ///     provider failure) falls back to step 3's original deterministic answer untouched.
    ///
    /// Every field the final answer is built from (amounts, totals, budget health) still comes
    /// entirely from `entries`/`budgets`/`headCategories` via `AskClarityPlanner`/`AskClarityExecutor`
    /// — Claude only ever chooses *which* query to run (step 2) or *how the already-verified answer
    /// reads* (step 4), never *what the numbers are*. `context` is threaded from step 1/3 only —
    /// phrasing never touches it, so follow-ups work identically whether or not the previous turn
    /// went through Claude at any point. If either Claude call is unavailable, times out, or
    /// returns anything invalid, the existing deterministic answer is shown instead — no separate
    /// error UI, since that answer already reads as a clear, honest response on its own.
    private func performAsk(_ text: String) async {
        guard !isAsking else { return }
        isAsking = true
        let settings = BudgetCalculationSettings(from: budgetSettings)

        let deterministicResult = await AskClarityEngine.respondWithSemanticFallback(
            to: text, context: context, entries: allEntries, budgets: allBudgets, headCategories: headCategories,
            settings: settings, semanticProvider: anthropicProvider, callBudget: callBudget
        )
        let finalResult = await AskClarityEngine.phrasedNaturally(
            deterministicResult, question: text, phrasingProvider: anthropicProvider, callBudget: callBudget
        )

        context = finalResult.updatedContext
        conversation.append(AskClarityTurn(question: text, answer: finalResult.answer))
        isAsking = false
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
