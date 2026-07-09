# File-system-driven refresh — design

## Problem

`UsageStore` refreshes on a fixed 60-second poll loop (`TokenWatch/Stores/UsageStore.swift:18-27`). Transcript files can change at any moment; a minute of stale stats is noticeable, and re-scanning every 60s regardless of activity wastes work when nothing has changed.

## Decision

Replace the 60s poll with **FSEventStream**-based file-system watching. Updates fire ~0.5s after a transcript file actually changes. A manual "Sync Now" button in Settings covers the rare case where an event is missed. No periodic timer remains.

## Architecture

```
FSEventStream (per provider dir, latency=0.5s)
  -> TranscriptWatcher (encapsulates stream lifecycle, coalesces callbacks)
    -> UsageStore.refresh()  (unchanged scan + aggregate path)
```

Only the *trigger* for `refresh()` changes. Scanning, aggregation, models, and the privacy audit are untouched.

## Components

### `TranscriptWatcher` (new) — `TokenWatch/Services/TranscriptWatcher.swift`

One `FSEventStream` per provider that has a configured folder.

- Flags: `.fileEvents | .watchRoot`. Do **not** set `.noDefer` — the OS coalesces all events within the `latency` window into one callback, which *is* the 0.5s debounce at the kernel level (no custom timer code).
- `latency = 0.5` seconds.
- Scheduled on the main run loop (`FSEventStreamScheduleWithRunLoop(..., .main, ...)`); the change callback is invoked on the main actor so `UsageStore` can mutate `@Published` state directly.
- Holds the security-scoped resource (`startAccessingSecurityScopedResource`) for the stream's lifetime; releases it on stop. Cleaner than the current per-refresh start/stop toggling in `refresh()`.
- Public API:
  - `func start(for url: URL, provider: UsageProvider)` — create + start the stream for one provider.
  - `func stop(for provider: UsageProvider)` — stop + release that provider's stream.
  - `func stopAll()` — stop everything (used in `deinit` and on app teardown).
  - `var onChange: ((UsageProvider) -> Void)?` — set by `UsageStore`; fired on any coalesced change event, including system recovery flags.
- `Sendable`-careful: the stream object is not `Sendable`; ownership stays on the main actor.
- Forwards `FSEventStreamEventFlags` recovery signals (`.rootChanged`, `.mustScanSubDirs`) to `onChange` as well — these are the system's own "rescan" signal, so remounts/renames recover automatically.

### `UsageStore` (modified) — `TokenWatch/Stores/UsageStore.swift`

- Delete `refreshTimer: Task<Void, Never>?` and its 60s `Task.sleep` loop.
- Add `private let watcher = TranscriptWatcher()`.
- `start()`:
  - Call `refresh()` once (initial load).
  - For each provider with a configured folder (`FolderAccessStore.url(for:)` != nil), call `watcher.start(for:provider:)`.
  - Set `watcher.onChange = { [weak self] _ in self?.refresh() }`.
- `refresh()`: unchanged except it no longer needs to call `startAccessingSecurityScopedResource`/`stopAccessingSecurityScopedResource` per refresh — the watcher holds the scope for the stream's lifetime. (If a one-off manual refresh runs while the watcher holds the scope, the scan proceeds fine; security-scoped URLs are re-entrant for reads. Keep the existing `startAccessingSecurityScopedResource` guard in `refresh()` for the no-watcher / not-yet-started case — it is a no-op when already in scope.)
- `chooseFolder(for:)`: on `.success`, call `watcher.start(for:)` (replaces any existing stream for that provider) in addition to the existing `refresh()`.
- `revokeFolder(for:)`: call `watcher.stop(for:)` in addition to existing event-removal logic.
- New `func manualSync()` — public, calls `refresh()`. Single scanning path; used by the Settings "Sync Now" button.
- `deinit`: `watcher.stopAll()` (replaces the old timer cancel).

### `SettingsView` (modified) — `TokenWatch/Views/SettingsView.swift`

- Replace the "Refresh" section (lines 23-26, which currently says "every 60 seconds while running") with:
  - Short text: updates happen automatically when transcript files change; plus a **"Sync Now"** button.
  - Button bound to `store.manualSync()`.
  - Button disabled while `store.isRefreshing` (existing published flag).

## Data flow

1. Transcript `.jsonl` appended (or created/renamed) in a watched directory.
2. FSEventStream coalesces events within 0.5s → fires one callback.
3. `TranscriptWatcher.onChange` → `UsageStore.refresh()`.
4. Existing scan → aggregate → `@Published` update → SwiftUI re-renders menu bar + dashboard.

## Error handling

- **No folder configured**: watcher not started; no-op. Existing `chooseFolder` path starts it.
- **Folder revoked mid-run**: `watcher.stop(for:)` stops that provider's stream; existing event-removal logic runs unchanged.
- **Stream recovery flags** (`.rootChanged`, `.mustScanSubDirs`): forwarded to `refresh()` — automatic recovery from remounts/renames.
- **App suspended/resumed**: FSEvents delivers a catch-up event on resume. Manual "Sync Now" covers the rare gap.
- **Stale security scope**: handled by FSEventStream's `.withSecurityScope` bookmark resolution; the watcher's held scope is the source of truth.

## Testing

Existing tests cover `TranscriptScanner` and `UsageAggregator` — those don't change. New test surface:

- `TranscriptWatcher` lifecycle: start/stop/restart do not leak streams; `stopAll` cleans up. (Unit test with a temp directory.)
- `UsageStore.manualSync()` calls `refresh()` exactly once.
- Optional / skipped: a full FSEvents integration test (append to a temp `.jsonl`, assert `refresh()` fires) — skipped because FSEvents timing is flaky in CI.

Run with:

```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS,arch=arm64' test
```

## Out of scope

- No changes to `TranscriptScanner`, `UsageAggregator`, models, views (other than Settings), or the privacy audit.
- No change to menu-bar label or dashboard views — they already react to `@Published`.
- No network or persistence changes.

## Acceptance

- No `Task.sleep`-based timer remains in `UsageStore`.
- A change to a watched `.jsonl` updates stats within ~1s on a running app.
- "Sync Now" button in Settings triggers an immediate refresh and is disabled while a refresh is in flight.
- `./script/audit_privacy.sh` and `./script/build_and_run.sh --verify` still pass.
- Tests pass.