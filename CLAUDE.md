# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Clarity** — a personal finance tracker (SwiftUI + SwiftData, iOS 17+). Budgeting, wallets,
shared/split expenses, spending insights, and a home-screen widget. No third-party dependencies —
SwiftUI, SwiftData, Charts, WidgetKit only.

**See `ARCHITECTURE.md`** for the full feature map (every area: Goals, Shared/Collaboration,
Calendar, Backup/Export, App Lock, Account/Auth, Shortcuts/Widget, AI categorization/insights, Ask
Clarity, sync, design system, testing conventions) with real file paths and the "why" behind each
one. Read it before a task that touches a feature not already covered below, instead of
re-exploring the codebase from scratch.

## Commands

The `.xcodeproj` is checked in and is what you normally build/test against directly.

- **Build:** open `FinanceTracker.xcodeproj` in Xcode, select the `FinanceTracker` scheme, ⌘B.
  From the CLI: `xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker -destination 'platform=iOS Simulator,name=iPhone 15' build`
- **Run full test suite:** ⌘U in Xcode, or
  `xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTracker -destination 'platform=iOS Simulator,name=iPhone 15'`
- **Run a single test:** `-only-testing:FinanceTrackerTests/<ClassName>/<testMethodName>` appended
  to the `xcodebuild test` invocation above (or run/debug it directly from Xcode's test gutter icon).
- **Regenerating the Xcode project:** only needed if `project.yml` changes (new target, new file
  group, new Info.plist key, etc.) — `brew install xcodegen` then `xcodegen generate` from the repo
  root (`FinanceTracker/`). Not needed for ordinary source edits.
- Project also has a sweetpad/BSP config (`buildServer.json`) for editor-integrated builds outside Xcode.

Note: ~34 CloudKit/Collaboration tests are expected to fail in any sandbox without the
`com.apple.developer.icloud-services` entitlement — this is pre-existing and unrelated to most
changes (see Collaboration feature flag below).

### Secret scanning

A pre-commit hook (via `ggshield`, hooks path set with `git config core.hooksPath .githooks`) and
a GitHub Actions workflow both scan for committed secrets. If a commit is blocked, it's catching a
real detected secret, not a flaky hook — don't bypass with `--no-verify`.

## Architecture

### Code style and comments

Keep comments concise and intentional.

- Prefer self-explanatory code over comments.
- Comment the **why**, not the obvious **what**.
- Do not add comments for straightforward code, simple properties, or obvious SwiftUI/SwiftData behavior.
- Avoid long explanatory blocks, repeated documentation, or comments that restate the implementation.
- Add a short comment only when a non-obvious constraint, workaround, architectural decision, or platform behavior needs to be preserved.
- When modifying existing comments, keep them concise rather than expanding them.
- Do not generate extensive documentation unless explicitly requested.

### Change summaries

Keep implementation summaries concise:
- what changed
- tests/builds run
- important remaining concerns

Do not repeat architecture or explain unchanged code unless relevant to a problem.

### Targets

| Target | Purpose |
|---|---|
| `FinanceTracker` | Main app (production bundle ID/App Group) |
| `FinanceTrackerDev` | Same source as `FinanceTracker`, side-by-side bundle ID/App Group/entitlements/URL scheme — lets a branch be installed and tested without touching the real app's data. Doesn't embed the widget (a widget extension's bundle ID must be prefixed by its host's). |
| `FinanceTrackerWidgets` | Home-screen widget extension. Pulls in `FinanceTracker/Models`, `Theme.swift`, `SharedModelContainer.swift`, and `DesignSystem/Tokens` only (not `Components/`) — kept minimal and explicit in `project.yml` rather than sharing the whole app target. |
| `FinanceTrackerTests` / `FinanceTrackerUITests` | Unit and UI tests. |

### Data layer: SwiftData in an App Group container

`Services/SharedModelContainer.swift` is the single source of truth for the SwiftData schema and
store location. The store lives in an **App Group container** (not the app's private sandbox)
because the widget extension is a separate process that needs to read/write the same SQLite file
as the main app. The App Group ID is derived from the running bundle ID at runtime (stripping a
`.Widgets` suffix) so the same source file resolves correctly for `FinanceTracker`,
`FinanceTrackerDev`, and the widget, each getting its own isolated store.

Because widget timeline refreshes and Shortcuts/Siri intents (`Intents/`) each run in their own
short-lived extension process, `SharedModelContainer.make()` *throws* rather than crashing — a
transient failure there used to `fatalError()` and silently kill the extension. Only the main
app's own launch (`FinanceTrackerApp.init()`), which genuinely cannot proceed without its store,
uses `makeOrFatal()`.

**Soft delete gotcha:** models don't use a field literally named `isDeleted` — that name collides
with a reserved flag under SwiftData/Core Data and silently fails to persist. See how `Wallet` and
`Entry` name their soft-delete flag instead before adding a new deletable model.

### Sync: local-first, Supabase as the remote backend

`Services/SyncCoordinator.swift` (`@MainActor` singleton) is the **only** place automatic Supabase
sync is triggered from, and it wraps `SupabaseSyncService` (the actual pull/push HTTP logic)
entirely unchanged — it only decides *when* to call it. Four distinct triggers all funnel into one
coalesced pass:
- App became active / launch — syncs only if stale (`periodicSyncInterval`, ~10 min default) or
  there are pending local changes.
- Pull-to-refresh (`DataSyncService.refresh`) — always syncs, and the call doesn't return until a
  real pass (plus any coalesced extra pass) has finished, so `.refreshable` spinners stay accurate.
- A periodic timer while the app is active.
- Local saves (`ModelContext.didSave` on `Entry`/`Wallet`/`Category`/`HeadCategory`/`Budget`) —
  these never trigger a sync directly, only flip a `hasPendingLocalChanges` flag for the next real
  trigger to notice.

A sync pass never runs two at once; a trigger arriving mid-sync coalesces into exactly one extra
pass afterward (hard-capped at one, not an unbounded chain). Each pass runs, in order: pull
reference data → pull budgets → pull entries → push reference data → push budgets → push entries.
SwiftData is always the local source of truth — a local save is never blocked, delayed, or rolled
back by sync; only a pass that completes all six steps updates `lastSuccessfulSync`.

`SupabaseTestView`'s manual "Sync Reference Data"/"Entry Sync"/"Sync All Data" buttons call
`SupabaseSyncService` directly and are unrelated to `SyncCoordinator`.

### CloudKit collaboration (currently disabled)

Shared-expense collaboration via CloudKit (`Services/Collaboration*.swift`, `Services/CloudKit*.swift`,
`Models/EventParticipant.swift`) is fully implemented but gated off by a single switch:
`CollaborationFeatureFlag.isEnabled = false`. It's off because the current build signs with
`FinanceTracker-LocalOnly.entitlements` (App Groups only, no iCloud capability — Apple's free
Personal Team can't request it). Nothing that touches CloudKit may run while the flag is false.
Re-enabling requires flipping the flag, switching `CODE_SIGN_ENTITLEMENTS` back to
`FinanceTracker.entitlements`, and configuring a paid Developer Program team in Xcode — no other
source change is needed, since every call site already checks the flag.

### Ask Clarity (natural-language query engine)

`Models/AskClarityEngine.swift` and its extensions (`AskClarityInterpreter`, `AskClarityPlanner`,
`AskClarityExecutor`, `AskClarityResponsePhrasing`, `AskClaritySemanticInterpreter`,
`AskClarityEngine+SemanticFallback`, `AskClarityEngine+ResponsePhrasing`) form a pipeline:
interpret the typed question → plan what data it needs → execute against local `Entry`/`Category`
data → phrase the answer. `AnthropicClaritySemanticProvider` is an optional fallback for
ambiguous/unmatched phrasing and only engages when an Anthropic API key is configured (see below);
the deterministic interpreter path always works without one. `AskClarityRangeCalculator` reuses
the same budget-eligibility rule (`BudgetEligibility`/`budgetEligible`) every other spending total
in the app uses — never recompute "what counts as spending" independently.

### Optional AI features (categorization, insights, Ask Clarity fallback)

`CategorizationService` and the Ask Clarity semantic fallback call the Anthropic API, keyed via
`ANTHROPIC_API_KEY` in `FinanceTracker/Secrets.plist` (gitignored, never committed). The app and
these specific features degrade gracefully and are simply skipped when no key is present — this
is not a hard dependency anywhere else in the app.

### Design system

`DesignSystem/` is split into `Tokens/` (Colors, Typography, Spacing, Shapes, ColorPalette,
GaugeThreshold) and `Components/` (Cards, Buttons, Forms, Metrics). The widget target only pulls
in `Tokens/`, not `Components/` — e.g. `BudgetGaugeWidgetView` shares `GaugeThreshold`/color tokens
with `RemainingGauge` specifically so the two can't drift apart on the gauge's color-threshold rule.

### Layout: adaptive tab bar vs. sidebar

`MainTabView` switches between a bottom `TabView` (compact width) and a `NavigationSplitView`
sidebar (regular width) based on size class — no `UIRequiresFullScreen` lock. iPhone is
portrait-only (no layout has been designed/tested for iPhone landscape); iPad allows all four
orientations since the sidebar layout assumes landscape use.

### Implementation log

`IMPLEMENTATION_LOG.md` is an append-only running record of past Claude-assisted changes, one
dated entry per change, oldest first. Add a new entry when asked to log work; never reorder or
rewrite past entries — if something changes later, log that as a new entry instead.
