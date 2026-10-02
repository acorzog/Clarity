import SwiftUI
import SwiftData
import WidgetKit

/// A smaller hero-number style for Home's cards specifically — Home packs more cards on screen
/// than any other tab, so it uses this instead of the shared `heroAmountStyle()` (34pt, used by
/// Net Worth here and elsewhere in the app) to keep everything visible without scrolling on
/// smaller phones. Not a Design System token change — just a Home-local compactness choice.
private struct CompactHeroAmountStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 32, weight: .bold))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }
}

/// A `SectionCard`-equivalent surface with a low-opacity color wash layered over the standard
/// `surfaceSecondary` tier, so each Home card can carry its own accent identity (emerald for Safe
/// to Spend, sky blue for Clarity Score, mint for What's Different — all within the app's
/// existing green/blue accent range) while still sitting on the same flat, no-shadow surface
/// treatment (`CLARITY_DESIGN_SYSTEM.md` §10) as every other card in the app — the wash is a
/// translucent overlay, not a replacement color system.
private struct TintedSurfaceModifier: ViewModifier {
    var tint: Color
    var radius: CGFloat
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.surfaceSecondary)
                    .overlay(RoundedRectangle(cornerRadius: radius).fill(tint.opacity(0.08)))
            )
    }
}

private extension View {
    func compactHeroAmountStyle() -> some View {
        modifier(CompactHeroAmountStyle())
    }

    func claritySurface(tint: Color, radius: CGFloat = ClarityRadius.large, padding: CGFloat = ClaritySpacing.lg) -> some View {
        modifier(TintedSurfaceModifier(tint: tint, radius: radius, padding: padding))
    }
}

/// Clarity's "Understand" surface — see `CLARITY_HOME_SPEC.md`. Composes already-computed
/// values from `BudgetCalculator`, `HomeCalculator`, `NetWorthCalculator`, and
/// `ClarityScoreCalculator`; performs no financial calculation of its own (`CLARITY_HOME_SPEC.md`
/// §17/§13 — "HomeView must NOT become a calculation layer").
struct HomeView: View {
    /// Lets a Home section switch tabs on tap — the closest existing navigation behavior. Home's
    /// drill-downs land on each destination tab's root, not a specific sub-tab or scroll
    /// position: that would require converting `OverviewView`/`BudgetContentView`'s sub-tab
    /// state from view-local `@State` to an externally-driven `@Binding`, which is a larger
    /// change than this phase's "small, local changes" discipline allows. Documented as a known
    /// limitation rather than silently worked around.
    @Binding var selectedTab: MainTab

    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var budgetSettings = BudgetSettingsStore.shared
    @Query(sort: \Entry.date, order: .reverse) private var allEntries: [Entry]
    @Query private var allBudgets: [Budget]
    @Query(sort: \HeadCategory.sortOrder) private var headCategories: [HeadCategory]
    @Query(sort: \Category.name) private var allCategories: [Category]
    @Query(sort: \Wallet.sortOrder) private var allWallets: [Wallet]
    @Query(sort: \SharedEvent.createdAt, order: .reverse) private var sharedEvents: [SharedEvent]

    @StateObject private var voiceRecorder = VoiceExpenseRecorder()
    @State private var floatingMicOffset: CGSize = .zero
    @State private var floatingMicDragStart: CGSize = .zero
    @State private var isHoldingMic = false
    /// Set right after `VoiceQuickSave.save` succeeds — drives the confirmation toast. Voice
    /// input saves immediately (no review sheet); this is the only feedback the person gets
    /// besides checking Entries themselves, so it also doubles as the "tap to edit" affordance
    /// for a single saved entry.
    @State private var voiceQuickSaveEntries: [Entry]?
    /// Bumped on every new toast so its auto-dismiss timer can tell a later toast apart from
    /// itself — same reasoning as `voiceHoldSessionID` below.
    @State private var voiceQuickSaveToastSessionID = UUID()
    /// The single saved entry to open for correction when the person taps the confirmation toast.
    @State private var editingVoiceSavedEntry: Entry?
    /// Minimum drag distance (points) before a hold-to-record touch is treated as an intentional
    /// reposition of the floating mic — see `floatingVoiceMic`'s gesture.
    private static let dragRepositionThreshold: CGFloat = 16
    /// Toggled by the mic's `.onChange(of: isHoldingMic)` to drive the repeating pulse-ring
    /// animation — a plain `Bool` (not derived from `isHoldingMic` directly) because SwiftUI
    /// needs a value transition to actually start a `.repeatForever` animation.
    @State private var micPulseRingExpanded = false
    /// User-facing feedback for a recording that produced *some* transcript but nothing
    /// `VoiceExpenseParser` could turn into an expense — distinct from `voiceRecorder.
    /// errorMessage` (a permission/engine failure). Cleared at the start of every new hold.
    @State private var voiceFeedbackMessage: String?
    /// Set inside `voiceRecorder.onFinalTranscript` the moment it fires for the current session
    /// (whether parsing succeeded or not) — lets `.onEnded`'s bounded fallback below tell "Speech
    /// genuinely produced nothing at all" apart from "already handled," without adding any signal
    /// to `VoiceExpenseRecorder` itself. Reset at the start of every new hold.
    @State private var didHandleFinalTranscript = false
    /// Bumped on every new hold so `.onEnded`'s bounded fallback (below) can tell its own session
    /// apart from a later one — without this, starting a new hold within the fallback's 2.5s
    /// window would reset `didHandleFinalTranscript` for the *new* session, and the *old*
    /// session's still-pending fallback would misread that reset as "nothing was heard."
    @State private var voiceHoldSessionID = UUID()

    /// Whether the mic has been released and `VoiceExpenseRecorder` is winding the session down —
    /// Speech may still be finishing recognition, or the bounded timeout fallback may still be
    /// pending. Drives the "Processing" state between "Listening" and a result, entirely from
    /// `voiceRecorder.phase` (see `VoiceRecordingPhase`); nothing here duplicates or reimplements
    /// that state.
    private var isProcessingVoice: Bool {
        voiceRecorder.phase.isProcessing
    }

    /// A single, combined trigger for the overlay's show/hide animation — previously
    /// `isHoldingMic` and `isProcessingVoice` each drove their own `.animation(value:)` on the
    /// same view, and since a mic release flips both within the same frame, the two competing
    /// implicit animations could both start at once and visibly overlap/blend the outgoing and
    /// incoming state's text on screen.
    private var isVoiceOverlayVisible: Bool {
        isHoldingMic || isProcessingVoice
    }

    private var month: Date { Date.startOfMonth() }

    private var calculationSettings: BudgetCalculationSettings {
        BudgetCalculationSettings(from: budgetSettings)
    }

    /// The same shared calculation `RemainingView`/`InsightsView`/`BudgetGaugeWidget` use — see
    /// `BudgetCalculator.periodSpendingSummary`. Safe to Spend, in V1, is exactly `totalLeft` —
    /// see `CLARITY_HOME_SPEC.md` §5 for why a forward-looking adjustment isn't implemented yet.
    private var summary: PeriodSpendingSummary {
        BudgetCalculator.periodSpendingSummary(
            month: month, entries: allEntries, budgets: allBudgets, headCategories: headCategories,
            settings: calculationSettings, respectHiddenCategories: true
        )
    }

    private var hasBudgetData: Bool {
        summary.totalAvailable > 0 || summary.totalSpent > 0
    }

    /// Mirrors `GaugeThreshold`'s own thresholds (1.0, 0.85) so this status text can never
    /// disagree with the dot/number color it sits next to, which is colored via `GaugeThreshold`
    /// directly.
    private var safeToSpendRatio: Double {
        guard summary.totalAvailable > 0 else { return 0 }
        return (summary.totalSpent / summary.totalAvailable).doubleValue
    }

    private var safeToSpendColor: Color {
        guard summary.totalAvailable > 0 else { return .textSecondary }
        return GaugeThreshold.color(forProgress: safeToSpendRatio)
    }

    private var safeToSpendStatusText: String {
        guard summary.totalAvailable > 0 else { return "" }
        if safeToSpendRatio > 1 { return "Over budget" }
        if safeToSpendRatio >= 0.85 { return "Getting close to budget" }
        return "On track"
    }

    private var periodRangeText: String {
        let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: summary.period.end) ?? summary.period.end
        return "Through \(lastDay.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private var clarityScoreResult: ClarityScoreResult {
        ClarityScoreCalculator.clarityScore(entries: allEntries, budgets: allBudgets, headCategories: headCategories)
    }

    private var whatsDifferentInsights: [WhatsDifferentInsight] {
        HomeCalculator.whatsDifferentInsights(
            month: month, entries: allEntries, budgets: allBudgets, headCategories: headCategories,
            settings: calculationSettings
        )
    }

    private var upcomingItems: [UpcomingSharedBalance] {
        HomeCalculator.upcomingSharedBalances(events: sharedEvents)
    }

    private var isEffectivelyEmpty: Bool {
        allEntries.isEmpty && allWallets.isEmpty && allBudgets.isEmpty && sharedEvents.isEmpty
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: ClaritySpacing.lg) {
                            header
                                .padding(.bottom, ClaritySpacing.xs)
                            safeToSpendSection
                            clarityScoreSection
                            whatsDifferentSection
                            upcomingSection
                        }
                        .padding(.horizontal)
                        .padding(.top, 4)
                        // Leave enough room to keep the last card readable behind the
                        // bottom-centered floating microphone.
                        .padding(.bottom, 96)
                        .readableContentWidth()
                    }

                    if isVoiceOverlayVisible {
                        voiceListeningOverlay
                            .transition(.opacity)
                            .zIndex(1)
                    }

                    if let savedEntries = voiceQuickSaveEntries {
                        voiceQuickSaveToast(for: savedEntries)
                            .frame(maxWidth: .infinity, alignment: .top)
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(3)
                    }

                    floatingVoiceMic(in: geometry.size)
                        .zIndex(2)
                }
                .animation(.easeInOut(duration: 0.2), value: isVoiceOverlayVisible)
                .animation(.easeInOut(duration: 0.2), value: voiceQuickSaveEntries != nil)
            }
            .refreshable { await DataSyncService.refresh(modelContext) }
            .darkScreenBackground()
        }
        .sheet(item: $editingVoiceSavedEntry) { entry in
            AddTransactionView(entry: entry)
        }
        .onAppear {
            // Only the recognizer's *final* transcript should ever save an expense — see
            // `VoiceExpenseRecorder.onFinalTranscript`'s doc comment. Wiring this here (rather
            // than `.onChange(of: voiceRecorder.transcript)`) also removes the need for any fixed
            // delay after releasing the mic: this fires exactly when Speech's own final result
            // arrives, however long that takes.
            voiceRecorder.onFinalTranscript = { transcript in
                didHandleFinalTranscript = true
                let expenses = VoiceExpenseParser.parseAll(transcript)
                guard !expenses.isEmpty else {
                    voiceFeedbackMessage = "Didn't catch an expense in that — try saying an amount and what it was for, like \"20 euros on taxi.\""
                    return
                }
                guard let savedEntries = VoiceQuickSave.save(
                    expenses, wallet: Wallet.preferredFallback(among: allWallets), categories: allCategories, modelContext: modelContext
                ) else {
                    voiceFeedbackMessage = "Set up an account in Clarity before saving expenses."
                    return
                }
                voiceFeedbackMessage = nil
                showVoiceQuickSaveToast(for: savedEntries)
            }
        }
    }

    /// Shows the confirmation toast for `entries` and schedules its auto-dismiss — bounded by a
    /// session ID (the same pattern as `voiceHoldSessionID` above) so a second voice save that
    /// lands while an earlier toast's timer is still pending can't have its own toast dismissed
    /// early by the stale timer.
    private func showVoiceQuickSaveToast(for entries: [Entry]) {
        voiceQuickSaveEntries = entries
        let sessionID = UUID()
        voiceQuickSaveToastSessionID = sessionID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard voiceQuickSaveToastSessionID == sessionID else { return }
            voiceQuickSaveEntries = nil
        }
    }

    // MARK: - Press-to-record floating microphone

    /// A full-screen, Siri-style focus layer shown while holding the mic *and* while
    /// `isProcessingVoice` — a dim scrim, a soft glow that breathes with `voiceRecorder.audioLevel`
    /// while actually listening, and a status label + large text that switches between three
    /// states (listening, processing, can't-listen) driven only by `voiceRecorder.phase`/
    /// `errorMessage` — never solely by color, so the state reads correctly under VoiceOver and
    /// without relying on the glow animation. Purely presentational and non-interactive
    /// (`allowsHitTesting(false)`); the mic button itself, drawn above this in `body`'s `ZStack`,
    /// is still what the gesture is attached to.
    private var voiceListeningOverlay: some View {
        ZStack {
            // Strong enough that whatever card is behind it (the Clarity Score number, "What's
            // Different" rows, …) is never legible through it — a lighter scrim previously let
            // background text bleed through and visually collide with the status text above it.
            Color.black.opacity(0.82)
                .ignoresSafeArea()

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.emerald.opacity(0.4), Color.emerald.opacity(0)],
                        center: .center, startRadius: 10, endRadius: 220
                    )
                )
                .frame(width: 440, height: 440)
                .scaleEffect(1 + voiceRecorder.audioLevel * 0.12)
                .animation(.easeOut(duration: 0.12), value: voiceRecorder.audioLevel)
                .blur(radius: 12)

            // Each state below carries its own `.id`, so SwiftUI always treats a state change
            // (listening → processing → can't-listen) as swapping in a whole new view rather than
            // cross-fading/morphing individual subviews that happen to share a position — the
            // latter is what produced overlapping, double-exposed text when two states' content
            // briefly rendered on top of each other during a transition.
            Group {
                if let errorMessage = voiceRecorder.errorMessage {
                    // A permission denial can resolve while the button is still physically held
                    // down (the authorization prompts are async) — surface it here immediately
                    // rather than only after release, same as the form's inline control already did.
                    VStack(spacing: ClaritySpacing.xl) {
                        Label("Can't listen", systemImage: "mic.slash.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.expense)
                        Text(errorMessage)
                            .font(.system(size: 22, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.textPrimary)
                    }
                    .id("error")
                } else if isProcessingVoice {
                    // Shown the moment the mic is released — the capture has definitively ended,
                    // even though Speech (or the bounded fallback) may take a moment longer to
                    // resolve. The spinner is a secondary cue only; "Processing" in text is the
                    // actual signal, so this reads correctly without it too.
                    VStack(spacing: ClaritySpacing.xl) {
                        Label("Processing", systemImage: "hourglass")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LinearGradient.emeraldSky)
                        ProgressView()
                            .tint(Color.emerald)
                        Text("Making sense of what you said…")
                            .font(.system(size: 22, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .id("processing")
                } else {
                    VStack(spacing: ClaritySpacing.xl) {
                        Label("Listening", systemImage: "waveform")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LinearGradient.emeraldSky)

                        Text(voiceRecorder.transcript.isEmpty ? "Say an amount and what it was for…" : voiceRecorder.transcript)
                            .font(.system(size: 30, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(voiceRecorder.transcript.isEmpty ? Color.textTertiary : Color.textPrimary)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .id("listening")
                }
            }
            // A solid card behind the status text, independent of the scrim above — guarantees
            // legibility no matter what's behind it, and gives the status a real, visible
            // boundary instead of just floating text (the "text box doesn't render" the person
            // saw was this content with nothing anchoring or grounding it).
            .padding(.vertical, ClaritySpacing.xxl)
            .padding(.horizontal, ClaritySpacing.xl)
            .background(Color.surfaceSecondary.opacity(0.96), in: RoundedRectangle(cornerRadius: 28))
            .padding(.horizontal, ClaritySpacing.xl)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceOverlayAccessibilityLabel)
    }

    /// A single, explicit announcement per state — kept separate from the visual layout above so
    /// VoiceOver always describes exactly which of the three states is active, not just whatever
    /// text happens to be on screen.
    private var voiceOverlayAccessibilityLabel: String {
        if let errorMessage = voiceRecorder.errorMessage {
            return "Can't listen. \(errorMessage)"
        }
        if isProcessingVoice {
            return "Processing what you said"
        }
        return voiceRecorder.transcript.isEmpty
            ? "Listening. Say an amount and what it was for."
            : "Listening. Heard so far: \(voiceRecorder.transcript)"
    }

    @ViewBuilder
    private func floatingVoiceMic(in size: CGSize) -> some View {
        let restingPosition = CGPoint(x: size.width / 2, y: size.height - 52)
        let position = CGPoint(
            x: min(max(restingPosition.x + floatingMicOffset.width, 36), size.width - 36),
            y: min(max(restingPosition.y + floatingMicOffset.height, 44), size.height - 44)
        )

        ZStack {
            // Feedback shown *after* release — the listening overlay above already covers a
            // permission error surfaced mid-hold; this covers it lingering afterward, plus
            // `voiceFeedbackMessage` (empty/unparseable speech), which can only ever be known
            // once the hold has ended.
            if !isHoldingMic, let message = voiceRecorder.errorMessage ?? voiceFeedbackMessage {
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(width: 240)
                .background(Color.surfaceSecondary.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.expense.opacity(0.35)))
                .offset(y: -78)
                .transition(.opacity)
                .accessibilityLabel(message)
            }

            // A classic "recording" pulse: a ring that continuously expands and fades while
            // listening — layered under the reactive breathing scale below for a fuller,
            // Siri-like sense of activity rather than a single static circle.
            if isHoldingMic {
                Circle()
                    .stroke(Color.emerald.opacity(0.55), lineWidth: 2)
                    .frame(width: 62, height: 62)
                    .scaleEffect(micPulseRingExpanded ? 1.7 : 1)
                    .opacity(micPulseRingExpanded ? 0 : 0.7)
                    .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: micPulseRingExpanded)
            }

            // The icon itself changes (not just the surrounding color) while processing, so the
            // state is legible without relying on color or the pulse animation — see the type's
            // own doc comment on avoiding color/animation-only state.
            Image(systemName: isProcessingVoice ? "hourglass" : "mic.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .background(
                    Circle().fill(Color.emerald)
                        .shadow(color: Color.emerald.opacity(0.5), radius: isHoldingMic ? 16 : 8)
                )
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                // Breathes with real input volume while recording — the same Siri-like reactive
                // feel as the glow above, tied to the same `audioLevel` reading.
                .scaleEffect(isHoldingMic ? 1 + voiceRecorder.audioLevel * 0.16 : 1)
                .animation(.easeOut(duration: 0.09), value: voiceRecorder.audioLevel)
        }
        .contentShape(Circle())
        .position(position)
        .accessibilityLabel(isHoldingMic ? "Recording" : (isProcessingVoice ? "Processing" : "Hold to record an expense"))
        .accessibilityHint("Hold while saying an amount and merchant. Release to review the transaction.")
        // `isHoldingMic` flips synchronously the instant a touch begins/ends, independent of any
        // async permission/engine work — an immediate tactile confirmation that the press
        // registered, on both press and release, rather than waiting for recording to actually
        // start (which was the main source of "nothing is happening" lag).
        .sensoryFeedback(.impact(weight: .light), trigger: isHoldingMic)
        .onChange(of: isHoldingMic) { _, holding in micPulseRingExpanded = holding }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isHoldingMic {
                        isHoldingMic = true
                        voiceQuickSaveEntries = nil
                        voiceFeedbackMessage = nil
                        didHandleFinalTranscript = false
                        voiceHoldSessionID = UUID()
                        floatingMicDragStart = floatingMicOffset
                        voiceRecorder.startRecording()
                    }
                    // The same hold gesture makes the control movable, but natural hand tremor
                    // while holding to talk means the touch point is essentially never at
                    // literally zero movement — without a small dead zone, every ordinary
                    // recording would also nudge the button. Only treat this as an intentional
                    // drag once the finger has moved past that dead zone.
                    let translation = value.translation
                    let distance = (translation.width * translation.width + translation.height * translation.height).squareRoot()
                    guard distance > Self.dragRepositionThreshold else { return }
                    floatingMicOffset = CGSize(
                        width: floatingMicDragStart.width + translation.width,
                        height: floatingMicDragStart.height + translation.height
                    )
                }
                .onEnded { _ in
                    isHoldingMic = false
                    voiceRecorder.stopRecording()
                    // `voiceRecorder.onFinalTranscript` (set in `.onAppear` above) opens the
                    // review sheet itself once Speech's real final result arrives — no fixed
                    // delay/guess here, so a slow finalization can never silently drop the
                    // recorded expense.
                    //
                    // The one thing that callback can never cover is total silence: `deliver
                    // FinalTranscriptIfNeeded` inside `VoiceExpenseRecorder` never fires at all
                    // when the transcript stayed empty (there's nothing to hand back), and its
                    // own bounded fallback resolves within 2 seconds whenever there *is* some
                    // text. Waiting strictly longer than that here — without touching the
                    // recorder itself — safely distinguishes "nothing was ever recognized" from
                    // "still being handled," and only then shows feedback.
                    let sessionID = voiceHoldSessionID
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2.5))
                        guard voiceHoldSessionID == sessionID, !didHandleFinalTranscript else { return }
                        didHandleFinalTranscript = true
                        voiceFeedbackMessage = "I didn't hear anything — hold the mic and try again."
                    }
                }
        )
    }

    /// Confirms a voice save without requiring a tap — the whole point of skipping the review
    /// sheet. Tapping it still opens the normal edit form for a single saved entry, since that's
    /// the one case a quick correction (wrong category, wrong wallet) is a single well-defined
    /// action; a multi-entry save just names the count and lets the person find the entries
    /// themselves, matching the review-later workflow this feature is meant to enable.
    private func voiceQuickSaveToast(for entries: [Entry]) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { voiceQuickSaveEntries = nil }
            if entries.count == 1 { editingVoiceSavedEntry = entries.first }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.emerald)
                VStack(alignment: .leading, spacing: 2) {
                    Text(voiceQuickSaveSummary(for: entries))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                    if entries.count == 1 {
                        Text("Tap to edit")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(14)
            .background(Color.surfaceSecondary.opacity(0.98), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.emerald.opacity(0.25)))
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(voiceQuickSaveSummary(for: entries) + (entries.count == 1 ? ", tap to edit" : ""))
    }

    private func voiceQuickSaveSummary(for entries: [Entry]) -> String {
        guard entries.count == 1, let only = entries.first else {
            return "Saved \(entries.count) transactions"
        }
        let label = only.note.isEmpty ? (only.category?.name ?? "Uncategorized") : only.note
        return "Saved \(only.amount.currencyFormatted) — \(label)"
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: ClaritySpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.subheadline)
                    .foregroundStyle(.textSecondary)
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.textPrimary)

                if isEffectivelyEmpty {
                    Text("Add a transaction or two, and Home will start filling in.")
                        .font(.footnote)
                        .foregroundStyle(.textTertiary)
                        .padding(.top, ClaritySpacing.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NavigationLink {
                AskClarityView()
            } label: {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.title3)
                    .foregroundStyle(LinearGradient.emeraldSky)
                    .frame(width: 44, height: 44)
                    .background(Color.surfaceSecondary, in: Circle())
            }
            .accessibilityLabel("Ask Clarity")
            .accessibilityHint("Double tap to start a conversation about your finances")
        }
    }

    // MARK: - Safe to Spend (hero)

    /// Fraction of `totalAvailable` spent, clamped to `0...1` for the progress bar's fill width —
    /// `safeToSpendRatio` itself is allowed to exceed 1 (over budget), but a bar can't render past
    /// its own track.
    private var safeToSpendProgress: Double {
        min(max(safeToSpendRatio, 0), 1)
    }

    private var spentPercentText: String {
        guard summary.totalAvailable > 0 else { return "0%" }
        return safeToSpendRatio.formatted(.percent.precision(.fractionLength(0)))
    }

    private var leftPercentText: String {
        guard summary.totalAvailable > 0 else { return "0%" }
        return max(1 - safeToSpendRatio, 0).formatted(.percent.precision(.fractionLength(0)))
    }

    private var safeToSpendPerDay: Decimal? {
        HomeCalculator.averageDailyAllowance(totalLeft: summary.totalLeft, periodEnd: summary.period.end)
    }

    private var safeToSpendSection: some View {
        Button {
            selectedTab = .plan
        } label: {
            VStack(alignment: .leading, spacing: ClaritySpacing.md) {
                HStack(spacing: ClaritySpacing.sm) {
                    ZStack {
                        Circle().fill(Color.income.opacity(0.18))
                        Image(systemName: "wallet.bifold.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.income)
                    }
                    .frame(width: 28, height: 28)

                    Text("SAFE TO SPEND")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(.textSecondary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.textTertiary)
                }

                if hasBudgetData {
                    HStack(alignment: .top, spacing: ClaritySpacing.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.totalLeft.currencyFormatted)
                                .compactHeroAmountStyle()
                                .foregroundStyle(summary.totalLeft < 0 ? Color.expense : Color.textPrimary)

                            Text(periodRangeText)
                                .font(.caption2)
                                .foregroundStyle(.textTertiary)
                        }

                        Spacer(minLength: ClaritySpacing.sm)

                        if let safeToSpendPerDay {
                            VStack(spacing: 2) {
                                HStack(spacing: 4) {
                                    Image(systemName: "calendar")
                                        .font(.caption2)
                                    Text("≈ \(safeToSpendPerDay.currencyFormattedSummary)")
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.textPrimary)
                                Text("per day")
                                    .font(.caption2)
                                    .foregroundStyle(.textTertiary)
                            }
                            .padding(.horizontal, ClaritySpacing.sm)
                            .padding(.vertical, ClaritySpacing.sm)
                            .background(Color.surfaceElevated, in: RoundedRectangle(cornerRadius: ClarityRadius.medium))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("About \(safeToSpendPerDay.currencyFormattedSummary) available per day")
                        }
                    }

                    HStack(spacing: ClaritySpacing.xs) {
                        Circle().fill(safeToSpendColor).frame(width: 7, height: 7)
                        Text(safeToSpendStatusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.textSecondary)
                        // A quiet, secondary caveat — see CLARITY_HOME_SPEC.md §5/§20: V1 is
                        // budget-position only, so this must not imply forward-looking awareness
                        // (upcoming bills) it doesn't have. Never the primary message; kept on the
                        // same line as the status dot to stay out of the way visually.
                        Text("· Based on this period's budget")
                            .font(.caption2)
                            .foregroundStyle(.textTertiary)
                            .lineLimit(1)
                    }

                    ClarityProgressBar(progress: safeToSpendProgress, color: safeToSpendColor)
                        .padding(.top, 2)

                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(summary.totalSpent.currencyFormattedSummary) spent")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.textPrimary)
                            Text("\(spentPercentText) of \(summary.totalAvailable.currencyFormattedSummary)")
                                .font(.caption2)
                                .foregroundStyle(.textTertiary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(summary.totalLeft.currencyFormattedSummary) left")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.textPrimary)
                            Text("\(leftPercentText) remaining")
                                .font(.caption2)
                                .foregroundStyle(.textTertiary)
                        }
                    }
                } else {
                    Text("Set a budget to see what's safe to spend")
                        .font(.subheadline)
                        .foregroundStyle(.textSecondary)
                        .padding(.top, ClaritySpacing.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .claritySurface(tint: .income, radius: ClarityRadius.large, padding: ClaritySpacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(safeToSpendAccessibilityLabel)
        .accessibilityHint("Double tap to view your budget")
    }

    private var safeToSpendAccessibilityLabel: String {
        guard hasBudgetData else { return "Safe to spend: set a budget to see what's safe to spend" }
        return "Safe to spend: \(summary.totalLeft.currencyFormatted), \(safeToSpendStatusText.lowercased())"
    }

    // MARK: - Clarity Score

    private var clarityScoreTrendBadge: (delta: String, direction: DeltaIndicator.Direction, isFavorable: Bool?)? {
        switch clarityScoreResult.trend {
        case .up: ("+\(clarityScoreResult.pointsChange ?? 0)", .up, true)
        case .down: ("\(clarityScoreResult.pointsChange ?? 0)", .down, false)
        case .stable: ("±0", .flat, nil)
        case .notEnoughHistory: nil
        }
    }

    /// Builds the actual phrasing for a factor from its raw data — `ClarityScoreCalculator`
    /// deliberately returns numbers, not sentences, so this (and not the calculator) owns the
    /// wording, matching `WhatsDifferentRow.message`'s split of data vs. phrasing.
    private func clarityScoreFactorTitle(_ factor: ClarityScoreFactor) -> String {
        let percent = factor.magnitudeFraction.formatted(.percent.precision(.fractionLength(0)))
        return switch factor.kind {
        case .budgetPace: factor.isFavorable ? "\(percent) under your weekly budget pace" : "\(percent) over your weekly budget pace"
        case .previousWeek: factor.isFavorable ? "\(percent) lower than last week" : "\(percent) higher than last week"
        case .typicalWeek: factor.isFavorable ? "\(percent) below your typical week" : "\(percent) above your typical week"
        case .monthOverMonth: factor.isFavorable ? "\(percent) lower than this point last month" : "\(percent) higher than this point last month"
        }
    }

    /// Short (1-2 word) label for the compact factor strip beneath the score — the sentence-level
    /// phrasing belongs to `clarityScoreFactorTitle`/`clarityScoreSummary` above; this exists only
    /// so `clarityScoreFactorsStrip` can lay out a percent + label pair per factor without
    /// truncating a full sentence.
    private func clarityScoreFactorShortLabel(_ factor: ClarityScoreFactor) -> String {
        switch factor.kind {
        case .budgetPace: "budget pace"
        case .previousWeek: "last week"
        case .typicalWeek: "typical week"
        case .monthOverMonth: "last month"
        }
    }

    /// True once the score reflects at least one real comparison — either a factor that actually
    /// contributed this week, or a genuine week-ago score to compare against (which itself
    /// requires real spend data at that anchor, not just a budget's existence — see
    /// `ClarityScoreCalculator.snapshot`). False only for the plain `baselineScore` default with
    /// zero comparisons available (e.g. a brand-new user's very first days), which must not be
    /// shown as if it were an actual measure of financial health.
    private var clarityScoreHasSignal: Bool {
        !clarityScoreResult.factors.isEmpty || clarityScoreResult.trend != .notEnoughHistory
    }

    private var clarityScoreSummary: String {
        guard clarityScoreResult.score != nil else {
            return "Log a few expenses this week to start seeing your Clarity Score."
        }
        guard clarityScoreHasSignal else {
            return "Your Clarity Score will get more precise as you add more transaction history."
        }
        guard let topFactor = clarityScoreResult.factors.first else {
            return "Spending is right in line with your usual pattern."
        }
        let trendPhrase = switch clarityScoreResult.trend {
        case .up: "Your score improved this week"
        case .down: "Your score dipped this week"
        case .stable: "Your score held steady this week"
        case .notEnoughHistory: "Here's your Clarity Score"
        }
        return "\(trendPhrase) — \(clarityScoreFactorTitle(topFactor))."
    }

    private var clarityScoreAccessibilityLabel: String {
        guard let score = clarityScoreResult.score, clarityScoreHasSignal else {
            return "Clarity Score. \(clarityScoreSummary)"
        }
        return "Clarity Score: \(score) out of 100, \(clarityScoreTierLabel ?? ""). \(clarityScoreSummary)"
    }

    /// A coarse, presentation-only reading of the 0-100 score — same "the view owns the wording,
    /// not the calculator" split as `clarityScoreFactorTitle` above. Deliberately simple (3
    /// buckets); this is a glance-level label, not a new scoring system.
    private var clarityScoreTierLabel: String? {
        guard let score = clarityScoreResult.score, clarityScoreHasSignal else { return nil }
        switch score {
        case 70...: return "Good"
        case 40..<70: return "Fair"
        default: return "Needs focus"
        }
    }

    private var clarityScoreTierColor: Color {
        guard let score = clarityScoreResult.score else { return .textSecondary }
        switch score {
        case 70...: return .income
        case 40..<70: return .warning
        default: return .expense
        }
    }

    private var clarityScoreSection: some View {
        VStack(alignment: .leading, spacing: ClaritySpacing.md) {
            HStack(spacing: ClaritySpacing.sm) {
                ZStack {
                    Circle().fill(Color.skyBlue.opacity(0.18))
                    Image(systemName: "chart.bar.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.skyBlue)
                }
                .frame(width: 32, height: 32)

                Text("CLARITY SCORE")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.textSecondary)

                Spacer()

                if let badge = clarityScoreTrendBadge {
                    DeltaIndicator(delta: badge.delta, direction: badge.direction, isFavorable: badge.isFavorable)
                }
            }

            if let score = clarityScoreResult.score, clarityScoreHasSignal {
                HStack(alignment: .center, spacing: ClaritySpacing.sm) {
                    Text("\(score)")
                        .compactHeroAmountStyle()
                        .foregroundStyle(.textPrimary)

                    if let clarityScoreTierLabel {
                        Text(clarityScoreTierLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(clarityScoreTierColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(clarityScoreTierColor.opacity(0.16), in: Capsule())
                    }
                }
            }

            Text(clarityScoreSummary)
                .font(.caption)
                .foregroundStyle(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !clarityScoreResult.factors.isEmpty {
                Rectangle()
                    .fill(Color.surfaceSecondary)
                    .frame(height: 1)

                HStack(alignment: .top, spacing: ClaritySpacing.md) {
                    ForEach(clarityScoreResult.factors) { factor in
                        VStack(alignment: .leading, spacing: 1) {
                            DeltaIndicator(
                                delta: factor.magnitudeFraction.formatted(.percent.precision(.fractionLength(0))),
                                direction: factor.isFavorable ? .down : .up,
                                isFavorable: factor.isFavorable
                            )
                            Text(clarityScoreFactorShortLabel(factor))
                                .font(.caption2)
                                .foregroundStyle(.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(clarityScoreFactorTitle(factor))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .claritySurface(tint: .skyBlue, padding: ClaritySpacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(clarityScoreAccessibilityLabel)
    }

    // MARK: - What's Different?

    /// Where a tap on a given insight should land — category/over-plan/pace insights explain
    /// themselves at Plan → Budget; the income insight is a cash-flow fact, closest to Overview's
    /// Income/Expenses card.
    private func handleInsightTap(_ kind: WhatsDifferentKind) {
        selectedTab = kind == .incomeChange ? .overview : .plan
    }

    @ViewBuilder
    private var whatsDifferentSection: some View {
        if !allEntries.isEmpty {
            VStack(alignment: .leading, spacing: ClaritySpacing.md) {
                HStack(spacing: ClaritySpacing.sm) {
                    ZStack {
                        Circle().fill(Color.indigo.opacity(0.18))
                        Image(systemName: "questionmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.indigo)
                    }
                    .frame(width: 32, height: 32)

                    Text("WHAT'S DIFFERENT?")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(.textSecondary)

                    Spacer()

                    if !whatsDifferentInsights.isEmpty {
                        NavigationLink {
                            // `InsightsView`'s own body is a bare `VStack` — it expects to sit
                            // inside a scrolling container, matching every other pushed detail
                            // screen in the app (e.g. `GoalDetailView`). Pushing it bare here
                            // previously froze the screen: `.darkScreenBackground()`'s
                            // `.ignoresSafeArea()` + fixed frame with no `ScrollView` above it
                            // left content stuck with no way to reach what scrolled off-screen.
                            ScrollView {
                                InsightsView(month: month)
                            }
                            .darkScreenBackground()
                            .navigationTitle("Insights")
                        } label: {
                            HStack(spacing: 2) {
                                Text("See all")
                                Image(systemName: "chevron.right")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.emerald)
                        }
                    }
                }

                if whatsDifferentInsights.isEmpty {
                    Text("Nothing stands out this period")
                        .font(.subheadline)
                        .foregroundStyle(.textTertiary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(whatsDifferentInsights.enumerated()), id: \.element.id) { index, insight in
                            if index > 0 {
                                Rectangle()
                                    .fill(Color.surfaceSecondary)
                                    .frame(height: 1)
                                    .padding(.leading, 44)
                            }
                            Button {
                                handleInsightTap(insight.kind)
                            } label: {
                                WhatsDifferentRow(insight: insight)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, ClaritySpacing.xs)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .claritySurface(tint: .indigo, padding: ClaritySpacing.md)
        }
    }

    // MARK: - Upcoming

    @ViewBuilder
    private var upcomingSection: some View {
        if !upcomingItems.isEmpty {
            // Same `.secondary` lightweight-surface tier as What's Different — both occupy the
            // SECONDARY hierarchy tier per CLARITY_HOME_SPEC.md §2 and should share one visual
            // weight. See CLARITY_HOME_VISUAL_SPEC.md §6.
            SectionCard(tier: .secondary, padding: ClaritySpacing.lg) {
                VStack(alignment: .leading, spacing: ClaritySpacing.sm) {
                    Text("Upcoming")
                        .font(.sectionTitle)
                        .foregroundStyle(.textSecondary)

                    VStack(spacing: ClaritySpacing.sm) {
                        ForEach(Array(upcomingItems.prefix(HomeCalculator.maxUpcomingItems))) { item in
                            Button {
                                selectedTab = .more
                            } label: {
                                UpcomingRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if upcomingItems.count > HomeCalculator.maxUpcomingItems {
                        Button("See all") {
                            selectedTab = .more
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.emerald)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }


}

// MARK: - Row subviews

/// The linear budget-progress track shown inside Safe to Spend — a thin, flat capsule (no
/// shadow/glow, matching `CLARITY_DESIGN_SYSTEM.md` §10's "no `.shadow(...)` calls" rule).
/// Presentation-only: takes an already-clamped `0...1` fraction and a color the caller derives
/// from `GaugeThreshold`, so it can never disagree with the status dot/text next to it.
private struct ClarityProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.surfaceElevated)
                Capsule().fill(color)
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 8)
    }
}

private struct WhatsDifferentRow: View {
    let insight: WhatsDifferentInsight

    /// Falls back to `.info` (the shared "neutral highlight" token) for `.incomeChange`/
    /// `.overPace`, which aren't tied to a single category and so have no category color.
    private var color: Color {
        insight.headCategory.map { Color(hex: $0.colorHex) } ?? .info
    }

    private var iconName: String {
        insight.headCategory?.icon ?? (insight.kind == .incomeChange ? "banknote.fill" : "gauge.with.needle.fill")
    }

    private var title: String {
        insight.subject.isEmpty ? "Budget pace" : insight.subject
    }

    private var statusText: String {
        switch insight.kind {
        case .categoryChange, .incomeChange:
            return insight.direction == .up ? "Higher than last month" : "Lower than last month"
        case .overPlan:
            return "Over plan"
        case .overPace:
            return "You're on pace to exceed this period's budget"
        }
    }

    private var amountText: String? {
        guard let amount = insight.amountDifference else { return nil }
        return "\(amount >= 0 ? "+" : "-")\(abs(amount).currencyFormattedSummary)"
    }

    private var percentText: String? {
        insight.magnitudeFraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }
    }

    private var accessibilityLabel: String {
        [title, statusText, amountText, percentText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: ClaritySpacing.md) {
            ZStack {
                Circle().fill(color.opacity(0.18))
                Image(systemName: iconName)
                    .foregroundStyle(color)
                    .font(.caption)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.textPrimary)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: ClaritySpacing.sm)

            VStack(alignment: .trailing, spacing: 2) {
                if let amountText {
                    Text(amountText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(insight.isFavorable == true ? Color.income : Color.expense)
                }
                if let percentText {
                    DeltaIndicator(
                        delta: percentText,
                        direction: insight.direction == .up ? .up : .down,
                        isFavorable: insight.isFavorable
                    )
                } else if insight.kind == .overPace {
                    Text("Ahead of pace")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.warning)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct UpcomingRow: View {
    let item: UpcomingSharedBalance

    private var color: Color { item.event.colorHex.map { Color(hex: $0) } ?? .skyBlue }

    var body: some View {
        HStack(spacing: ClaritySpacing.md) {
            ZStack {
                Circle().fill(color.opacity(0.18))
                Image(systemName: item.event.icon ?? "person.2.fill")
                    .foregroundStyle(color)
                    .font(.subheadline)
            }
            .frame(width: 32, height: 32)

            Text(item.event.title)
                .font(.body)
                .foregroundStyle(.textPrimary)
                .lineLimit(1)

            Spacer()

            CurrencyValue(
                amount: abs(item.amount).currencyFormatted,
                kind: item.amount > 0 ? .income : .expense
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.event.title), \(item.amount > 0 ? "you are owed" : "you owe") \(abs(item.amount).currencyFormatted)"
        )
    }
}

#Preview {
    HomeView(selectedTab: .constant(.home))
        .modelContainer(for: [HeadCategory.self, Category.self, Wallet.self, Entry.self, Budget.self, Person.self, SharedEvent.self], inMemory: true)
}
