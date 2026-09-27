# Implementation Log

A running record of implementations made with Claude, in the order they happened, so each one can
be reviewed independently. New entries get appended at the bottom — don't reorder or rewrite past
ones; if something changes later, add a new entry that says so rather than editing history here.

---

## 1. Nav bar restructure: Wallets promoted, Shared moved to More

**Date:** 2026-09-24

**Files changed:**
- `FinanceTracker/Views/MainTabView.swift`
- `FinanceTracker/Views/ToolsView.swift`
- `FinanceTracker/Views/HomeView.swift`
- `FinanceTrackerUITests/TabNavigationUITests.swift`
- `FinanceTrackerUITests/WalletManagementUITests.swift`

**Summary:**
Swapped the bottom nav bar's Shared and Accounts tabs. Accounts (renamed **Wallets** in the tab
bar) is now a top-level tab again instead of living under More. Shared — called out as not yet
fully developed — moved into the More menu in its place. Updated Home screen drill-down taps (Net
Worth card now jumps to Wallets; the Upcoming/shared-events card now jumps to More) and the UI
tests that asserted on the old tab layout.

**Testing:** Full app build succeeded. Updated UI tests reflect the new tab structure (not run in
this session — no simulator UI pass, just build verification).

---

## 2. Wallets tab icon: `wallet.pass.fill` → `wallet.bifold.fill`

**Date:** 2026-09-24

**Files changed:**
- `FinanceTracker/Views/MainTabView.swift`

**Summary:**
Swapped the Wallets tab's SF Symbol from `wallet.pass.fill` (looks like a ticket/pass) to
`wallet.bifold.fill` (an actual folding-wallet glyph), per a reference image showing the intended
look. Scoped to just the tab bar icon — the account editor's icon picker, empty-state icon, and
wallet picker icon were left untouched.

**Testing:** Full app build succeeded.

---

## 3. Clarity Score (new feature, built from scratch)

**Date:** 2026-09-24

**Files changed:**
- `FinanceTracker/Models/ClarityScoreCalculator.swift` (new)
- `FinanceTracker/Views/HomeView.swift`
- `FinanceTrackerTests/ClarityScoreCalculatorTests.swift` (new)

**Summary:**
There was no existing "Clarity Score" in the codebase, so this was built as a new feature rather
than an enhancement. `ClarityScoreCalculator` is a pure, deterministic 0–100 score weighted toward
the last 7 days of spending, with up to three independent adjustments — budget pace this month,
vs. last week, and vs. a trailing 30-day "typical week" — each skipped (not invented) when its own
baseline has no data. Trend (up/down/stable) is derived by re-running the same calculation anchored
one week earlier and comparing scores, so no separate persisted history is needed. A new "Clarity
Score" card on Home shows the score, a trend badge, a one-line explanation, and the top 2–3 factors
behind it, using existing `SectionCard`/`DeltaIndicator` design-system components.

**Testing:** 11 new unit tests, all passing, covering the no-data guard, exclusion/income
filtering, each factor individually, ranking, and all trend states (values cross-checked against
an independent Python port of the exact arithmetic). Full app build succeeded; full test suite run
showed 231/231 executed tests passing (34 unrelated CloudKit/Collaboration tests fail in this
sandbox only because it has no `com.apple.developer.icloud-services` entitlement — pre-existing,
unrelated to this change).

---

## 4. Spending Health card on Overview

**Date:** 2026-09-24

**Files changed:**
- `FinanceTracker/Models/BudgetCalculator.swift` (added `BudgetHealthState`)
- `FinanceTracker/DesignSystem/Tokens/GaugeThreshold.swift` (refactored to reuse `BudgetHealthState`)
- `FinanceTracker/Models/OverviewCalculator.swift` (new)
- `FinanceTracker/Models/OverviewSettings.swift` (added `.spendingHealth` card)
- `FinanceTracker/Views/OverviewSummaryView.swift`
- `FinanceTrackerTests/OverviewCalculatorTests.swift` (new)

**Summary:**
Added a compact "Spending Health" card to Overview showing budget-vs-actual per category.
`BudgetHealthState` (on-track / approaching-limit / over-budget) was extracted from
`GaugeThreshold`'s existing 85%/100% thresholds into the Models layer, so the new card and the
existing gauge color rule share one source of truth instead of duplicating magic numbers.
`OverviewCalculator.categorySpendingHealth` reuses `BudgetCalculator.periodSpendingSummary`'s
existing per-category totals — categories with no budget are excluded (nothing to compare
against), and results are ranked over-budget → approaching → on-track, capped at 5, so only what
needs attention shows. Rows reuse the existing (previously-built-but-unadopted) `BudgetProgress`
ring component and tap through to `CategoryEntriesDetailView` — the same drill-down `RemainingView`
already uses, via an identical entry filter so the detail list matches the total shown. The new
card is wired into Overview's existing show/hide/reorder settings automatically.

**Testing:** 12 new unit tests, all passing — `BudgetHealthState` threshold boundaries, budget
exclusion, `excludeFromBudget` handling, ranking, and the 5-item cap. Ran only the targeted test
classes affected by this change (`OverviewCalculatorSpendingHealthTests`, `BudgetHealthStateTests`,
`BudgetCalculatorPeriodSpendingSummaryTests` — 32 tests total, all passing) rather than the full
suite, plus a full app build.

---

## 5. Money Calendar: daily-spending calendar on Overview

**Date:** 2026-09-24

**Files changed:**
- `FinanceTracker/Views/CalendarView.swift`
- `FinanceTracker/Views/DayEntriesView.swift`
- `FinanceTracker/Views/OverviewSummaryView.swift` (card title only)
- `FinanceTracker/Models/OverviewSettings.swift` (card title only)
- `FinanceTrackerTests/CalendarAccessibilityTests.swift` (rewritten)
- `FinanceTrackerTests/SpendingBreakdownCalculationTests.swift` (updated cross-surface tests)

**Summary:**
Reworked the existing Overview calendar (previously a net income/expense heatmap) into a "Money
Calendar" focused specifically on daily spending. Each day cell now shows that day's total
budget-eligible expenses (reusing `EntryQuerying`'s `.inMonth`/`.totalExpenses` and
`BudgetEligibility`'s `.budgetEligible` — no new calculation logic), with a subtly-scaled red tint
and compact amount label; days with no spending stay visually quiet (no more green
income-day tint). Today is marked with a blue ring as before; tapping a day now also sets a
**persistent** selection (a distinct white-wash highlight that survives closing the detail sheet,
plus a one-line "date — amount spent" summary below the grid that updates instantly on tap) before
opening `DayEntriesView` for that day's full transaction list, so today and the selected day are
always visually distinguishable even when they're different days. Month navigation is unchanged —
it's inherited from `OverviewView`'s existing `MonthSelector`, not duplicated.

One deliberate behavior change, called out explicitly per this task's requirements: a day's
**spend total** now excludes `excludeFromBudget` entries (matching Spending/Budget elsewhere in
the app), whereas previously Calendar was fully "raw" like Activity. The day's **transaction
list** itself (what `DayEntriesView` shows) is still raw/unfiltered — an excluded entry stays
visible and editable there, it just no longer counts toward the total. `DayEntriesView`'s "Total"
row was renamed "Spent" and now computes `entries.budgetEligible.totalExpenses` instead of a
net income/expense/transfer sum.

**Testing:** Rewrote `CalendarAccessibilityTests` for the new spend-only label API (5 tests) and
updated `SpendingBreakdownCalculationTests`' cross-surface-consistency tests to characterize the
new split behavior — list stays raw, total doesn't (12 tests). Ran only these two affected test
classes (17 tests total, all passing) rather than the full suite, plus a full app build.

---

## 6. Quick fix: hitting a budget exactly (100%) no longer flags red

**Date:** 2026-09-24

**Files changed:**
- `FinanceTracker/Models/BudgetCalculator.swift` (`BudgetHealthState.forProgress`)
- `FinanceTracker/DesignSystem/Tokens/GaugeThreshold.swift` (doc comment only, no behavior change beyond what `BudgetHealthState` already drives)
- `FinanceTracker/DesignSystem/Components/Metrics/BudgetProgress.swift`
- `FinanceTracker/Views/HomeView.swift` (`safeToSpendStatusText`)
- `FinanceTrackerTests/OverviewCalculatorTests.swift`

**Summary:**
Reported bug: Spending Health showed "Phone 10,00 € / 10,00 € — 100%" as over-budget (red ring,
red text), even though spending exactly the planned amount isn't a bad outcome — Rent, Electricity,
and Phone all hit exactly 100% and were all wrongly flagged red alongside categories genuinely
over budget (Claude 130%, Gym 111%). Root cause: `BudgetHealthState.forProgress` used `progress >=
1` for `.overBudget`, so exactly-100% and everything above it were indistinguishable. Changed the
comparison to `progress > 1` — exactly 100% now falls into `.approachingLimit` (amber), same as
95%, and only spending that genuinely exceeds the plan reads as over-budget (red). Since this rule
is shared everywhere via `GaugeThreshold.color(forProgress:)`, the fix applies consistently across
Spending Health, Plan → Remaining's gauge, and the budget widget — not just the screen in the bug
report.

While fixing this, found and fixed a second, related bug it would otherwise have introduced:
`BudgetProgress`'s `isOverBudget` flag was implemented as `GaugeThreshold.color(forProgress:
isOverBudget ? 1 : progress)` — a trick that only worked because `1` used to mean "over budget."
With the threshold now `> 1`, that trick would have silently stopped forcing the ring red for any
caller passing `isOverBudget: true` (e.g. `RemainingView`'s `CategoryProgressRow`, and this
session's own Spending Health rows). Rewrote it to set `.expense` directly when `isOverBudget` is
true, independent of the threshold rule.

Also updated `HomeView.safeToSpendStatusText`'s own hardcoded `>= 1` check (a duplicate of the
same threshold, kept in sync by its own doc comment's stated invariant) to `> 1`, so Home's "Over
budget" / "Getting close to budget" wording can't disagree with the color it sits next to.

**Testing:** Updated `BudgetHealthStateTests` to assert `forProgress(1.0) == .approachingLimit`
(previously asserted `.overBudget`) and that only `> 1.0` values are `.overBudget`. Ran only the
tests affected by this change — `BudgetHealthStateTests`, `OverviewCalculatorSpendingHealthTests`,
`BudgetCalculatorPeriodSpendingSummaryTests` (32 tests, all passing) — rather than the full suite,
plus a full app build.

---

## 7. Shortcut "New Transaction" flow: local categorization + fewer prompts

**Date:** 2026-09-24

**Files changed:**
- `FinanceTracker/Services/CategorizationService.swift`
- `FinanceTracker/Intents/LogExpenseIntent.swift`
- `FinanceTracker/Views/AutomationsHelpView.swift` (description text only)
- `FinanceTrackerTests/CategorizationServiceTests.swift`

**Summary:**
Inspected the existing App Intents (`LogExpenseIntent` = "New Transaction", `TransactionFromTextIntent`
= "Transaction from Message") rather than building a new one — `LogExpenseIntent` was the right fit
for "amount + quick context" (it already had `note`/`categoryHint`/`category` parameters), but had
two real gaps against this task's requirements:

1. **No deterministic/local categorization existed anywhere in the app.** `CategorizationService`
   (the app's one categorization system, also used by `AddTransactionView`'s manual entry and
   `TransactionFromTextIntent`) was 100% AI-dependent — every suggestion required a network call
   and a configured Anthropic API key, with no offline path at all. Added
   `CategorizationService.localCategoryMatch(for:in:)`: a fast, deterministic, offline
   case-insensitive substring match between the note/merchant text and the user's own category
   names (longest match wins, e.g. "Fast Food" over "Food"). Wired into `suggestCategory(for:
   isIncome:)` as the first attempt, before the AI call — so it benefits every caller
   (`AddTransactionView`, `LogExpenseIntent`) automatically, not just Shortcuts, and never
   requires an API key for the common case where the note text already resembles a category
   name. Falls through to the existing AI suggestion, then the existing "Miscellaneous"/nil
   default, exactly as before, when nothing matches locally — no invented categories, no new
   categorization system.

2. **The intent asked a redundant interactive question even when context was already provided.**
   Previously, `LogExpenseIntent.perform()` only ever used `categoryHint` (asked via an
   interactive `requestValue` prompt) to categorize — it never used `note` for this at all, even
   when a Shortcuts Automation had already piped a bank/wallet notification's text straight into
   `note`. Reordered the flow: if `category` isn't set explicitly, categorize from `note` first
   (now instant via the local match, above); only prompt interactively for `categoryHint` when
   there's no `note` text either. This makes the fully-automated notification-trigger case (amount
   + note already provided) resolve with zero extra prompts, while the interactive Siri/Action
   Button case (nothing provided yet) is unchanged.

Amount and note were already both saved on the `Entry` (`Entry.note`) — no model change needed
there. Parameter names/titles, the `AppShortcut` phrases, and `TransactionFromTextIntent` were all
left untouched for compatibility with any already-configured Shortcuts Automation.

**Testing:** Added 9 new tests to `CategorizationServiceTests.swift` — `localCategoryMatch`'s exact
match, substring-both-directions, longest-match preference, no-match/empty-input cases, and an
end-to-end `suggestCategory` test proving a category resolves via the local path alone with no API
key configured in the test target. Ran only the affected test classes — `CategorizationServiceTests`
and `IntentWalletResolutionTests` (29 tests total, all passing) — rather than the full suite, plus
a full app build.

---

## 8. Follow-up fix: make the merchant/note field required, not just interactive

**Date:** 2026-09-24

**Files changed:**
- `FinanceTracker/Intents/LogExpenseIntent.swift`
- `FinanceTracker/Views/AutomationsHelpView.swift` (description text only)

**Reported:** after entry #7 shipped, running the actual "DEBITO SANTANDER" Apple-Pay-triggered
Automation on-device still only showed a numeric Amount prompt — no merchant/note field appeared,
so categorization still never happened.

**Root cause:** entry #7's fix relied on `$categoryHint.requestValue(...)`, an *interactive*
mid-`perform()` prompt, to ask for text when `note` was empty. `amount`, by contrast, is a
*required* `@Parameter` — Shortcuts resolves required parameters itself, up front, before
`perform()` even runs, which is why it always reliably showed a numeric prompt. An Automation
triggered by a notification or an Apple Pay payment is typically configured with "Ask Before
Running" off (the normal, desired setup for something you don't want to be interrupted by every
time), and iOS does not reliably surface a *mid-run* interactive `requestValue` prompt in that
context — it can be silently skipped, so `categoryHint` stayed empty, `resolvedCategory` stayed
nil, and the expense saved with no category, with no visible error. `TransactionFromTextIntent`
never hit this because its `requestValue` calls only ever "confirm" values already pre-filled by
AI extraction — a `requestValue` call for an already-set parameter returns immediately without
needing to prompt at all.

**Fix:** made `note` a required (non-optional) `@Parameter`, exactly like `amount` already was,
and removed the now-redundant `categoryHint` parameter and its interactive-fallback code path
entirely — one required text field does the job of both. Shortcuts now resolves `note` the same
guaranteed way it already resolved `amount`, regardless of "Ask Before Running." An existing,
already-configured Automation isn't broken by this — Shortcuts just starts prompting for the one
additional required field, the same way it already prompts for amount today.

**Testing:** No test changes needed — `IntentWalletResolutionTests` and `CategorizationServiceTests`
(the two suites touching this intent/service) still pass unchanged (29 tests), plus a full app
build. This particular fix is fundamentally about Shortcuts' runtime parameter-resolution behavior
on-device, which isn't exercised by the unit test target — see entry #7 for the actual
categorization-logic test coverage, which this entry doesn't change.

---

## 9. "Explain My Month": deterministic monthly narrative on Overview

**Date:** 2026-09-24

**Files changed:**
- `FinanceTracker/Models/ExplainMyMonthCalculator.swift` (new)
- `FinanceTracker/Views/ExplainMyMonthCardView.swift` (new)
- `FinanceTracker/Models/OverviewSettings.swift` (new `.explainMonth` case)
- `FinanceTracker/Views/OverviewSummaryView.swift` (wire the new card into the existing card switch)
- `FinanceTracker.xcodeproj/project.pbxproj` (new file references/build phases)
- `FinanceTrackerTests/ExplainMyMonthCalculatorTests.swift` (new)

**Summary:**
Added an "Explain My Month" card to Overview: a short, deterministic explanation of what happened
in a month's actual data — total spending, the change vs. last month (only when last month has
comparable data), the categories that moved most, budget performance, one positive highlight, and
one area that may need attention. Deliberately separate from the existing `SpendingInsightsCardView`
(the AI-generated free-text summary calling Claude): that one can fail, needs an API key, and isn't
reproducible from the same data twice. This one is pure, local, and always produces the exact same
output for the exact same data — every number traces back to a specific comparison in
`ExplainMyMonthCalculator.explain`, never an invented figure.

Built entirely by composing existing calculation layers rather than adding new spend/budget math:
`BudgetCalculator.periodSpendingSummary` for current/previous-month totals and per-category actuals,
`OverviewCalculator.categorySpendingHealth` for over-budget categories, `BudgetCalculator.
spendingPace`/`HomeCalculator.forecastPaceState` for the "ahead of pace" check, and `HomeCalculator.
whatsDifferentThreshold`/`WhatsDifferentInsight`'s existing shape for "meaningful change" (applied
at `Category` granularity here, rather than Home's `HeadCategory` granularity, since a monthly
narrative benefits from being more specific). A comparison to the previous month — both the total
and any per-category change — is only ever produced when the previous month itself had
budget-eligible spend; otherwise those fields are `nil`/empty rather than comparing against zero.
The positive highlight and attention area are each chosen from a fixed priority order (e.g. total
spend meaningfully down > biggest category decrease > nothing over budget, for the positive side)
so the single most relevant observation surfaces without ever showing more than one of each. A
month with no budget-eligible spend at all renders a plain first-month/empty-state message instead
of the narrative. The card is wired into Overview's existing show/hide/reorder card settings
(`OverviewSettingsView`) automatically, and its visuals (`.surface(.secondary, ...)`, `DeltaIndicator`/
`TrendIndicator`, `GaugeThreshold` coloring) reuse the exact same design-system components as the
neighboring `SpendingHealthCardView`/`SpendingInsightsCardView`.

**Testing:** 19 new unit tests in `ExplainMyMonthCalculatorTests.swift` covering the first-month/
no-activity state, total spending and previous-month comparison (including "no comparison when
there's no prior data"), notable per-category changes (threshold, ranking, the 3-item cap,
`excludeFromBudget` exclusion, favorable/unfavorable direction), budget performance (nil when
unbudgeted, over/on-track states), and the positive-highlight/attention-area priority chains
(total-down, category-decrease, within-budget / over-budget-category, ahead-of-pace,
category-increase, and the "nothing supports a claim" nil cases). Ran only the six new test classes
(19 tests, all passing) rather than the full suite, plus a full app build for the `FinanceTracker`
scheme (including the widget extension target, which also compiles the new Model file). Manual
in-simulator verification of the rendered card was not completed — this sandboxed environment has
no accessibility permissions for UI automation (AppleScript/`cliclick` taps on the Simulator app are
silently rejected, and no `idb` install is available), so only the empty first-launch Home screen
could be screenshotted; the Overview tab itself was not visually confirmed.

---

## 10. "Ask Clarity": controlled Q&A over the app's own data

**Date:** 2026-09-24

**Files changed:**
- `FinanceTracker/Models/AskClarityEngine.swift` (new)
- `FinanceTracker/Views/AskClarityView.swift` (new)
- `FinanceTracker/Views/ToolsView.swift` (new "Ask Clarity" entry in the More grid)
- `FinanceTracker.xcodeproj/project.pbxproj` (new file references/build phases)
- `FinanceTrackerTests/AskClarityEngineTests.swift` (new)

**Summary:**
Added "Ask Clarity" — a lightweight, local Q&A screen reachable from More, letting a user ask
about their own data in a controlled way rather than through an open-ended chatbot.
`AskClarityIntent` (`Models/AskClarityEngine.swift`) is a closed, `CaseIterable` enum of exactly
six supported questions (total spending, top category, budget status, increasing categories,
month-over-month comparison, and available/saved), each carrying its own suggested-question string,
a keyword list for free-text matching, and a graceful "not enough data" message. Adding a seventh
supported question later means adding one case, one keyword list, and one branch in
`AskClarityEngine.answer(to:...)` — nothing else in the pipeline changes.

`AskClarityIntentMatcher.match(_:)` is a deterministic local keyword lookup — exact suggested-
question match first, then a substring/keyword scan in intent-declaration-priority order — and
returns `nil` for anything unrecognized, which the view surfaces as "I can't answer that yet, try
one of the suggested questions" rather than guessing. This is a plain string match, not a language
model or network call: "Ask Clarity" deliberately never calls an external AI service, unlike the
existing `SpendingInsightsService` (used for a separate, AI-generated free-text monthly summary),
preserving the app's local-first approach for a feature whose answers must be exactly traceable to
the app's own data.

`AskClarityEngine.answer(to:...)` computes every answer by composing existing calculation layers —
`BudgetCalculator.periodSpendingSummary` (for per-category totals and the "left to spend"/savings-
transfer figures) and this session's own `ExplainMyMonthCalculator.explain` (for the previous-month
comparison, notable category changes, and budget performance) — never a new spend/budget
calculation. Each intent's answer is a plain `AskClarityAnswer` (headline + supporting-numbers
detail + a `hasSufficientData` flag) built by selecting and phrasing already-computed fields; when
the underlying data can't support an answer (e.g. no spending logged, no prior month to compare, no
budget set), `hasSufficientData` is `false` and the headline is the intent's own honest explanation
instead of an invented figure.

`AskClarityView` is a chat-style screen (question bubbles + answer cards, a persistent row of
tappable suggested-question chips, and a text field for free-typed questions) pushed from a new
"Ask Clarity" tile in More, styled with the same design-system tokens (`Color.surfaceSecondary`,
`LinearGradient.emeraldSky`, `ClaritySpacing`) as every other screen in that list. It always answers
the current calendar month, matching the suggested questions' own "this month"/"last month"
phrasing.

**Testing:** 21 new unit tests in `AskClarityEngineTests.swift` — intent matching (every suggested
question resolves to itself, case/whitespace insensitivity, several free-text paraphrases per
intent, unrecognized text returns `nil`, and a same-text-matches-two-intents priority check) plus
one answer-correctness test class per intent covering both the "sufficient data" happy path (right
numbers/wording) and the "insufficient data" graceful fallback. Ran only the seven new test classes
(21 tests, all passing) rather than the full suite, plus a full app build for the `FinanceTracker`
scheme (including the widget extension target, which also compiles the new Model file). As with
entry #9, manual in-simulator interaction (tapping a suggestion chip, typing a question) could not
be verified in this sandboxed environment for the same UI-automation-permission reason.

---

## 11. Plan default sub-tab, unplanned-expense verification, and a duplicate Home card

**Date:** 2026-09-24

**Files changed:**
- `FinanceTracker/Views/BudgetView.swift` (`BudgetContentView.subTab` default)
- `FinanceTracker/Views/HomeView.swift` (removed Financial Snapshot)
- `FinanceTrackerUITests/TabNavigationUITests.swift`
- `FinanceTrackerUITests/PlanAllocateUITests.swift`
- `FinanceTrackerUITests/PullToRefreshUITests.swift`

**Summary:**

**1. Plan now opens to Remaining by default.** `BudgetContentView.subTab` defaulted to `.plan`
(Allocate); changed to `.remaining`, per this task's request. Three UI tests assumed the old
default and needed updating so they keep testing what their names say they test rather than
silently drifting onto whatever the new default is: `TabNavigationUITests` now asserts Remaining's
own "No Budget Set" empty-state text renders on a fresh Plan visit (a real content check, not just
"the Allocate segment button exists," which is true regardless of which segment is selected);
`PlanAllocateUITests.openAllocateWithIncomeCollapsed()` and `PullToRefreshUITests.
testPullToRefreshOnPlanAllocateDoesNotDisruptTheScreen` both now explicitly tap "Allocate" after
opening Plan instead of assuming it's already showing.

**2. Verified: unplanned/unbudgeted expenses are already included in the app's totals — no bug
found, no code change needed.** Traced this through `BudgetCalculator.periodSpendingSummary`: a
category with no `Budget` row (or a `Budget` row with no fixed carry-forward) resolves to
`planned == 0` (`BudgetQuerying.amount(for:month:)`), and any of its spend falls into
`otherExpensesTotal` — which is folded into `totalSpent` by default
(`settings.includeUnplannedAsOtherExpenses`, true unless the user turns it off in Plan settings).
So `totalSpent`, `totalLeft` ("Available to Spend"), and every downstream consumer of
`periodSpendingSummary` (Overview's Income/Expenses, Explain My Month, Ask Clarity, the budget
widget) already count unplanned spending correctly — it isn't silently dropped. It's excluded only
from the *per-category* Spending Health/Remaining rings specifically (`OverviewCalculator.
categorySpendingHealth` skips `planned == 0` categories), which is intentional and pre-existing:
there's no per-category limit to show a ring against. Plan → Remaining already surfaces the
unbudgeted amount explicitly as its own "Other Expenses" row (`RemainingView.OtherSpendingCard`)
rather than hiding it. No production code changed for this item — it's a verification, reported
here per this task's request to check the behavior.

**3. Removed Financial Snapshot from Home.** It duplicated Overview's own Income/Expenses/Net row
(`SummaryMetricsRow`) — same budget-eligible calendar-month calculation, same three numbers, one
tap away. Deleted `HomeView.financialSnapshotSection` and its now-unused `monthEntries`/
`snapshotIncome`/`snapshotExpenses`/`snapshotNet` computed properties, and removed it from Home's
body. Net Worth and Forecast (Home's other two lower sections) are unaffected and unchanged. No
other file referenced these symbols (confirmed via a full-project search), so nothing else needed
updating.

**Testing:** No unit tests exist for either HomeView content or `BudgetContentView`'s default
sub-tab (both are plain SwiftUI view/state, not calculator logic), so there's nothing to run there
beyond a full app build, which succeeded. The three UI test edits above were updated to match the
new default but — consistent with every other UI-test change this session — could not be run in
this sandboxed environment (no accessibility permissions for Simulator UI automation); they're
reasoned through by inspection instead; item 2 involved no code change to test.

---

## 12. Revert: "New Transaction" shortcut required a merchant/note, breaking unattended Automations

**Date:** 2026-09-25

**Files changed:**
- `FinanceTracker/Intents/LogExpenseIntent.swift`
- `FinanceTracker/Views/AutomationsHelpView.swift` (description text only)

**Reported:** the real "DEBITO SANTANDER" Apple-Pay-triggered Automation (the exact one entry #8
was fixing for) stopped completing after entry #8 shipped — it now shows/asks for a Merchant/Note
field that never resolves, and the transaction never gets logged.

**Root cause:** entry #8's own fix was the regression. Making `note` a required `@Parameter` does
make Shortcuts resolve it up front rather than via an interactive mid-`perform()` prompt (true),
but entry #8's closing claim — "an existing, already-configured Automation isn't broken by this"
— was wrong on exactly the case that matters here: a bank/Apple-Pay-triggered Automation with "Ask
Before Running" off has no text to supply for a new required free-text field and, being
unattended, no one present to type one in if Shortcuts tries to prompt for it — so the run stalls
on that field instead of completing. A required parameter only stays reliable when something can
actually supply it without a human in the loop; `amount` gets that from the trigger context (a
payment amount), but there's no equivalent automatic source for a merchant *note*. Entry #8's
"Testing" section had already flagged this exact gap — "this fix is fundamentally about
Shortcuts' runtime parameter-resolution behavior on-device, which isn't exercised by the unit test
target" — and it turned out to be wrong in exactly the untested case.

**Fix:** `note` is optional again (`String?`), and `parameterSummary` no longer references it, so
Shortcuts never prompts for it and never blocks a run on it. Entry #7/#8's actual improvement —
resolving a category from `note` via `CategorizationService.suggestCategory` instead of the
original interactive `categoryHint` prompt — is kept as-is: categorization still runs whenever
`note` already happens to be filled in (by the automation, or typed/dictated interactively), and
is silently skipped (transaction saves uncategorized) when it isn't, rather than ever prompting for
one on its own. This is the same category of bug entry #8 itself was fixing (a silent, interactive,
mid-run prompt that unattended Automations can't answer) — the fix here is to make sure nothing
about `note` ever becomes one again, not to swap which parameter has the problem.

**Testing:** `IntentWalletResolutionTests` (unchanged assertions, only tests `resolveWallet`, not
the `note` parameter's type) still passes, plus a full app build. Like entry #8, the actual
regression here is Shortcuts' on-device parameter-resolution behavior for an unattended Automation,
which isn't something the unit test target can exercise — this was reported by the user actually
running their real Automation, not caught by CI/tests, and entry #8's own log entry already said as
much about the fix it introduced.

---

## 13. Full UI regression pass, a "Consolidated" Remaining section, performance fixes, and Overview/Home feature removals

**Date:** 2026-09-27

**Files changed:**
- `FinanceTracker/Views/EntryRow.swift`
- `FinanceTracker/Views/CategoryEntriesDetailView.swift`
- `FinanceTracker/Views/RemainingView.swift`
- `FinanceTracker/Models/BudgetSettings.swift`
- `FinanceTracker/FinanceTrackerApp.swift`
- `FinanceTracker/Views/RootView.swift`
- `FinanceTracker/Models/BudgetCalculator.swift`
- `FinanceTracker/Views/HomeView.swift`
- `FinanceTracker/Views/OverviewSummaryView.swift`
- `FinanceTracker/Models/OverviewSettings.swift`
- `FinanceTracker/Views/SpendingInsightsCardView.swift` (deleted)
- `FinanceTrackerTests/SpendingInsightsAggregationTests.swift` (deleted)
- `FinanceTrackerTests/TrendChartAccessibilityTests.swift` (deleted)
- `FinanceTrackerUITests/RemainingOtherExpensesUITests.swift` (new)
- `FinanceTracker.xcodeproj/project.pbxproj` (file references for the above)

**Summary:**

**1. Ran the full UI regression suite on request** (`xcodebuild test`, iPhone 17 Pro simulator) —
8/10 passing, `PullToRefreshUITests.testPullToRefreshOnPlanAllocateDoesNotDisruptTheScreen` and
`TabNavigationUITests.testAllFiveTabsAreReachableAndShowDistinctContent` failing. Root-caused via
an `app.debugDescription` accessibility-tree dump mid-test: Plan's header read "Budget" instead of
the expected "Plan." `BudgetSettingsStore.name` persists to the App-Group `UserDefaults` suite
(shared with the widget), and `-uiTestReset` (`UITestSupport.launchApp()`'s documented "clean
slate") only ever reset the SwiftData store, never this suite — a stale pre-Phase-2J "Budget" value
left over on this simulator survived every reset indefinitely. Added `BudgetSettingsStore.
resetForUITesting()` (clears every key this store persists) and call it alongside
`SharedModelContainer.resetStoreForUITesting()` in `FinanceTrackerApp.init()`. Both previously-
failing tests, and the full 11-test suite (after also adding item 2 below), pass clean.

**2. Added `CategoryEntriesDetailView` transaction dates + a "Consolidated" section on Remaining.**
`EntryRow` gained an opt-in `showDate` parameter (a trailing caption under the amount), turned on
only for `CategoryEntriesDetailView`'s flat, non-day-grouped entry list — every other list reusing
`EntryRow` is already grouped under day-section headers and is unaffected. Also added a
collapsed-by-default "Consolidated" section to `RemainingView`, sitting once directly below the
gauge: a two-level `DisclosureGroup` recap of every category with spend this period, grouped by
head category then category, each leaf linking into `CategoryEntriesDetailView`. Went through two
designs per user feedback: the first version scoped the breakdown to unplanned/"Other Expenses"
spend only and lived inside the existing "Other" card — flagged by the user as confusing, since a
category with both `planned == 0` and real spend (e.g. Outcomes' Colombia/Cash/Bizum Out) then
showed up twice on screen under a label that didn't fit a section repeating already-visible data.
Redesigned as a standalone, all-spend recap named "Consolidated," and the original flat "Other
Expenses" drill-down row was removed outright from the "Other" card (Savings Transfers/Debt
Payments stay — each is its own transfer type, not a duplicate view of spend shown elsewhere;
`settings.includeUnplannedAsOtherExpenses` still controls the gauge total, just no longer has a
dedicated row). Discovered and fixed a real SwiftUI accessibility-identifier bug along the way:
`.accessibilityIdentifier(...)` chained after a whole `DisclosureGroup` (label + expanded content)
attaches to that entire subtree and silently overwrites every descendant's own identifier —
verified via another `app.debugDescription` dump; fixed by moving each identifier onto its own
`DisclosureGroup`'s *label* (`.accessibilityElement(children: .combine)` + `.accessibilityIdentifier`),
never the whole disclosure.

**3. Two of the three requested performance investigations were implemented; the third was
deliberately skipped.** (a) `RootView`'s splash hold was a flat, unconditional 1.3s regardless of
how fast anything actually loaded — trimmed to just past when `LaunchScreenView`'s own intro
animation finishes playing (~0.82s), not an arbitrary round number, per explicit instruction to
improve rather than remove the splash (the user further hand-tuned this to 1.0s/0.7s-fade after the
initial 0.9s edit). (b) `BudgetCalculator.periodSpendingSummary`'s `actualSpend(for:)` re-filtered
the *entire* period-expenses array once per category (O(categories × entries), called from Home,
Overview, and Plan independently every render) — replaced with a single `Dictionary(grouping:)`
pass keyed by `persistentModelID` up front, then O(1) lookups; verified behavior-identical via the
full 268-test unit suite (all passing, unchanged). (c) The broader finding — 15 separate views each
declare an unfiltered `@Query allEntries` pulling the *entire* transaction history into memory,
then filter in Swift (only 2 files in the whole codebase use `#Predicate` at all) — was reported but
explicitly **not** implemented, per the user's own "sin comprometer arquitectura ni afectar
funcionalidades... si no, no lo hagas": fixing it properly means auditing each of the 15 call sites
individually (several, like CSV export and category search, may genuinely need full history) rather
than one contained change, so it was left as a flagged, un-actioned finding.

**4. Removed four features on request, verifying no orphaned code/tests each time.** "Forecast" on
Home (`HomeView.forecastSection` + its now-unused `pace`/`forecastState` computed properties —
`HomeCalculator.forecastPaceState` itself stays, still used by `ExplainMyMonthCalculator`).
"Spending Insights" on Overview (the AI-generated free-text card) — deleted `SpendingInsightsCardView.
swift` entirely (the view *and* its `SpendingInsightsAggregation` logic, confirmed unreferenced
anywhere else) along with its dedicated `SpendingInsightsAggregationTests.swift`;
`SpendingInsightsService` itself (the underlying network/caching service) was kept untouched — it's
also used by `ClarityScoreCalculator`, `ExplainMyMonthCalculator`, and `AnthropicClaritySemanticProvider`.
The "Insights" 6-month-trend-chart card on Overview — deleted `InsightsSummaryCard` and its
`trend`/`topCategories`/`trendAccessibilitySummary` support code from `OverviewSummaryView.swift`,
plus its dedicated `TrendChartAccessibilityTests.swift` (`summaryHasActivity`, used by the
`.summary` card that stays, was left in place). Both Overview cases were removed from the
`OverviewCard` enum (`OverviewSettings.swift`) — `OverviewSettingsView`'s show/hide/reorder list
iterates `OverviewCard.allCases` generically, so both entries disappeared from that settings screen
automatically, no manual list edit needed. Used the `xcodeproj` Ruby gem to remove/add file
references (`project.pbxproj` isn't XcodeGen-managed for the UI test target — confirmed the hard
way earlier this session, see below) rather than hand-editing the pbxproj.

**5. Aborted `xcodegen generate` mid-session after it silently clobbered the checked-in project.**
While trying to add a throwaway manual-verification UI test file, ran `xcodegen generate` to pick it
up — this deleted the shared `FinanceTracker.xcscheme` and rewrote large parts of `project.pbxproj`,
because the `FinanceTrackerUITests` target/scheme were apparently added by hand in Xcode at some
point and were never declared in `project.yml`. Caught immediately via `git status`, reverted both
files with `git checkout --`, and used the `xcodeproj` gem for all subsequent file-reference changes
instead (a `~4`-line pbxproj diff per file, rather than XcodeGen's full regeneration). No commit/push
happened while the project was in the broken state.

**6. Several small SwiftUI layout tweaks the user made themselves, working from live guidance** (not
implemented by Claude, included here since they touch the files above): `SummaryMetricsRow`
(Overview's Income/Expenses/Net row) centered via `FinancialMetric(..., alignment: .center)` +
`HStack(spacing: 40)` + `.frame(maxWidth: .infinity)` — the fix required passing `alignment: .center`
per-child, since `FinancialMetric`'s own default (`alignment: .leading`) makes each metric request
`maxWidth: .infinity` internally, which no amount of alignment on the outer `HStack`/`frame` can
override. `RemainingGauge`'s frame height was briefly reduced directly (`labelRadius * 2 + 24`),
which clipped the top arc labels since they're positioned via `.offset()` relative to the `ZStack`'s
center and a smaller frame recenters everything; reverted to the original `+ 50` and the actual gap
to `ConsolidatedSection` closed instead via a negative `.padding(.bottom, -60)` on `RemainingGauge`
at its call site, which doesn't touch the gauge's internal centering at all.

**Testing:** Full unit suite (268 tests) and full UI suite (11 tests) both passing at session's end,
run multiple times as changes landed. `RemainingOtherExpensesUITests` (new) exercises Consolidated's
head-category grouping, its category-level drill-down, and the entry-date display added in item 2,
end to end.

---
