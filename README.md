# Clarity

A personal finance tracker built with SwiftUI and SwiftData — budgeting, wallets, shared/split expenses, and spending insights, plus a home-screen widget.

- **Display name:** Clarity
- **Minimum iOS:** 17.0
- **Dependencies:** none — SwiftUI, SwiftData, Charts, WidgetKit only (no CocoaPods/SPM packages to install)

## Requirements

- A Mac with Xcode 16 or later
- An iPhone running iOS 17+ (to install on a physical device) or the iOS Simulator
- An Apple ID signed into Xcode (a free Personal Team is enough — no paid developer account required)

## Project Structure

| Target | What it is |
|---|---|
| `FinanceTracker` | The main app |
| `FinanceTrackerWidgets` | The home-screen widget extension |
| `FinanceTrackerTests` | Unit tests |

The Xcode project (`FinanceTracker.xcodeproj`) is checked into the repo, so you can open it directly — no generation step needed for normal use. `project.yml` is the source of truth if the project structure ever needs to change; that requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`, then `xcodegen generate` from the repo root) to regenerate the `.xcodeproj`.

## Getting Started

1. Clone the repo and open `FinanceTracker.xcodeproj` in Xcode.
2. Wait for Xcode to index the project (first open only).
3. Select the **FinanceTracker** scheme in the toolbar.

## Installing on Your iPhone from Xcode

1. **Connect your iPhone** to your Mac with a cable, or over Wi-Fi (Xcode → Window → Devices and Simulators, then check "Connect via network" once paired by cable).
2. **Trust the Mac on your iPhone** if prompted (first-time connection only).
3. In Xcode's toolbar, click the device/simulator selector (next to the scheme name) and choose **your iPhone** from the list.
4. Select the project in the navigator, select the **FinanceTracker** target, and open **Signing & Capabilities**:
   - Check **Automatically manage signing**.
   - Set **Team** to your own Apple ID (add it first via Xcode → Settings → Accounts if it's not listed).
   - Repeat the same Team selection for the **FinanceTrackerWidgets** target.
5. Press **Run** (⌘R), or Product → Run. Xcode will build, sign, and install the app directly onto your phone.
6. **On first launch**, iOS will refuse to open the app until you trust the developer certificate: on your iPhone go to **Settings → General → VPN & Device Management**, tap your Apple ID under "Developer App", and tap **Trust**.
7. Reopen the app from your Home Screen — it should launch normally from now on.

With a free Personal Team, the install expires after about 7 days (Apple's free-signing limit) — just re-run from Xcode with your phone connected to reinstall.

### Adding the widget

After installing the app once, long-press your Home Screen → **+** → search "Clarity" to add the budget gauge widget.

## Optional: AI Categorization Setup

Automatic transaction categorization and spending insights call the Anthropic API and need a key in `FinanceTracker/Secrets.plist` (gitignored — never committed):

```xml
<key>ANTHROPIC_API_KEY</key>
<string>YOUR_KEY_HERE</string>
```

The app runs fine without this file — those specific AI-powered features are simply skipped if no key is present.

## Secret Scanning (GitGuardian)

This repo is protected against accidentally committing API keys, credentials, or other secrets in two layers:

1. **`.gitignore`** excludes `Secrets.plist`, `.env` files, certificates (`.pem`, `.p12`, `.cer`, `.mobileprovision`), and similar sensitive file patterns outright.
2. **[GitGuardian](https://www.gitguardian.com)** scans every commit and every push/PR for secrets that slip through anyway (a key pasted into source, a token in a comment, etc.):
   - **Locally:** a pre-commit hook (via [`ggshield`](https://github.com/GitGuardian/ggshield)) blocks a commit if it contains a detected secret.
   - **In CI:** [`.github/workflows/gitguardian.yml`](.github/workflows/gitguardian.yml) re-scans every push to `main` and every pull request.

### One-time setup (per machine)

```bash
brew install gitguardian/tap/ggshield
cd FinanceTracker   # repo root
ggshield install -m local   # installs the local pre-commit hook
ggshield auth login         # free GitGuardian account, opens a browser to authenticate
```

### One-time setup (CI, repo owner only)

1. Create a free account at [dashboard.gitguardian.com](https://dashboard.gitguardian.com) and generate a **Personal Access Token** (or API key) with `scan` scope.
2. Add it to the GitHub repo as a secret: **Settings → Secrets and variables → Actions → New repository secret**, named `GITGUARDIAN_API_KEY`.

Without that repo secret, the CI workflow step will simply fail (nothing breaks locally) until it's added.

## Known Limitations

- **CloudKit sync is currently deactivated.** The app signs with `FinanceTracker-LocalOnly.entitlements` (App Groups only), so all data is local to the device — nothing syncs via iCloud right now. The collaborative shared-expense sync code exists in the codebase behind a feature flag but is not yet enabled.
