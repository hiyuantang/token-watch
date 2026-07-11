# AGENTS.md

Token Watch is a macOS 26+ SwiftUI menu-bar app that reads token-usage metadata already present in local Claude Code, Codex, and OpenCode data. Single Xcode project, two targets (`TokenWatch` app, `TokenWatchTests`). No packages, no codegen, no migrations.

## Build, audit, test

```sh
# Privacy gate — MUST pass before any build. Fails on network entitlements or
# networking APIs (URLSession|URLRequest|NWConnection|NWPathMonitor|WebSocket|HTTPClient).
./script/audit_privacy.sh

# Build + launch (audit runs first). Modes: run | --verify | --debug | --logs | --telemetry
# --verify opens the app, waits 1s, checks it's alive, then kills it — use after parser/UI edits.
./script/build_and_run.sh --verify

# Full test suite (unsigned Debug, arm64, derived data under build/DerivedData)
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' test

# Single test
xcodebuild ... test -only-testing:TokenWatchTests/UsageScannerTests/testClaudeAssistantUsageIsDeduplicatedAndMalformedLinesAreReported
```

`audit_privacy.sh` shells out to `rg` (ripgrep) — it must be installed. The app target is intentionally unsigned `Debug` with no App Sandbox and an empty `TokenWatch.entitlements`; select a signing team only when distributing a bundle.

## Hard invariants — do not break these

- **No networking, ever.** No network entitlement, no networking API. The privacy audit is part of `build_and_run.sh`; any new Swift file under `TokenWatch/` that touches `URLSession`/`URLRequest`/`NWConnection`/`NWPathMonitor`/`WebSocket`/`HTTPClient` will fail the build. This is the product's core promise — see `README.md`.
- **Read-only transcript access.** Scanners only decode whititelisted timestamp/model/token-usage fields. Prompts, responses, source code, paths, real session IDs, credentials, and account data are never read, displayed, or persisted.
- **`UsageEvent.sessionToken` is an in-memory UUID, not a provider session ID.** It exists only to group events in the UI; never persist it or expose the provider's real session ID.

## Architecture

- `TokenWatch/App/TokenWatchApp.swift` — `@main`. `LSUIElement` (menu-bar only, no Dock). Two scenes: `MenuBarExtra` (`.window` style) and `WindowGroup("dashboard")`. Owns `UsageStore` as `@StateObject` and calls `store.start()` in `init`.
- `TokenWatch/Stores/UsageStore.swift` — `@MainActor final class ObservableObject`. `start()` registers one `FSEventStream` per provider and runs `refresh()`. `refresh()` runs a full scan inside `Task.detached(priority: .utility)`. `refreshProvider(_)` does an incremental single-provider rescan (used by the watcher so one provider's change doesn't rescan the other two). `snapshot(for:)` builds `UsageSnapshot` and computes cost in the same pass via `Pricing.rate(for:)`.
- `TokenWatch/Services/TranscriptScanner.swift` — Reads JSONL as byte chunks (`FileHandle` 64KB, line-by-line). `scan(claudeRoot:codexRoot:openCodeRoot:)` for all three; `scanProvider(_:root:)` for the watcher path. Three private impls:
  - **Claude**: dedup by message `uuid` (fallback `sessionId|timestamp|message.id`); skip `<synthetic>` model entries; only `type == "assistant"` with `message.usage`.
  - **Codex**: cumulative-total deltas via `TokenUsage.delta(from:)` (monotonic required); model comes from the most recent `turn_context` record; non-monotonic rows fall back to `last_token_usage` fingerprinted against duplicates. Only `type == "event_msg"` with `payload.type == "token_count"`.
  - **OpenCode**: delegates to `OpenCodeScanner`.
- `TokenWatch/Services/OpenCodeScanner.swift` — Shells out to `/usr/bin/sqlite3 -json -readonly` (NOT the SQLite library). Reads `id, model, tokens_*, time_updated` from the `session` table. `model` is stored as JSON `{"id": "..."}` and decoded separately. Keep the CLI approach — it preserves the no-link, read-only stance and matches the tests.
- `TokenWatch/Services/TranscriptWatcher.swift` — `@MainActor`. One `FSEventStreamCreate` per provider directory (latency 0.5s, file events). Callback hops to the main run loop via `DispatchQueue.main.async`; `onChange: ((UsageProvider) -> Void)?` is the only outward signal.
- `TokenWatch/Services/ProviderPaths.swift` — Home-relative roots. `openCodeRoot()` honors `XDG_DATA_HOME` then `~/.local/share/opencode`; Claude is `~/.claude`; Codex is `~/.codex`. Each provider's subdirectory is `UsageProvider.expectedRelativeDirectory` (`projects` / `sessions` / `.`).
- `TokenWatch/Models/UsageModels.swift` — Pure data types: `UsageProvider` (3 cases), `UsageRange`, `TokenUsage` (with monotonic `delta(from:)` returning `nil` on regression), `UsageEvent`, `SourceHealth`/`SourceState`, `UsageSnapshot`, `CostEstimate`.
- `TokenWatch/Support/Pricing.swift` — Static hand-maintained catalog. `docs/pricing.md` is the human-readable twin — **keep both in sync**. Matching is case-insensitive substring, first entry wins; **more specific matchers must be registered before looser ones** (e.g. `gpt-5.2` before `gpt-5`; the bare `gpt-5` entry is intentionally placed last in its family with a comment). Unknown models return `nil` and contribute $0; they are tracked via `unpricedModels`/`CostEstimate.unpricedModelCount` so the UI can surface the gap instead of understating cost. Cache writes are charged at the base input rate (no write premium); reasoning output is folded into output cost.

## Toolchain constraints

- **macOS 26.0+ deployment target.** Code uses `MenuBarExtra` `.window` style, `MenuBarLabel`, and recent SwiftUI APIs — do not lower it.
- **Swift 6.0 with `SWIFT_STRICT_CONCURRENCY = complete`** on the app target. Anything touching `UsageStore` or the watcher must be `@MainActor` or `Sendable`; scanning work goes through `Task.detached(priority: .utility)`. Don't weaken this setting.
- Tests use `@testable import TokenWatch` and `TEST_HOST = $(BUILT_PRODUCTS_DIR)/TokenWatch.app/...` — they run hosted in the app. Scanner tests create temp `.claude`/`.codex`/`opencode` dirs and seed the OpenCode DB by shelling out to `/usr/bin/sqlite3`, mirroring `OpenCodeScanner`. `UsageStoreSyncTests` polls up to ~30s for `lastRefresh` — expect it to be slow.

## Do not touch

- `.codex/environments/environment.toml` — autogenerated (see its header). `.codex/` is gitignored.
- `.codegraph/`, `.superpowers/` — tooling scratch, gitignored.

## Conventions

- Keep comments minimal and tied to a non-obvious decision (the existing code follows this). Don't add section-banner comments.
- New sources/models go through `TranscriptScanner`'s private scan methods and surface `SourceHealth` (state, scanned/unreadable/malformed counts, `lastRefresh`). The UI keys off `SourceHealth`, not off "events present".
- When adding a pricing entry, also update `docs/pricing.md` with the source URL and date, and verify ordering with the matching tests in `TokenWatchTests/PricingTests.swift`.