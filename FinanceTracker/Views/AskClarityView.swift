import SwiftUI
import SwiftData

/// One question/answer exchange in the on-screen conversation.
private struct AskClarityTurn: Identifiable {
    let id = UUID()
    let question: String
    let answer: AskClarityAnswer
    /// The session context as it stood *before* this question was asked — captured alongside the
    /// turn so `AskClarityInsight.build(for:context:...)` can later re-interpret this exact
    /// question (e.g. resolving "and last month?" the same way `performAsk` originally did),
    /// purely for card presentation. Never written back to `AskClarityEngine` or reused to answer
    /// anything — see `AskClarityInsight`'s doc comment.
    let contextBeforeAsk: AskClaritySessionContext
}

/// A discovery aid shown on the empty-state screen — never a restriction on what can be typed.
/// `AskClarityInterpreter`/`AskClarityEngine` understand a much broader, compositional set of
/// questions than this fixed list; see `Models/AskClarityInterpreter.swift`'s header doc comment.
private struct AskClaritySuggestedQuestion: Identifiable {
    let id = UUID()
    let category: String
    let icon: String
    let question: String
}

/// Same six example questions the previous chip row showed, just paired with a category label
/// and icon for the new card layout — the underlying capability hasn't changed.
private let suggestedQuestions: [AskClaritySuggestedQuestion] = [
    .init(category: "Spending", icon: "chart.bar.fill", question: "How much did I spend this month?"),
    .init(category: "Categories", icon: "magnifyingglass", question: "Where am I spending the most?"),
    .init(category: "Budget", icon: "target", question: "Am I within my budget?"),
    .init(category: "Budget", icon: "exclamationmark.triangle.fill", question: "Which categories are over budget?"),
    .init(category: "Changes", icon: "arrow.left.arrow.right", question: "Did I spend more this month than last month?"),
    .init(category: "Remaining", icon: "wallet.bifold.fill", question: "How much do I have left to spend?")
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
///
/// Presents two distinct states — a discovery-first empty/welcome state before the first question,
/// and a content-first conversation state afterward (§19 of the redesign brief) — but both are
/// still driven by the exact same `performAsk` pipeline below; only the surrounding chrome differs.
/// A secondary screen: it hides the app's main tab bar (`toolbar(.hidden, for: .tabBar)`) so it
/// reads as its own focused conversation, with the standard back button returning to wherever it
/// was opened from.
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
                    Group {
                        if conversation.isEmpty {
                            welcomeSection
                                .padding(.top, ClaritySpacing.md)
                        } else {
                            conversationSection
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, ClaritySpacing.lg)
                    .padding(.bottom, ClaritySpacing.xxl)
                    .readableContentWidth()
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

            AskClarityComposer(
                text: $inputText,
                placeholder: conversation.isEmpty ? "Ask Clarity about your money…" : "Ask a follow-up…",
                isSending: isAsking,
                canSubmit: canSubmit,
                onSubmit: submit
            )
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Ask Clarity")
        .navigationBarTitleDisplayMode(.inline)
        // Ask Clarity is a secondary, focused conversation screen — the app's main Home/Overview/
        // Plan/Wallets/More tab bar has no place inside it; Back is the only way out.
        .toolbar(.hidden, for: .tabBar)
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

    // MARK: - Empty / welcome state

    private var welcomeSection: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.xxl) {
            identityHeader
            introCard
            trySection
        }
        .frame(maxWidth: .infinity)
    }

    private var identityHeader: some View {
        VStack(spacing: ClaritySpacing.sm) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title)
                .foregroundStyle(LinearGradient.emeraldSky)
                .frame(width: 72, height: 72)
                .background(Color.surfaceSecondary, in: Circle())

            Text("Ask Clarity")
                .font(.title2.bold())
                .foregroundStyle(.textPrimary)

            Text("Your personal financial assistant.")
                .font(.subheadline)
                .foregroundStyle(.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var introCard: some View {
        SectionCard {
            HStack(alignment: .top, spacing: ClaritySpacing.md) {
                Image(systemName: "sparkles")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(LinearGradient.emeraldSky)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: ClaritySpacing.xs) {
                    Text("Get insights about your money")
                        .font(.sectionTitle)
                        .foregroundStyle(.textPrimary)
                    Text("Ask about your spending, budgets, income, or any category.")
                        .font(.caption)
                        .foregroundStyle(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var trySection: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.md) {
            Text("Try asking…")
                .font(.sectionTitle)
                .foregroundStyle(.textSecondary)

            VStack(spacing: ClaritySpacing.sm) {
                ForEach(suggestedQuestions) { item in
                    AskClaritySuggestionCard(item: item, isDisabled: isAsking) {
                        ask(item.question)
                    }
                }
            }
        }
    }

    // MARK: - Active conversation state

    private var conversationSection: some View {
        LazyVStack(alignment: .leading, spacing: ClaritySpacing.lg) {
            ForEach(conversation) { turn in
                AskClarityTurnView(
                    turn: turn, entries: allEntries, budgets: allBudgets, headCategories: headCategories,
                    settings: BudgetCalculationSettings(from: budgetSettings), onTapFollowUp: ask
                )
                .id(turn.id)
            }

            if isAsking {
                typingIndicator
            }
        }
    }

    /// Shown only while `isAsking` is true, appended after the last real turn — a lightweight
    /// "Clarity is thinking…" affordance covering `performAsk`'s whole round-trip, which may
    /// include a semantic interpretation call, a phrasing call, both, or neither (the fully local
    /// deterministic pass alone never takes long enough to need this indicator).
    private var typingIndicator: some View {
        HStack(spacing: ClaritySpacing.sm) {
            ProgressView()
                .tint(.textSecondary)
            Text("Clarity is thinking…")
                .font(.caption)
                .foregroundStyle(.textSecondary)
        }
        .padding(ClaritySpacing.lg)
        .background(Color.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClarityRadius.large))
        .frame(maxWidth: .infinity, alignment: .leading)
        .id("askClarityTypingIndicator")
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
    /// suggestion cards, follow-up rows). `performAsk` itself guards against overlap, so a stray
    /// double-tap here just no-ops on the second call rather than firing a second request.
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

        let contextBeforeAsk = context
        let deterministicResult = await AskClarityEngine.respondWithSemanticFallback(
            to: text, context: context, entries: allEntries, budgets: allBudgets, headCategories: headCategories,
            settings: settings, semanticProvider: anthropicProvider, callBudget: callBudget
        )
        let finalResult = await AskClarityEngine.phrasedNaturally(
            deterministicResult, question: text, phrasingProvider: anthropicProvider, callBudget: callBudget
        )

        context = finalResult.updatedContext
        conversation.append(AskClarityTurn(question: text, answer: finalResult.answer, contextBeforeAsk: contextBeforeAsk))
        isAsking = false
    }
}

/// A single vertical, fully-tappable suggested-question card for the empty state — replaces the
/// old horizontally-scrolling chip row, which could clip its last item on narrow screens.
private struct AskClaritySuggestionCard: View {
    let item: AskClaritySuggestedQuestion
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ClaritySpacing.md) {
                Image(systemName: item.icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(LinearGradient.emeraldSky)
                    .frame(width: 36, height: 36)
                    .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: ClarityRadius.small))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.category)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.textSecondary)
                    Text(item.question)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: ClaritySpacing.sm)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.textTertiary)
            }
            .padding(ClaritySpacing.lg)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClarityRadius.large))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.category): \(item.question)")
        .accessibilityHint("Asks Clarity this question")
    }
}

/// The bottom chat composer — a rounded, elevated capsule containing the text field and send
/// button, kept visible above the keyboard by SwiftUI's default keyboard-avoidance (no manual
/// offsets), and always accessible via the surrounding `VStack` in `AskClarityView.body`.
private struct AskClarityComposer: View {
    @Binding var text: String
    let placeholder: String
    let isSending: Bool
    let canSubmit: Bool
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: ClaritySpacing.sm) {
            TextField(placeholder, text: $text, axis: .vertical)
                .foregroundStyle(.textPrimary)
                .submitLabel(.send)
                .lineLimit(1...4)
                .onSubmit(onSubmit)
                .disabled(isSending)

            Button(action: onSubmit) {
                Group {
                    if isSending {
                        ProgressView()
                            .tint(.appBackground)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(canSubmit ? Color.appBackground : Color.textDisabled)
                    }
                }
                .frame(width: 36, height: 36)
                .background(
                    canSubmit ? AnyShapeStyle(LinearGradient.emeraldSky) : AnyShapeStyle(Color.surfaceSecondary),
                    in: Circle()
                )
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .disabled(!canSubmit || isSending)
            .accessibilityLabel("Send")
        }
        .padding(.leading, ClaritySpacing.lg)
        .padding(.trailing, ClaritySpacing.xs)
        .padding(.vertical, ClaritySpacing.sm)
        .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: ClarityRadius.extraLarge, style: .continuous))
        .padding(.horizontal, ClaritySpacing.lg)
        .padding(.top, ClaritySpacing.sm)
        .padding(.bottom, ClaritySpacing.sm)
        .background(Color.appBackground)
    }
}

private struct AskClarityTurnView: View {
    let turn: AskClarityTurn
    let entries: [Entry]
    let budgets: [Budget]
    let headCategories: [HeadCategory]
    let settings: BudgetCalculationSettings
    let onTapFollowUp: (String) -> Void

    /// Only ever a *presentation* of the same answer `AskClarityEngine` already produced (see
    /// `AskClarityInsight`'s doc comment) — `nil` whenever there isn't a card designed for this
    /// question shape, or not enough real data to fill one in, in which case `answerCard` below
    /// is shown instead. Recomputed on every render, but cheap: purely in-memory, synchronous,
    /// local matching over data already loaded for this screen — no network, no LLM.
    private var insight: AskClarityInsight? {
        AskClarityInsight.build(
            for: turn.question, context: turn.contextBeforeAsk, entries: entries, budgets: budgets,
            headCategories: headCategories, settings: settings
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.md) {
            userBubble

            if turn.answer.hasSufficientData, let insight {
                insightCard(for: insight)
            } else {
                answerCard
            }

            if !turn.answer.followUpSuggestions.isEmpty {
                followUpSection
            }
        }
    }

    @ViewBuilder
    private func insightCard(for insight: AskClarityInsight) -> some View {
        switch insight {
        case .spending(let data): AskClaritySpendingInsightCard(insight: data)
        case .category(let data): AskClarityCategoryInsightCard(insight: data)
        case .budget(let data): AskClarityBudgetInsightCard(insight: data)
        case .categoryBudgetList(let data): AskClarityCategoryBudgetListInsightCard(insight: data)
        }
    }

    private var userBubble: some View {
        Text(turn.question)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.textPrimary)
            .padding(.horizontal, ClaritySpacing.lg)
            .padding(.vertical, ClaritySpacing.md)
            .background(Color.emerald.opacity(0.25), in: RoundedRectangle(cornerRadius: ClarityRadius.medium))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Comparison text is colored to read at a glance — favorable (spending down, within budget)
    /// in the app's positive tint, unfavorable in its expense tint, neutral otherwise. Purely a
    /// presentation choice on data `AskClarityEngine` already computed
    /// (`AskClarityAnswer.comparisonIsFavorable`); no new figure is introduced.
    private var detailColor: Color {
        switch turn.answer.comparisonIsFavorable {
        case true: .success
        case false: .expense
        case nil: .textSecondary
        }
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.sm) {
            HStack(spacing: ClaritySpacing.xs) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LinearGradient.emeraldSky)
                Text("Clarity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.textSecondary)
            }

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
        .padding(ClaritySpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClarityRadius.large))
    }

    /// A couple of directly-relevant next questions, specific to *this* answer — never the same
    /// generic list every turn. Stacked vertically (rather than the old horizontally-scrolling
    /// chip row) so a longer question is never clipped.
    private var followUpSection: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.sm) {
            Text("You might also ask…")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.textTertiary)

            VStack(spacing: ClaritySpacing.xs) {
                ForEach(turn.answer.followUpSuggestions, id: \.self) { question in
                    Button {
                        onTapFollowUp(question)
                    } label: {
                        HStack(spacing: ClaritySpacing.sm) {
                            Text(question)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.textPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: ClaritySpacing.sm)

                            Image(systemName: "arrow.up.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.textTertiary)
                        }
                        .padding(.horizontal, ClaritySpacing.md)
                        .padding(.vertical, ClaritySpacing.sm)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: ClarityRadius.small))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Asks Clarity this follow-up question")
                }
            }
        }
    }
}

// MARK: - Visual insights
//
// A structured, colorful rendering of an `AskClarityAnswer` for the question shapes that have
// enough real, already-computed data to visualize — never a second source of truth for the
// numbers, and never a replacement for `AskClarityAnswer` itself.
//
// Built by independently re-running the exact same local, deterministic **interpret → plan →
// execute** stages `AskClarityEngine.respond` already uses — `AskClarityInterpreter` /
// `AskClarityPlanner` / `AskClarityExecutor` — against the same `entries`/`budgets`/
// `headCategories`, one more time, purely to keep the raw `Decimal`/`Category`/`BudgetHealthState`
// values a card needs (`AskClarityAnswer` itself only ever carries pre-formatted `String`s — see
// its doc comment). Never a new financial calculation: every figure here comes from the exact
// same `BudgetCalculator`/`OverviewCalculator` calls the engine's own pipeline makes. Does not
// call `AskClarityEngine.respond`/`phrasedNaturally` and never touches `AskClaritySessionContext`
// or `AskClaritySemanticCallBudget` — purely an additional, read-only presentation pass over data
// `AskClarityView` already has.
//
// When nothing here applies (`build(...)` returns `nil`) — insufficient data, or a question shape
// with no card designed for it yet — the existing plain-text `AskClarityAnswer` is shown instead;
// see `AskClarityTurnView.body`. No case ever fabricates a number or shows an empty chart.
//
// Internal (not `private`), unlike the card views below it, specifically so `AskClarityInsightTests`
// can exercise `build(...)` directly via `@testable import` — the card views themselves stay
// `private`, since they're pure rendering with nothing to unit test.
enum AskClarityInsight {
    case spending(SpendingInsight)
    case category(CategoryInsight)
    case budget(BudgetInsight)
    case categoryBudgetList(CategoryBudgetListInsight)

    /// "How much did I spend this month?" — a total with no category named.
    struct SpendingInsight {
        let amount: Decimal
        let periodLabel: String
        /// `nil` when the period isn't month-based, or no budget/income data exists to compare
        /// against — the card then simply omits the progress row rather than showing an empty one.
        let available: Decimal?
        let previousPeriod: (amount: Decimal, label: String)?
    }

    /// Either "Where am I spending the most?" (`title == "Top spending category"`, the ranking's
    /// winner) or a plain single-category amount question like "How much did I spend on Housing
    /// this month?" (`title == "\(category.name) spending"`) — same shape either way.
    struct CategoryInsight {
        let title: String
        let category: Category
        let amount: Decimal
        let periodLabel: String
        /// This category's share of every category's spend the same period, when the ranking
        /// path computed one (`nil` for the plain-amount path — no ranking context to share against).
        let shareOfTotal: Double?
        let previousPeriod: (amount: Decimal, label: String)?
    }

    /// "Am I within my budget?" — the overall, categoryless verdict.
    struct BudgetInsight {
        let state: BudgetHealthState
        let spent: Decimal
        let available: Decimal
        let periodLabel: String
    }

    /// "Which categories are over/within budget?" — every category currently in `state`.
    struct CategoryBudgetListInsight {
        let state: BudgetHealthState
        let rows: [CategorySpendingHealth]
        let periodLabel: String
    }

    static func build(
        for question: String,
        context: AskClaritySessionContext,
        entries: [Entry],
        budgets: [Budget],
        headCategories: [HeadCategory],
        settings: BudgetCalculationSettings,
        calendar: Calendar = .current,
        today: Date = .now
    ) -> AskClarityInsight? {
        let categories = headCategories.flatMap { $0.categories.filter { !$0.isArchived } }
        guard let query = AskClarityInterpreter.interpret(question, categories: categories, context: context, today: today, calendar: calendar) else {
            return nil
        }
        guard case .plan(let plan) = AskClarityPlanner.plan(for: query, context: context, today: today, calendar: calendar) else {
            return nil
        }
        let execution = AskClarityExecutor.execute(
            plan: plan, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today
        )

        switch (plan.operation, execution) {
        case (.amount, .amount(let primary, _, let previousPeriod, let hasData)):
            guard hasData, primary > 0 else { return nil }

            if plan.subjects.isEmpty, plan.metric == .spending {
                let available = monthlyAvailable(
                    periodKind: plan.period.kind, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, calendar: calendar, today: today
                )
                return .spending(SpendingInsight(amount: primary, periodLabel: plan.period.label, available: available, previousPeriod: previousPeriod))
            }

            // A single, specifically-named leaf category — not an aggregated head category
            // (`singleCategory == nil` there), which has no one icon/color of its own to show.
            if let subject = plan.subjects.first, let category = subject.singleCategory {
                return .category(CategoryInsight(
                    title: "\(category.name) spending", category: category, amount: primary,
                    periodLabel: plan.period.label, shareOfTotal: nil, previousPeriod: previousPeriod
                ))
            }
            return nil

        case (.rankCategories, .categoryRanking(let rows)):
            // Only the single-winner phrasing ("where am I spending the most") — a plural list
            // ("my biggest spending categories") isn't one figure to headline a card with.
            guard let ranking = plan.ranking, !ranking.wantsList, ranking.direction == .highest else { return nil }
            let ordered = rows.sorted { $0.amount > $1.amount }
            guard let winner = ordered.first, winner.amount > 0 else { return nil }
            let total = ordered.reduce(Decimal(0)) { $0 + $1.amount }
            let share = total > 0 ? (winner.amount / total).doubleValue : nil
            return .category(CategoryInsight(
                title: "Top spending category", category: winner.category, amount: winner.amount,
                periodLabel: plan.period.label, shareOfTotal: share, previousPeriod: nil
            ))

        case (.budgetState, .overallBudgetState(let summary)):
            guard summary.totalAvailable > 0 else { return nil }
            let progress = (summary.totalSpent / summary.totalAvailable).doubleValue
            return .budget(BudgetInsight(
                state: .forProgress(progress), spent: summary.totalSpent, available: summary.totalAvailable, periodLabel: plan.period.label
            ))

        case (.budgetState, .budgetState(nil, let health)):
            guard let targetQuery = plan.budgetState, !health.isEmpty else { return nil }
            let target = healthState(for: targetQuery)
            let rows = health.filter { $0.state == target }
            guard !rows.isEmpty else { return nil }
            return .categoryBudgetList(CategoryBudgetListInsight(state: target, rows: rows, periodLabel: plan.period.label))

        default:
            return nil
        }
    }

    /// Mirrors `AskClarityEngine`'s own private `targetState(for:)` mapping exactly — not a
    /// financial calculation, just the fixed correspondence between the two enums.
    private static func healthState(for query: AskClarityBudgetStateQuery) -> BudgetHealthState {
        switch query {
        case .overBudget: return .overBudget
        case .approachingLimit: return .approachingLimit
        case .withinBudget: return .onTrack
        }
    }

    private static func monthlyAvailable(
        periodKind: AskClarityPeriodKind, entries: [Entry], budgets: [Budget], headCategories: [HeadCategory],
        settings: BudgetCalculationSettings, calendar: Calendar, today: Date
    ) -> Decimal? {
        guard periodKind.isMonthBased, let month = AskClarityEngine.monthDate(for: periodKind, today: today, calendar: calendar) else { return nil }
        let summary = BudgetCalculator.periodSpendingSummary(
            month: month, entries: entries, budgets: budgets, headCategories: headCategories, settings: settings, respectHiddenCategories: true, calendar: calendar
        )
        return summary.totalAvailable > 0 ? summary.totalAvailable : nil
    }
}

private extension BudgetHealthState {
    /// Reuses `GaugeThreshold`'s exact green/amber/red rule — the same one `RemainingView`'s
    /// gauge and `BudgetGaugeWidget` already use — so a budget insight card can never disagree
    /// with the rest of the app about what counts as on-track/approaching/over.
    var color: Color { GaugeThreshold.color(forProgress: progressAnchor) }

    /// A representative progress value for each state, solely to feed `GaugeThreshold.color(
    /// forProgress:)` — the actual progress fraction a card displays always comes from real data;
    /// this only exists because a *filtered* row list (e.g. every "over budget" category) no
    /// longer carries one shared progress number of its own to color the section by.
    private var progressAnchor: Double {
        switch self {
        case .onTrack: 0.5
        case .approachingLimit: 0.9
        case .overBudget: 1.1
        }
    }

    var label: String {
        switch self {
        case .onTrack: "Within budget"
        case .approachingLimit: "Close to budget"
        case .overBudget: "Over budget"
        }
    }
}

/// A subtle, semantically-tinted card surface — `color` at low opacity over the existing dark
/// background, never a full-strength color fill or a gradient (per the design system's existing
/// "no shadow, no border, flat surfaces" aesthetic — see `DesignSystem/Surfaces/Surface.swift`).
private struct TintedInsightCard<Content: View>: View {
    var color: Color
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(ClaritySpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: ClarityRadius.large))
    }
}

/// The small eyebrow title row every insight card leads with — see the redesign's
/// response-hierarchy spec (Clarity identity, then the insight's own title).
private struct InsightEyebrow: View {
    let title: String
    var color: Color = .textSecondary

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(color)
    }
}

private struct InsightProgressBar: View {
    let progress: Double
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.surfaceElevated)
                Capsule().fill(color).frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 8)
    }
}

private struct AskClaritySpendingInsightCard: View {
    let insight: AskClarityInsight.SpendingInsight

    private var progress: Double? {
        guard let available = insight.available, available > 0 else { return nil }
        return (insight.amount / available).doubleValue
    }
    private var state: BudgetHealthState? { progress.map(BudgetHealthState.forProgress) }

    var body: some View {
        TintedInsightCard(color: state?.color ?? .info) {
            VStack(alignment: .leading, spacing: ClaritySpacing.sm) {
                InsightEyebrow(title: "Monthly spending")

                Text(insight.amount.currencyFormatted)
                    .heroAmountStyle()
                    .foregroundStyle(.textPrimary)
                Text("spent \(insight.periodLabel)")
                    .font(.caption)
                    .foregroundStyle(.textSecondary)

                if let available = insight.available, let progress {
                    InsightProgressBar(progress: progress, color: state?.color ?? .info)
                        .padding(.top, ClaritySpacing.xs)
                    Text("\(insight.amount.currencyFormatted) of \(available.currencyFormatted) — \(progress.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.caption2)
                        .foregroundStyle(.textTertiary)
                }

                if let previousPeriod = insight.previousPeriod {
                    ComparisonRow(current: insight.amount, previous: previousPeriod.amount, previousLabel: previousPeriod.label)
                        .padding(.top, ClaritySpacing.xs)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AskClarityCategoryInsightCard: View {
    let insight: AskClarityInsight.CategoryInsight

    var body: some View {
        TintedInsightCard(color: Color(hex: insight.category.resolvedColorHex)) {
            VStack(alignment: .leading, spacing: ClaritySpacing.sm) {
                InsightEyebrow(title: insight.title)

                HStack(spacing: ClaritySpacing.md) {
                    CategoryIconView(category: insight.category, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(insight.category.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.textPrimary)
                        Text(insight.amount.currencyFormatted)
                            .font(.title2.bold())
                            .foregroundStyle(.textPrimary)
                    }
                }
                Text(insight.periodLabel.capitalizedFirstLetter)
                    .font(.caption)
                    .foregroundStyle(.textSecondary)

                if let share = insight.shareOfTotal {
                    InsightProgressBar(progress: share, color: Color(hex: insight.category.resolvedColorHex))
                        .padding(.top, ClaritySpacing.xs)
                    Text("\(share.formatted(.percent.precision(.fractionLength(0)))) of spending")
                        .font(.caption2)
                        .foregroundStyle(.textTertiary)
                }

                if let previousPeriod = insight.previousPeriod {
                    ComparisonRow(current: insight.amount, previous: previousPeriod.amount, previousLabel: previousPeriod.label)
                        .padding(.top, ClaritySpacing.xs)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AskClarityBudgetInsightCard: View {
    let insight: AskClarityInsight.BudgetInsight

    private var progress: Double { (insight.spent / insight.available).doubleValue }
    private var remaining: Decimal { insight.available - insight.spent }

    var body: some View {
        TintedInsightCard(color: insight.state.color) {
            VStack(alignment: .leading, spacing: ClaritySpacing.sm) {
                HStack(spacing: ClaritySpacing.xs) {
                    Image(systemName: "target")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(insight.state.color)
                    Text(insight.state.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(insight.state.color)
                }

                InsightProgressBar(progress: progress, color: insight.state.color)

                Text("\(insight.spent.currencyFormatted) of \(insight.available.currencyFormatted)")
                    .font(.caption)
                    .foregroundStyle(.textSecondary)

                Text(insight.state == .overBudget
                    ? "\((-remaining).currencyFormatted) over budget \(insight.periodLabel)"
                    : "\(remaining.currencyFormatted) remaining \(insight.periodLabel)")
                    .font(.caption2)
                    .foregroundStyle(.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AskClarityCategoryBudgetListInsightCard: View {
    let insight: AskClarityInsight.CategoryBudgetListInsight

    var body: some View {
        TintedInsightCard(color: insight.state.color) {
            VStack(alignment: .leading, spacing: ClaritySpacing.md) {
                InsightEyebrow(title: insight.state.label, color: insight.state.color)

                VStack(spacing: ClaritySpacing.sm) {
                    ForEach(insight.rows) { row in
                        HStack(spacing: ClaritySpacing.sm) {
                            CategoryIconView(category: row.category, size: 28)
                            Text(row.category.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.textPrimary)
                            Spacer(minLength: ClaritySpacing.sm)
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(row.state == .overBudget
                                    ? "+\((row.spent - row.budgeted).currencyFormatted)"
                                    : row.spent.currencyFormatted)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(row.state.color)
                                Text(row.progress.formatted(.percent.precision(.fractionLength(0))))
                                    .font(.caption2)
                                    .foregroundStyle(.textTertiary)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ComparisonRow: View {
    let current: Decimal
    let previous: Decimal
    let previousLabel: String

    private var delta: Decimal { current - previous }
    private var direction: DeltaIndicator.Direction { delta > 0 ? .up : (delta < 0 ? .down : .flat) }
    private var percent: Double? {
        guard previous != 0 else { return nil }
        return (delta / previous).doubleValue
    }

    var body: some View {
        HStack(spacing: ClaritySpacing.xs) {
            DeltaIndicator(delta: percent?.formatted(.percent.precision(.fractionLength(0))) ?? delta.currencyFormatted, direction: direction, isFavorable: nil)
            Text("vs \(previousLabel)")
                .font(.caption2)
                .foregroundStyle(.textTertiary)
        }
    }
}

private extension String {
    var capitalizedFirstLetter: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

#Preview {
    NavigationStack {
        AskClarityView()
    }
    .preferredColorScheme(.dark)
    .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self], inMemory: true)
}
