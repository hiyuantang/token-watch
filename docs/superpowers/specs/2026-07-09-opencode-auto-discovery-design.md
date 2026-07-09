# OpenCode provider + auto-discovery + file-watching — design

> **Supersedes** `2026-07-09-file-system-driven-refresh-design.md`. That earlier design kept the
> App Sandbox and `FolderAccessStore` per-provider folder picker. This design drops the sandbox and
> auto-discovers all three providers, folding file-watching in as one unified change. The older
> spec and its implementation plan are obsolete; delete both once this one ships.

## Problem

Token Watch supports Claude Code and Codex today. We want to add **OpenCode** as a third provider
and make the app feel live — stats update ~0.5s after a transcript changes, instead of the current
60s poll. Both improvements are blocked by the same thing: the current posture (App Sandbox +
per-provider `NSOpenPanel` folder picker + security-scoped bookmarks) makes adding a third provider
another round of folder-picker UX, and keeps a fixed 60s `Task.sleep` timer in `UsageStore`.

A secondary goal: **remove all dead code** that this change leaves behind — `FolderAccessStore`,
the folder-picker UI, the per-provider bookmark machinery, the `selectedFolderName` enum property,
and the `SourcesView` that exists only to host the folder picker.

## Decisions

1. **Drop `com.apple.security.app-sandbox`.** The app reads three well-known paths directly, no
   folder picker. The privacy audit (`script/audit_privacy.sh`) is unchanged — it only checks for
   network entitlements/APIs, neither of which is introduced. The app stays local-only and
   network-free; it just is no longer sandboxed. This matches the posture of the reference repo
   (Javis603/token-monitor, an Electron app).

2. **Add OpenCode as a third `UsageProvider`.** OpenCode stores everything in SQLite
   (`~/.local/share/opencode/opencode.db`), not JSONL. Token Watch reads it via the system
   `/usr/bin/sqlite3` CLI invoked as a read-only `Process` that returns JSON. **Zero new
   dependencies, zero build-system changes** — `sqlite3` ships with macOS and `Process` is not a
   networking API, so the privacy audit invariant holds.

3. **Replace the 60s poll with `FSEventStream` file-watching.** One `FSEventStream` per provider
   directory, `latency = 0.5s`, scheduled on the main run loop. The kernel coalesces bursts into
   one callback — that *is* the debounce. No custom timer code. OpenCode is watched at the
   directory level (an append to `opencode.db-wal` fires the event, triggering a re-scan).

4. **Session-level granularity for OpenCode.** One `UsageEvent` per row in the `session` table,
   timestamped at `time_updated`, carrying the session's cumulative token totals. This matches the
   existing `UsageEvent` shape and how Claude/Codex already emit one event per turn. Per-message
   parsing from the `message` table is explicitly out of scope for this change.

5. **Model display = just the `id`.** OpenCode stores `model` as JSON like
   `{"id":"glm-5.2","providerID":"ollama-cloud","variant":"max"}`. Decode only `id`; display
   `"glm-5.2"`. Matches how Claude/Codex show just the model name without provider noise.

6. **Remove all dead code** left behind by the above: `FolderAccessStore`, `SourcesView`,
   folder-picker UI in `SettingsView`, `chooseFolder`/`revokeFolder` on `UsageStore`,
   `selectedFolderName` on `UsageProvider`, the `FolderAccessError` type, the old 60s
   `refreshTimer`, and the superseded 2026-07-09 spec/plan.

## Architecture

```
launch → UsageStore.start()
         ├─ refresh()                           (one fast scan of all 3 paths → initial totals)
         └─ for each provider path that exists:
            watcher.start(for: provider, directory: <path>)
                                              │
FSEventStream (per provider dir, latency=0.5s) │
   └─ TranscriptWatcher.onChange ──────► UsageStore.refresh()
                                              │
TranscriptScanner.scan(claudeRoot:, codexRoot:, openCodeRoot:)
   ├─ Claude JSONL parser   (unchanged)
   ├─ Codex JSONL parser    (unchanged)
   └─ OpenCodeScanner.scan(root:)  ── Process ── /usr/bin/sqlite3 -json -readonly opencode.db
                                              │
UsageAggregator.snapshot() ── @Published ── SwiftUI re-renders
```

**Auto-discovery replaces folder picking.** Three well-known paths, resolved by a tiny
`ProviderPaths` helper, no user interaction:

| Provider    | Path                                       |
| ----------- | ------------------------------------------ |
| Claude Code | `~/.claude/`                               |
| Codex       | `~/.codex/`                                |
| OpenCode    | `$XDG_DATA_HOME/opencode` or `~/.local/share/opencode` |

A path that doesn't exist → `SourceState.missingExpectedDirectory` (existing state reused), zero
events from that provider. No error, no user prompt.

## Components

### `ProviderPaths` (new) — `TokenWatch/Services/ProviderPaths.swift`

A pure enum namespace, ~15 lines. Replaces every `FolderAccessStore.url(for:)` call site.

```swift
enum ProviderPaths {
    static func claudeRoot() -> URL?             // ~/.claude
    static func codexRoot() -> URL?              // ~/.codex
    static func openCodeRoot() -> URL?           // $XDG_DATA_HOME/opencode or ~/.local/share/opencode
    static func root(for provider: UsageProvider) -> URL?  // dispatch over the three above
}
```

Each method returns `nil` if the directory is absent. `openCodeRoot()` honors `XDG_DATA_HOME` if
set (matches the reference repo's `resolveDataDir`), falling back to `~/.local/share/opencode`.
`root(for:)` is a thin switch used by `UsageStore.start()` to iterate `UsageProvider.allCases`.

### `OpenCodeScanner` (new) — `TokenWatch/Services/OpenCodeScanner.swift`

A `Sendable` struct, sibling to `TranscriptScanner`. Single responsibility: read the `session`
table from `opencode*.db` files via the `sqlite3` CLI.

```swift
struct OpenCodeScanner: Sendable {
    func scan(root: URL?, now: Date = Date()) -> ScanResult
}
```

- **DB discovery:** in `root`, find every file matching `opencode.db` or
  `opencode-<channel>.db` where `channel` is `[A-Za-z0-9._-]+` (matches the reference repo's
  `isOpenCodeDbFilename`). Excludes WAL/SHM/journal sidecars. `root == nil` or absent →
  `SourceState.missingExpectedDirectory`, empty events.

- **Per db file:** run `/usr/bin/sqlite3 -json -readonly <db> "<query>"` via `Process`, capture
  stdout, decode as `[OpenCodeSessionRow]`. Query:

  ```sql
  SELECT id, model, tokens_input, tokens_output, tokens_cache_read,
         tokens_cache_write, tokens_reasoning, time_updated
  FROM session
  ORDER BY time_updated ASC
  ```

  Only whitelisted columns are selected. **`cost` and `data` (message text) are deliberately not
  selected** — preserves the privacy boundary.

- **Private Decodable shapes** (snake_case via `CodingKeys`, same convention as `CodexTokenInfo`):

  ```swift
  private struct OpenCodeSessionRow: Decodable {
      let id: String
      let model: String          // JSON string: {"id":"glm-5.2","providerID":"...","variant":"..."}
      let tokensInput: Int
      let tokensOutput: Int
      let tokensCacheRead: Int
      let tokensCacheWrite: Int
      let tokensReasoning: Int
      let timeUpdated: Int       // epoch ms
  }
  private struct OpenCodeModel: Decodable { let id: String? }
  ```

- **Event mapping** — one `UsageEvent` per row:
  - `provider: .openCode`
  - `timestamp: Date(timeIntervalSince1970: TimeInterval(timeUpdated) / 1000)`
  - `model:` decode the `model` JSON string, take `id`; on malformed JSON → `"Unknown model"` and
    `malformedLines += 1` (same convention as Codex)
  - `sessionToken: UUID()` cached per `row.id` (mirrors Claude/Codex session-token handling so
    the "Sessions" metric counts distinct sessions correctly)
  - `usage: TokenUsage(input:, output:, cacheRead:, cacheWrite:, reasoningOutput:, recordedTotal: nil)`
    — `recordedTotal` defaults to `input + output + cacheRead + cacheWrite`; reasoning stays
    informational (matches the reference repo's session-card convention, same as Codex)

- **Health bookkeeping** (mirrors the existing scanner): `scannedFiles` = number of db files
  touched; `usageRecords` = number of session rows emitted; `malformedLines` = rows whose model
  JSON failed to decode; `unreadableFiles` = db files `sqlite3` couldn't open (non-zero exit or
  unparseable stdout).

- **Failure modes:**
  - `/usr/bin/sqlite3` missing (hypothetically, on a non-standard macOS) → provider reports
    `SourceState.inaccessible`, no crash.
  - WAL mode is safe — `sqlite3 -readonly` reads through the WAL without issue.
  - Empty `session` table → `.ready` with zero records (not an error).

### `TranscriptScanner` (modified) — `TokenWatch/Services/TranscriptScanner.swift`

Gains an `openCodeRoot` parameter:

```swift
func scan(claudeRoot: URL?, codexRoot: URL?, openCodeRoot: URL?, now: Date = Date()) -> ScanResult
```

Internally calls `OpenCodeScanner().scan(root: openCodeRoot, now: now)` and folds its events +
`SourceHealth` into the shared accumulators (same pattern as `scanClaude`/`scanCodex`). The JSONL
parsing helpers (`streamLines`, `parseTimestamp`, `jsonlFiles`, `directoryExists`) are unchanged
and still used by the Claude/Codex paths.

### `TranscriptWatcher` (new) — `TokenWatch/Services/TranscriptWatcher.swift`

Carried over from the superseded design, unchanged in shape:

```swift
@MainActor final class TranscriptWatcher {
    var onChange: ((UsageProvider) -> Void)?
    func start(for provider: UsageProvider, directory: URL)
    func stop(for provider: UsageProvider)
    func stopAll()
    func isWatching(for provider: UsageProvider) -> Bool
}
```

- One `FSEventStream` per provider, flags `[.fileEvents, .watchRoot]`, `latency = 0.5`, scheduled
  on the main run loop (`kCFRunLoopMain`) so callbacks arrive on the main actor.
- Per-stream `WatchInfoBox` carries the `UsageProvider` so `onChange` receives the correct
  provider (the superseded plan's Task 3 fix).
- **No-sandbox note:** `TranscriptWatcher.start` calls `directory.startAccessingSecurityScopedResource()`.
  With the sandbox gone, that call is a harmless no-op on plain paths (returns `true`). The
  `securityScope` field is vestigial but harmless — kept to avoid churn against the superseded
  plan's already-written implementation; a follow-up could drop it. **No code change required.**

### `UsageStore` (modified) — `TokenWatch/Stores/UsageStore.swift`

- **Delete** `refreshTimer: Task<Void, Never>?`, its `deinit` cancel, and the 60s `Task.sleep` loop.
- **Delete** `chooseFolder(for:)` and `revokeFolder(for:)` — folder picking is gone.
- **Add** `private let watcher = TranscriptWatcher()`.
- **Add** `func manualSync()` — public; calls `refresh()`. Used by the Settings "Sync Now" button.
- `start()`:
  ```swift
  func start() {
      watcher.onChange = { [weak self] _ in self?.refresh() }
      refresh()
      for provider in UsageProvider.allCases {
          if let url = ProviderPaths.root(for: provider) {
              watcher.start(for: provider, directory: url)
          }
      }
  }
  ```
  (`ProviderPaths.root(for:)` is a convenience dispatch over the three methods.)
- `refresh()`: simplified — no more `FolderAccessStore.url(for:)`, no more
  `startAccessingSecurityScopedResource`/`stopAccessingSecurityScopedResource` toggling. Resolve
  the three paths via `ProviderPaths`, hand them to `TranscriptScanner.scan(claudeRoot:codexRoot:openCodeRoot:)`.
- `deinit`: `watcher.stopAll()`.

### `UsageProvider` (modified) — `TokenWatch/Models/UsageModels.swift`

- **Add** `.openCode` case.
  - `displayName = "OpenCode"`
  - `expectedRelativeDirectory = "."` (kept for enum exhaustiveness; `OpenCodeScanner` scans the
    root directly rather than appending a subdir, so this is unused but must not break the enum)
- **Delete** `selectedFolderName` — only callers were `FolderAccessStore` + `SettingsView`'s
  folder section, both deleted. Dead property removed.
- Keep `expectedRelativeDirectory` — still used by Claude/Codex scanners.

### `Views` (modified + deleted)

- **Delete** `SourcesView.swift` — it existed only to host the folder picker + revoke flow + health
  rows, all of which are gone. Move its "Privacy boundary" `Label` rows (no network / no prompts /
  no cost) into `SettingsView`'s privacy section before deleting.
- **`SettingsView.swift` rewritten:**
  - Delete the "Local data access" section (the per-provider `Choose Folder` rows).
  - Keep the "Refresh" section — new copy: "Token Watch auto-discovers `~/.claude`, `~/.codex`,
    and `~/.local/share/opencode` on launch and updates automatically when local transcript files
    change. Use Sync Now if anything looks out of date." + a "Sync Now" button bound to
    `store.manualSync()`, disabled while `store.isRefreshing`.
  - Keep the "Privacy and status" section; append the moved privacy-boundary labels. Update the
    affiliation disclaimer to mention OpenCode: "Token Watch is not affiliated with or endorsed by
    Anthropic, OpenAI, or OpenCode."
- **`DashboardView.swift`:**
  - Remove the `Sources` case from `DashboardSection` (the enum + its `allCases` list + the
    `case .sources: SourcesView(store: store)` switch arm). With `SourcesView` deleted, this
    section has nowhere to navigate.
  - Reword the `ContentUnavailableView` description in the empty-timeline branch: from "Choose
    your Claude Code or Codex folder in Sources to begin." to "Open Claude Code, Codex, or
    OpenCode to begin recording token metadata."
  - The provider-split `GroupBox` ternary `provider == .claudeCode ? "sparkles" : "terminal"` →
    add `.openCode` with symbol `"curlybraces"`. Use a `switch` instead of nested ternaries.
- **`ModelsView.swift` + `MenuBarPopover.swift`:** same ternary fix — add `.openCode` with
  `"curlybraces"`. Use a `switch`.
- **`MenuBarLabel`:** no change — it already shows the total across all providers generically.

### `TokenWatch.entitlements` (modified)

Delete both keys. The file becomes:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
```

`CODE_SIGN_ENTITLEMENTS` in `project.pbxproj` (build configs `A80000000000000000000003` /
`A80000000000000000000004`) keeps pointing at the now-empty `TokenWatch.entitlements` file —
leaving it avoids pbxproj churn, and an empty entitlements dict is a no-op. (If a follow-up wants
to delete the setting entirely, that's safe too; not required for this change.)

### `README.md` (modified)

Rewrite the "Local-only boundary" section:

- Replace "You explicitly select the `.claude` and `.codex` folders; the app requests read-only,
  sandbox-scoped access." with "The app auto-discovers `~/.claude/projects/`, `~/.codex/sessions/`,
  and `~/.local/share/opencode/opencode.db` on launch. Access is read-only; the app declares no
  network entitlement."
- Add OpenCode to the path list and the JSONL/SQLite distinction note.
- Update the affiliation disclaimer to add OpenCode.
- Drop the "sandbox" wording; keep the "local-only, no network" wording — that part is still true.

### `project.pbxproj` (modified)

Remove two files, add four source files + two test files.

**Remove:**
- `A10000000000000000000003` (FolderAccessStore.swift build-file) + its file-ref
  `A20000000000000000000003`; drop `A10000000000000000000003` from the app Sources phase
  `A60000000000000000000001` `files` list; drop the ref from the Services group
  `A30000000000000000000007` children list.
- `A10000000000000000000009` (SourcesView.swift build-file) + its file-ref
  `A20000000000000000000009`; drop from the app Sources phase and the Views group
  `A30000000000000000000009` children list.

**Add (next free synthetic IDs):**

| ID (build-file)                 | File ref                         | File                          |
| ------------------------------- | -------------------------------- | ----------------------------- |
| `A10000000000000000000016`      | `A20000000000000000000019`       | `TranscriptWatcher.swift`     |
| `A10000000000000000000017`      | `A20000000000000000000020`       | `OpenCodeScanner.swift`       |
| `A10000000000000000000018`      | `A20000000000000000000021`       | `ProviderPaths.swift`         |
| `A10000000000000000000019`      | `A20000000000000000000022`       | `UsageStoreSyncTests.swift` (from superseded plan) |
| `A10000000000000000000020`      | `A20000000000000000000023`       | `TranscriptWatcherTests.swift` (from superseded plan) |
| `A10000000000000000000021`      | `A20000000000000000000024`       | `OpenCodeScannerTests.swift`  |

- `TranscriptWatcher.swift`, `OpenCodeScanner.swift`, `ProviderPaths.swift` → added to the
  Services group `A30000000000000000000007` and the app Sources phase
  `A60000000000000000000001`.
- `OpenCodeScannerTests.swift`, `TranscriptWatcherTests.swift`, `UsageStoreSyncTests.swift` →
  added to the `TokenWatchTests` group `A30000000000000000000003` and the test Sources phase
  `A60000000000000000000004`.

The synthetic-ID scheme continues the convention: `A100…` = build files, `A200…` = file refs,
`A300…` = groups, `A600…` = build phases.

### Dead-code removal — complete list

| File / symbol                     | Why dead                                       |
| --------------------------------- | ----------------------------------------------- |
| `TokenWatch/Services/FolderAccessStore.swift` (whole file) | No more folder picking; no bookmarks.           |
| `FolderAccessError` (in same file) | Only used by `FolderAccessStore`.               |
| `TokenWatch/Views/SourcesView.swift` (whole file) | Existed only to host the folder picker UI.     |
| `UsageStore.chooseFolder(for:)`   | No folder picking.                              |
| `UsageStore.revokeFolder(for:)`    | No folder revocation.                           |
| `UsageStore.refreshTimer` + 60s `Task.sleep` loop | Replaced by `TranscriptWatcher`.               |
| `UsageProvider.selectedFolderName` | Only callers were `FolderAccessStore` + `SettingsView` folder section. |
| `SettingsView` "Local data access" section | Folder picker UI removed.                       |
| `DashboardSection.sources` case + its switch arm + nav | `SourcesView` deleted; nowhere to navigate.    |
| `docs/superpowers/specs/2026-07-09-file-system-driven-refresh-design.md` | Superseded by this doc. |
| `docs/superpowers/plans/2026-07-09-file-system-driven-refresh.md` | Superseded; new plan will be generated from this spec. |

**Confirmation grep after implementation:** `rg 'FolderAccessStore|chooseFolder|revokeFolder|selectedFolderName|refreshTimer|Task.sleep' TokenWatch/` should return nothing.

## Data flow

1. App launches → `UsageStore.start()` → `refresh()` scans all three paths → menu bar shows
   initial totals immediately.
2. `start()` registers a `TranscriptWatcher` for each path that exists.
3. User runs Claude Code / Codex / OpenCode → a `.jsonl` is appended, or `opencode.db-wal`
   grows → FSEventStream coalesces within 0.5s → fires one callback.
4. `TranscriptWatcher.onChange(provider)` → `UsageStore.refresh()` → `TranscriptScanner.scan()`
   (Claude/Codex JSONL + OpenCode `sqlite3` subprocess) → `UsageAggregator.snapshot()` →
   `@Published` update → SwiftUI re-renders menu bar + dashboard.
5. "Sync Now" button in Settings → `store.manualSync()` → `refresh()` (covers the rare gap after
   sleep/remount where an FSEvents event was missed).

## Error handling

- **Path absent:** `ProviderPaths.<provider>Root()` returns `nil` → that provider reports
  `SourceState.missingExpectedDirectory`, zero events. No error, no prompt.
- **`/usr/bin/sqlite3` missing:** `OpenCodeScanner` catches the missing-binary case and reports
  `SourceState.inaccessible` for OpenCode; Claude/Codex are unaffected.
- **DB unreadable** (corrupt, locked beyond `PRAGMA busy_timeout`): counted as
  `unreadableFiles += 1`; other db files in the same directory are still scanned.
- **Malformed model JSON:** row counted as `malformedLines += 1`; the event still emits with
  `model = "Unknown model"` (so the session still counts toward totals), matching Codex.
- **Stream recovery flags** (`.rootChanged`, `.mustScanSubDirs`): forwarded to `onChange` →
  automatic recovery from remounts/renames.
- **App suspended/resumed:** FSEvents delivers a catch-up event on resume. "Sync Now" covers the
  rare gap.

## Testing

**New: `OpenCodeScannerTests.swift`** — uses the same `sqlite3` CLI to create a temp `opencode.db`
and insert fixture rows, then scans. Covers:
- Happy path: session rows → events with correct model id, token totals, timestamp.
- Missing `opencode` dir → `.missingExpectedDirectory`, empty events.
- Malformed `model` JSON → `"Unknown model"`, `malformedLines > 0`.
- Multiple db files (`opencode.db` + `opencode-staging.db`) aggregated.
- Unreadable db (write garbage to a `.db` file) → `unreadableFiles > 0`, other files still scanned.

**Modified: `UsageScannerTests.swift`** — existing `testClaude…`/`testCodex…` tests pass
`openCodeRoot: nil` (add the parameter; no behavior change). Add one test exercising all three
providers merging through `TranscriptScanner.scan(claudeRoot:codexRoot:openCodeRoot:)`.

**Modified: `UsageSnapshotTests.swift`** — `testEmptySnapshotProvidesBothProviders` asserts
`providers.count == 2`; with `.openCode` added, `UsageProvider.allCases` grows to 3 → update to 3
and rename to `testEmptySnapshotProvidesAllProviders`. Other tests unchanged (they use
`.claudeCode`/`.codex` events directly).

**From the superseded plan, carried over unchanged:** `TranscriptWatcherTests.swift` (lifecycle +
per-stream provider identity) and `UsageStoreSyncTests.swift` (`manualSync` triggers a refresh).

**Verification commands** (unchanged from repo convention):

```sh
./script/audit_privacy.sh
./script/build_and_run.sh --verify
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS,arch=arm64' test
```

## Out of scope

- Per-message OpenCode parsing from the `message` table (session-level only, per decision 4).
- OpenCode cost / quota / account-limit tracking (Token Watch deliberately tracks neither costs
  nor quotas for any provider; this stays consistent).
- Removing the vestigial `securityScope` field from `TranscriptWatcher` — harmless, left to avoid
  churn against the superseded plan's implementation; a follow-up can drop it.
- Any change to `TokenFormatting`, `MetricCard`, or the menu-bar label — they're provider-generic.

## Acceptance

- `UsageProvider.allCases` contains `.claudeCode`, `.codex`, `.openCode`.
- Launching the app with all three sources present shows non-zero totals from each within ~1s.
- A change to `~/.claude/projects/*.jsonl`, `~/.codex/sessions/*.jsonl`, or
  `~/.local/share/opencode/opencode.db` updates stats within ~1s on a running app (no 60s wait).
- `./script/audit_privacy.sh` passes (no network entitlements, no networking APIs — `Process` is
  not a networking API).
- `./script/build_and_run.sh --verify` passes.
- `xcodebuild … test` passes.
- `rg 'FolderAccessStore|chooseFolder|revokeFolder|selectedFolderName|refreshTimer|Task.sleep' TokenWatch/` returns nothing.
- `SourcesView.swift` no longer exists; `FolderAccessStore.swift` no longer exists.
- The superseded spec and plan files are deleted.