# Clarity — Architecture & Feature Map

A reference for understanding the whole app without re-exploring the codebase from scratch.
`CLAUDE.md` stays short and is always loaded; this file is the deep version — read it when a task
touches a feature you don't already know, or spans more than one area. Keep it in sync with
reality: when a feature changes shape, update its section here rather than leaving this stale.

File paths below are relative to `FinanceTracker/` unless stated otherwise.

## 1. What this is

SwiftUI + SwiftData iOS app (iOS 17+), personal finance tracker with budgeting, wallets, shared/
split expenses, goals, spending insights, two AI assistants (Ask Clarity, voice/text
categorization), Supabase-backed account sync, and a home-screen widget. No third-party
dependencies besides the Supabase Swift SDK.

## 2. Navigation structure

`MainTabView` — exactly 5 tabs (`MainTab`: `.home`, `.overview`, `.plan`, `.wallets`, `.more`).
Capped at 5 deliberately: a 6th tab gets collapsed into iOS's system "More" list, which
contradicted a product decision to keep things visible — Shared lives inside the "More" tab as a
grid item instead. Compact width shows a bottom `TabView`; regular width (iPad) shows
`NavigationSplitView`/`AdaptiveSidebarView`. Each tab's content is re-identified (`.id(currentDay)`)
whenever the calendar day ticks over, since several screens default to "today"/"this month" via a
plain `@State` initializer SwiftUI only evaluates once.

- **Home** → `HomeView.swift` — Safe to Spend, Clarity Score, What's Different, Upcoming.
- **Overview** → `OverviewView.swift` → `OverviewSummaryView`/`SpendingBreakdownView`/`EntryListView`
  sub-tabs (Overview / Spending / List).
- **Plan** → `BudgetView` → `BudgetContentView`, 3 sub-tabs: **Allocate** (`PlanView`, per-category
  budget editor), **Remaining** (`RemainingView`, the gauge), **Goals** (`GoalsListView`). "Insights"
  is a toolbar sheet, not a sub-tab. `PlanContainerView` is a now-unused but deliberately-kept
  Budget/Goals/Forecast launcher, preserved only so the Forecast `ComingSoonView` route isn't lost.
- **Wallets** → `WalletsView` → `WalletsContentView` (UI copy says "Account," the `Wallet` model/
  type names are deliberately not renamed to match).
- **More** → `ToolsView` — grid of: Account, Ask Clarity, Shared, Categories, Export CSV, Widgets
  info, Automations help, App Lock, Backup & Restore, plus two `ComingSoonView` placeholders
  (Reminders, Bank Connections).

## 3. Data layer

`Services/SharedModelContainer.swift` is the single source of truth for the SwiftData schema and
store location — an **App Group container**, not the app's private sandbox, because the widget
extension is a separate process reading/writing the same SQLite file. `make()` throws (extensions
must degrade, never crash); only `FinanceTrackerApp.init()` uses `makeOrFatal()`.

**Soft delete gotcha:** no model uses a field literally named `isDeleted` — that name collides with
a reserved Core Data flag and silently fails to persist (`Entry`/`Wallet` use `isSoftDeleted`).

Core models: `HeadCategory` → `Category` → `Entry`/`Budget`; `Wallet` (balance always computed,
never cached — `NetWorthCalculator.netWorth(wallets:)` sums active, `includeInNetWorth` wallets);
`Goal` → `GoalContribution`; `SharedEvent` → `SharedExpense`/`Settlement`/`EventParticipant`,
`Person`; `SpendingInsight` (regenerable AI cache, excluded from backups).

`Models/EntryQuerying.swift` is the base querying layer everything else builds on:
`.inMonth(_:)`, `.inBudgetPeriod(_:startDay:)` (budget-cycle-aware, half-open range so a boundary
day is never double-counted), `.totalIncome`/`.totalExpenses`. `Models/BudgetEligibility.swift`
defines what counts as spending at all (an `excludeFromBudget` entry — e.g. a wallet balance
adjustment — counts for nothing, app-wide). Every spending/budget calculator in the app is built on
these two files; never recompute "what counts" independently.

`Models/SeedData.swift` seeds 11 default HeadCategories + one "Spending" Wallet, but **only** for a
signed-out/local-only user with zero existing HeadCategories — never unconditionally at launch (see
§8, this is what stops a signed-in user's fresh install from getting duplicate starter data).

## 4. Calculation layer conventions

A small set of calculators are the single source of truth every view reads from — never
re-derive a total independently:

- `Models/BudgetCalculator.swift` — `periodSpendingSummary(...)` is *the* budget-cycle-aware
  spend/budget totals function. Read by Remaining, Home's Safe to Spend, the widget, Ask Clarity,
  Explain My Month, Insights.
- `Models/OverviewCalculator.swift` — `categorySpendingHealth(...)` → `CategorySpendingHealth`
  rows, capped at 5, built on top of `periodSpendingSummary`.
- `Models/ExplainMyMonthCalculator.swift` — `explain(...)` → `MonthExplanation` (total, previous-
  month comparison, notable category changes, budget performance, one positive + one attention
  highlight). Embeds `CategorySpendingHealth` directly rather than re-deriving it.
- `Models/ClarityScoreCalculator.swift` — `clarityScore(...)` → `ClarityScoreResult` (0-100 score,
  trend, up to 4 factors: budget pace / previous week / typical week / month-over-month). Computes
  its own week/month totals directly from `Entry`+`Budget` rather than reusing
  `periodSpendingSummary` — the one calculator that doesn't share that exact lineage. **Inherently
  "as of today"** — has no meaning for a past month; every view gates its Clarity Score section on
  `isCurrentMonth` rather than showing a stale score for a month someone navigated back to.
- `Models/HomeCalculator.swift` — "What's Different" insights + upcoming shared balances.
- `Models/GoalCalculator.swift` / `GoalPresentation.swift` — deliberately independent of Budget/
  BudgetEligibility; Goals and Budget are separate concerns. Progress is always derived from
  `GoalContribution` rows, never cached on `Goal` itself.
- `Models/NetWorthCalculator.swift`, `Models/SharedSplitCalculator.swift` (equal/largest-remainder
  split math, shares always sum back exactly to the original amount).

`BudgetCalculationSettings` (built from `BudgetSettingsStore`, a `@Published`/UserDefaults-backed
singleton holding `cycleStartDay` etc.) is the one settings bundle threaded through all of these.

## 5. Ask Clarity (natural-language query engine)

`Models/AskClarityEngine.swift` + `AskClarityInterpreter`/`AskClarityPlanner`/`AskClarityExecutor`/
`AskClarityResponsePhrasing` — four explicit stages: **interpret** (text → `AskClarityQuery`,
local/deterministic/no network) → **plan** (query → `AskClarityPlan` or a clarification/unsupported
reason) → **execute** (plan → raw numbers, via the calculators in §4) → **respond** (numbers →
worded `AskClarityAnswer`). Never invents a number — Claude is involved in at most two optional,
narrowly-scoped ways:

- `AskClarityEngine+SemanticFallback.swift` — `respondWithSemanticFallback` runs the deterministic
  pass first, synchronously, at zero cost; only calls `AnthropicClaritySemanticProvider` when that
  finds *zero* signal at all (`isUnrecognizedLocally`), and the provider only ever returns a
  structured classification (metric/category/period/etc.), never a number or prose — turned into
  the exact same `AskClarityQuery` shape the deterministic path produces.
- `AskClarityEngine+ResponsePhrasing.swift` — `phrasedNaturally` optionally asks Claude to reword an
  already-computed answer, fact-checked afterward (`AskClarityPhrasingFidelity.preservesFacts`)
  before being used.

Both share one `AskClaritySemanticCallBudget` (default 20 calls/session) so a conversation can't
spiral into unbounded API calls. A question can be scoped to a specific month via
`AskClarityPeriodKind.specificMonth(Date)`, or — the pattern `MonthAskClarityController` uses — by
passing a non-`.now` `today:` to every entry point, which every date-relative phrase resolves
against.

`Views/AskClarityView.swift` is the full chat UI (conversation history, suggested questions,
rich per-insight cards). `Models/MonthAskClarityController.swift` is a second, narrower integration
— a single-question-at-a-time box embedded in Explain My Month (§7), reusing the same engine/
provider rather than a parallel AI integration.

**Separate from this:** `Services/CategorizationService.swift` (bundles `VoiceExpenseParser` —
fully offline voice/text parsing — plus Claude-based category suggestion and raw-text transaction
extraction) assists *data entry*, not querying. `Services/SpendingInsightsService.swift` generates
one cached free-text monthly summary (`SpendingInsight`) from pre-aggregated totals only, never raw
transaction notes. All three AI integrations read the same `ANTHROPIC_API_KEY` from
`Secrets.plist` (gitignored) via `CategorizationService.sanitizedAPIKey(from:)` — one shared
key-reading mechanism, not three.

## 6. Explain My Month / Clarity Score detail screen

`Views/ExplainMyMonthCardView.swift` — the Overview entry banner (gradient card, Clarity Score ring
as its illustration) and `HomeView`'s Clarity Score card both push into:

`Views/MonthInsightsDetailView.swift` — always opens on the real current month (never a month-
picker screen); month changes by **tapping a bar** in its own trend chart
(`.chartXSelection`), never a prev/next control. The chart shows a fixed, non-scrolling window
(currently the latest 6 months, anchored to the real current month — not to whichever month is
selected) specifically so picking an older month can never scroll the current month's bar out of
view, and never auto-scrolls/re-centers on selection (`chartScrollPosition` is set once and never
rewritten). A brief `isChangingMonth` loading state covers the synchronous recompute a month change
triggers. Composes: total spending + trend chart, Highlights (`ExplainMyMonthContent`, shared with
the Overview card), a link into `SpendingBreakdownView`, the Clarity Score card (current month
only), `SpendingHealthCardView` (shared with Overview), and the Ask AI box
(`MonthAskClarityController`, §5).

`Models/ClarityScorePresentation.swift` centralizes the score's wording/tier colors so Home's card
and this screen can never phrase the same score differently.

## 7. Shared/split expenses + Collaboration (CloudKit — currently disabled)

A `SharedEvent` (trip/dinner/group activity) is a temporary workspace entirely separate from the
personal ledger — nothing touches personal `Wallet`/`Entry`/`Budget` until an explicit `Settlement`
is confirmed via "Add to Transactions." `SharedExpense` (equal/byParts/exactAmounts split) +
`SharedExpenseParticipant` hold the cost/share data; `Person` is a lightweight participant (not
necessarily a Clarity user); `EventParticipant` (event-scoped identity/claiming) is deliberately
separate from `Person` since "which iCloud account is this" only makes sense within one event.
`Models/SharedEventQuerying.swift` computes balances/outstanding amounts.

CloudKit sharing (`Services/Collaboration*.swift`, `CloudKit*.swift`) is fully implemented but
gated by **one switch**, `CollaborationFeatureFlag.isEnabled = false` — off because the current
build signs with `FinanceTracker-LocalOnly.entitlements` (App Groups only; a free Personal Team
can't request the iCloud capability). Re-enabling needs only flipping the flag + entitlements + a
paid team, no source changes (every call site already checks it).

## 8. Account / Auth (Supabase)

`RootView`'s `RootAuthState` (`.loading`/`.signedOut`/`.signedIn`) is the whole app's auth gate.
**There's no separate "local-only" state** — `.signedOut` *is* local-only mode: `SeedData` seeds
defaults for it, sync just never runs. `establishSignedIn(userID:seedIfNewAccount:)` is the single
choke point every signed-in transition goes through (launch restore, sign-in, sign-up, password-
recovery, email-confirmation/-change), so none of them can bypass the local-store-ownership check.

`Services/LocalStoreOwnership.swift` (Phase 6.1): the local SwiftData store has no per-row owner
field, so switching Supabase accounts on one device used to silently mix the previous user's local
data into the new one's. `LocalAccountTransition.establishOwnership` decides `.adopt`/
`.alreadyOwner`/`.wipe` by comparing a stored owner marker (App-Group UserDefaults) against the
newly-authenticated user id, wiping (`LocalBackupService.eraseAllData` + `SyncCoordinator
.resetStateAfterLocalStoreWipe()`) before anything else touches the store on a mismatch.

Sensitive-change screens (`ChangeEmailView`/`ChangePasswordView`) route through
`ReauthenticationView` (emails a one-time code). `DeleteAccountConfirmationView` is its own
password-entry sheet instead — account deletion has no OTP-nonce path, so the password is verified
via an ordinary `signIn` call rather than being sent to the delete-account Edge Function.

## 9. Sync: local-first, Supabase as remote backend

`Services/SyncCoordinator.swift` (`@MainActor`) is the only place automatic sync is triggered from;
it decides *when*, `Services/SupabaseSyncService.swift` does the actual pull/push HTTP work. Four
triggers (app-active-if-stale, pull-to-refresh-always, a periodic timer, local-save-marks-pending)
funnel into one coalesced six-step pass: pull reference data → pull budgets → pull entries → push
reference data → push budgets → push entries.

A sync pass runs on its own private `ModelContext`, via `Services/BackgroundSyncExecutor.swift`
(a `@ModelActor`), entirely **off the Main Actor** — this is deliberate: running it against the
main context used to freeze the UI for the pass's full duration (every intermediate `save()`
triggering `@Query` recomputation app-wide). The main context picks up what the background context
writes via the same `.NSPersistentStoreRemoteChange` notification + `modelContext.rollback()` path
already used for the widget/Shortcuts' cross-process writes.

## 10. Other features

- **Calendar** (`Views/CalendarView.swift`) — no dedicated calculator, reuses `EntryQuerying`
  directly. Spending is always the primary visual read per day; income-only days get an emerald
  tint instead of reading blank.
- **Backup & restore** (`Services/LocalBackupService.swift`) — manual, local, full JSON snapshot/
  restore (the CloudKit-sync alternative under the free-team entitlement limitation, §7). Restore
  is always a full replace, never a merge — the snapshot's relationships are encoded as array
  indices scoped to one export, not stable IDs.
- **App Lock** (`Services/AppLockService.swift`) — PIN hashed (SHA256) in the Keychain, never
  UserDefaults; biometrics via `LocalAuthentication`. Always requires a PIN as fallback — no
  biometric-only lock.
- **Shortcuts/Siri** (`Intents/`) — `LogExpenseIntent`/`TransactionFromTextIntent` deliberately
  never prompt interactively (an unattended Automation would stall); uncategorized is an acceptable
  outcome, a silent stall is not.
- **Widget** (`FinanceTrackerWidgets/`) — `BudgetGaugeWidget` reuses the exact same
  `BudgetCalculator.periodSpendingSummary` call the in-app Remaining gauge uses, reading the shared
  App Group settings, so the two can never disagree.

## 11. Design system

`DesignSystem/Tokens/` (Colors, Typography, Spacing, Shapes, ColorPalette, GaugeThreshold) +
`DesignSystem/Components/` (Cards, Buttons, Forms, Metrics) + `DesignSystem/Surfaces/Surface.swift`
(`.surface(tier:radius:padding:)` — the one flat, no-shadow card treatment; `.claritySurface(tint:)`
layers a low-opacity color wash on top for an accent identity, e.g. Home's Safe to Spend/Clarity
Score cards). The widget target pulls in only `Tokens/`, not `Components/`.

## 12. Testing conventions

`FinanceTrackerTests` — calculators tested directly with in-memory `ModelContext` fixtures
(`TestSupport.swift` helpers). Ask Clarity's AI layer is tested via protocol stubs
(`AskClaritySemanticProviding`/`AskClarityPhrasingProviding`), never a real network call. Sync is
tested the same way (mock uploader/downloader protocols). ~34 CloudKit/Collaboration tests are
expected to fail in any sandbox without the `com.apple.developer.icloud-services` entitlement —
pre-existing, unrelated to most changes.

`FinanceTrackerUITests` — `UITestSupport.launchApp()` launches with `-uiTestReset` (wipes the local
store only) and signs in with `TEST_USER`/`TEST_USER_PASSWORD` (read from the test runner's
environment, configured via the scheme's Test action `$(VAR)` indirection — never hardcoded) when
the sign-in screen appears, since the account feature gates app launch. Most runs skip this path
entirely (a prior session's Supabase session is still on disk).
