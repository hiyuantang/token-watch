# OpenCode provider + auto-discovery + file-watching — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add OpenCode as a third `UsageProvider` reading session-table totals from `opencode.db` via the system `sqlite3` CLI; drop the App Sandbox and `FolderAccessStore` per-provider folder picker in favor of auto-discovering `~/.claude`, `~/.codex`, and `~/.local/share/opencode`; replace the 60s `Task.sleep` poll with `FSEventStream`-based `TranscriptWatcher` across all three providers; remove all dead code left behind.

**Architecture:** A new `ProviderPaths` enum resolves the three well-known paths. A new `OpenCodeScanner` reads the `session` table from `opencode*.db` files by shelling out to `/usr/bin/sqlite3 -json -readonly` and decoding whitelisted columns. A new `TranscriptWatcher` wraps one `FSEventStream` per provider directory at `latency = 0.5s` and forwards change events to `UsageStore.refresh()`. `UsageStore` loses its 60s timer and folder-picker methods; `UsageProvider` gains `.openCode`; `SourcesView` and `FolderAccessStore` are deleted; `SettingsView`/`DashboardView`/`ModelsView`/`MenuBarPopover` get a `switch` over providers with a `"curlybraces"` symbol for OpenCode. The privacy audit stays unchanged — `Process` is not a networking API.

**Tech Stack:** Swift 6 (strict concurrency), CoreServices `FSEventStream`, Foundation `Process` + `JSONDecoder`, AppKit/SwiftUI, XCTest. Zero third-party dependencies. Zero build-system changes (no SPM packages added).

## Global constraints

- macOS 26+ deployment target; Swift 6.0; `SWIFT_STRICT_CONCURRENCY = complete`.
- App Sandbox is **removed** in this change (entitlements file becomes an empty `<dict/>`). No network entitlement is ever introduced. The privacy audit (`script/audit_privacy.sh`) must keep passing — it only checks for `network.client`/`network.server` entitlements and `URLSession|URLRequest|NWConnection|NWPathMonitor|WebSocket|HTTPClient` APIs. `Process` is not in that list.
- `FSEventStream` is a CoreServices C API. Wrap it in a Swift class owned by `UsageStore` (a `@MainActor` `ObservableObject`). The stream is scheduled on the main run loop so callbacks arrive on the main actor; no cross-actor hops for state mutation.
- The `project.pbxproj` uses hand-maintained synthetic IDs of the form `A1000000000000000000000N` (build files), `A2000000000000000000000N` (file refs), `A3000000000000000000000N` (groups), `A6000000000000000000000N` (build phases). The next free build-file index is **16**; the next free file-ref index is **19**. See the "pbxproj ID allocation" table below for the exact assignments this plan uses.
- No comments in code unless asked (repo convention).
- The superseded spec `docs/superpowers/specs/2026-07-09-file-system-driven-refresh-design.md` and its plan `docs/superpowers/plans/2026-07-09-file-system-driven-refresh.md` are deleted in Task 12.
- The reference repo is https://github.com/Javis603/token-monitor — take ideas only, do not copy code. All code in this plan is original Swift matching this repo's existing style.

### pbxproj ID allocation

| Build-file ID (A100…)            | File-ref ID (A200…)              | File                              | Group / phase                                                |
| -------------------------------- | -------------------------------- | --------------------------------- | ------------------------------------------------------------ |
| `A10000000000000000000016`       | `A20000000000000000000019`       | `TranscriptWatcher.swift`         | Services `A30000000000000000000007`; app Sources `A60000000000000000000001` |
| `A10000000000000000000017`       | `A20000000000000000000020`       | `OpenCodeScanner.swift`           | Services `A30000000000000000000007`; app Sources `A60000000000000000000001` |
| `A10000000000000000000018`       | `A20000000000000000000021`       | `ProviderPaths.swift`             | Services `A30000000000000000000007`; app Sources `A60000000000000000000001` |
| `A10000000000000000000019`       | `A20000000000000000000022`       | `UsageStoreSyncTests.swift`       | Tests `A30000000000000000000003`; test Sources `A60000000000000000000004` |
| `A10000000000000000000020`       | `A20000000000000000000023`       | `TranscriptWatcherTests.swift`    | Tests `A30000000000000000000003`; test Sources `A60000000000000000000004` |
| `A10000000000000000000021`       | `A20000000000000000000024`       | `OpenCodeScannerTests.swift`      | Tests `A30000000000000000000003`; test Sources `A60000000000000000000004` |

**Removals** (free up these IDs by deleting their entries and dropping them from group/phase lists):
- `A10000000000000000000003` / `A20000000000000000000003` — `FolderAccessStore.swift` (from Services group `A30000000000000000000007` + app Sources phase `A60000000000000000000001`).
- `A10000000000000000000009` / `A20000000000000000000009` — `SourcesView.swift` (from Views group `A30000000000000000000009` + app Sources phase `A60000000000000000000001`).

---

## File structure

**Create:**
- `TokenWatch/Services/ProviderPaths.swift` — enum namespace; resolves `~/.claude`, `~/.codex`, `$XDG_DATA_HOME/opencode` or `~/.local/share/opencode`; returns `nil` if absent.
- `TokenWatch/Services/OpenCodeScanner.swift` — `Sendable` struct; reads `session` table from `opencode*.db` via `/usr/bin/sqlite3 -json -readonly`; emits one `UsageEvent` per row.
- `TokenWatch/Services/TranscriptWatcher.swift` — `@MainActor final class`; one `FSEventStream` per provider; `onChange` callback; main-run-loop scheduled.
- `TokenWatchTests/OpenCodeScannerTests.swift` — temp `opencode.db` fixtures via the same `sqlite3` CLI; happy path, missing dir, malformed model JSON, multiple db files, unreadable db.
- `TokenWatchTests/TranscriptWatcherTests.swift` — lifecycle + per-stream provider identity.
- `TokenWatchTests/UsageStoreSyncTests.swift` — `manualSync()` triggers a refresh.

**Modify:**
- `TokenWatch/Models/UsageModels.swift` — add `.openCode` to `UsageProvider`; set `displayName`/`expectedRelativeDirectory`; **delete** `selectedFolderName`.
- `TokenWatch/Services/TranscriptScanner.swift` — `scan(claudeRoot:codexRoot:openCodeRoot:now:)` gains `openCodeRoot`; folds `OpenCodeScanner.scan(root:)` into the shared accumulators.
- `TokenWatch/Stores/UsageStore.swift` — delete `refreshTimer` + 60s loop + `chooseFolder`/`revokeFolder`; own a `TranscriptWatcher`; add `manualSync()`; `start()` auto-discovers + watches.
- `TokenWatch/Views/SettingsView.swift` — delete "Local data access" section; rewrite "Refresh" section with Sync Now button + auto-discovery copy; move privacy-boundary labels here; update affiliation disclaimer.
- `TokenWatch/Views/DashboardView.swift` — remove `DashboardSection.sources` case + switch arm; reword `ContentUnavailableView`; `switch` over providers in the provider-split `GroupBox` with `"curlybraces"` for OpenCode.
- `TokenWatch/Views/ModelsView.swift` — `switch` over providers with `"curlybraces"` for OpenCode.
- `TokenWatch/Views/MenuBarPopover.swift` — `switch` over providers in the Models list with `"curlybraces"` for OpenCode.
- `TokenWatch/TokenWatch.entitlements` — both keys deleted; file becomes empty `<dict/>`.
- `TokenWatchTests/UsageScannerTests.swift` — existing Claude/Codex tests pass `openCodeRoot: nil`; add a three-provider merge test.
- `TokenWatchTests/UsageSnapshotTests.swift` — `testEmptySnapshotProvidesBothProviders` → rename + assert count 3.
- `TokenWatch.xcodeproj/project.pbxproj` — register new files, unregister deleted files (see ID table).
- `README.md` — rewrite "Local-only boundary" for auto-discovery + OpenCode + no-sandbox wording.
- `script/audit_privacy.sh` — no changes (verified in Task 13).

**Delete:**
- `TokenWatch/Services/FolderAccessStore.swift` — whole file (no more folder picking).
- `TokenWatch/Views/SourcesView.swift` — whole file (existed only for folder picker UI).
- `docs/superpowers/specs/2026-07-09-file-system-driven-refresh-design.md` — superseded.
- `docs/superpowers/plans/2026-07-09-file-system-driven-refresh.md` — superseded.

---

### Task 1: Add `TranscriptWatcher` to the project (stub + pbxproj)

**Files:**
- Create: `TokenWatch/Services/TranscriptWatcher.swift`
- Modify: `TokenWatch.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: a compiled (stub) `TranscriptWatcher.swift` referenced in the app module. Full implementation lands in Task 8.

- [ ] **Step 1: Create the stub source file**

Create `TokenWatch/Services/TranscriptWatcher.swift`:

```swift
import Foundation

@MainActor
final class TranscriptWatcher {
}
```

- [ ] **Step 2: Register the file in `project.pbxproj`**

In `TokenWatch.xcodeproj/project.pbxproj`:

1. After the `A10000000000000000000015` build-file entry (line 22), add:

```
		A10000000000000000000016 /* TranscriptWatcher.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000019 /* TranscriptWatcher.swift */; };
```

2. After the `A20000000000000000000018` file-ref entry (line 41), add:

```
		A20000000000000000000019 /* TranscriptWatcher.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TranscriptWatcher.swift; sourceTree = "<group>"; };
```

3. In the Services group (line 49), replace its `children = (...)` list so it reads:

```
		A30000000000000000000007 /* Services */ = {isa = PBXGroup; children = (A20000000000000000000003 /* FolderAccessStore.swift */, A20000000000000000000004 /* TranscriptScanner.swift */, A20000000000000000000019 /* TranscriptWatcher.swift */); path = Services; sourceTree = "<group>"; };
```

4. In the app Sources phase (line 61), append `A10000000000000000000016` to the `files = (...)` list so the end of the list becomes `..., A10000000000000000000012, A10000000000000000000016);`.

- [ ] **Step 3: Verify the project still builds**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED (the stub class compiles and is unused).

- [ ] **Step 4: Commit**

```sh
git add TokenWatch/Services/TranscriptWatcher.swift TokenWatch.xcodeproj/project.pbxproj
git commit -m "Add TranscriptWatcher.swift stub to project"
```

---

### Task 2: Add `ProviderPaths` to the project + implement it

**Files:**
- Create: `TokenWatch/Services/ProviderPaths.swift`
- Modify: `TokenWatch.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `UsageProvider` (from `TokenWatch/Models/UsageModels.swift`; note: `.openCode` is added in Task 4 — this task compiles against the current two-case enum, and the `switch` becomes non-exhaustive only after Task 4, where it will be updated).
- Produces:
  - `enum ProviderPaths` with:
    - `static func claudeRoot() -> URL?` — `~/.claude`
    - `static func codexRoot() -> URL?` — `~/.codex`
    - `static func openCodeRoot() -> URL?` — `$XDG_DATA_HOME/opencode` or `~/.local/share/opencode`
    - `static func root(for provider: UsageProvider) -> URL?` — dispatch over the three above

- [ ] **Step 1: Register the file in `project.pbxproj`**

In `TokenWatch.xcodeproj/project.pbxproj`:

1. After the `A10000000000000000000016` build-file entry, add:

```
		A10000000000000000000018 /* ProviderPaths.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000021 /* ProviderPaths.swift */; };
```

2. After the `A20000000000000000000019` file-ref entry, add:

```
		A20000000000000000000021 /* ProviderPaths.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProviderPaths.swift; sourceTree = "<group>"; };
```

3. In the Services group `A30000000000000000000007`, add `A20000000000000000000021` to the children list so it reads (in any order, but keep existing order + append):

```
		A30000000000000000000007 /* Services */ = {isa = PBXGroup; children = (A20000000000000000000003 /* FolderAccessStore.swift */, A20000000000000000000004 /* TranscriptScanner.swift */, A20000000000000000000019 /* TranscriptWatcher.swift */, A20000000000000000000021 /* ProviderPaths.swift */); path = Services; sourceTree = "<group>"; };
```

4. In the app Sources phase `A60000000000000000000001`, append `A10000000000000000000018` to `files = (...)`.

- [ ] **Step 2: Create the source file**

Create `TokenWatch/Services/ProviderPaths.swift`:

```swift
import Foundation

enum ProviderPaths {
    static func claudeRoot() -> URL? {
        URL(filePath: NSHomeDirectory()).appendingPathComponent(".claude", isDirectory: true)
    }

    static func codexRoot() -> URL? {
        URL(filePath: NSHomeDirectory()).appendingPathComponent(".codex", isDirectory: true)
    }

    static func openCodeRoot() -> URL? {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            URL(fileURLWithPath: xdg).appendingPathComponent("opencode", isDirectory: true)
        } else {
            URL(filePath: NSHomeDirectory())
                .appendingPathComponent(".local/share/opencode", isDirectory: true)
        }
    }

    static func root(for provider: UsageProvider) -> URL? {
        switch provider {
        case .claudeCode: claudeRoot()
        case .codex: codexRoot()
        case .openCode: openCodeRoot()
        }
    }
}
```

> Note: this references `.openCode`, which doesn't exist on the enum yet. The build in Step 3 will fail with "switch must be exhaustive" until Task 4 adds the case. That is expected — Task 4 lands the enum change in the same series. If you prefer the project to build at every commit, add the `.openCode` case to the enum now (Task 4 Step 2) and come back to `ProviderPaths` verification. Either ordering is fine; this plan adds the file first because Task 4 is the enum change and Task 5 will re-verify.

- [ ] **Step 3: Verify the project builds**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```
Expected: **expected to FAIL** with a non-exhaustive switch error against `ProviderPaths.root(for:)` until Task 4 adds `.openCode`. If you want green builds at every commit, do Task 4 Step 2 now and re-run.

> If you chose to keep this commit red, fix it in Task 4 and squash/rebase later. The recommended path is: do Task 4 Step 2 immediately, then commit Task 2 and Task 4 Step 2 together. This plan keeps them as separate commits for reviewability; resolve as you prefer.

- [ ] **Step 4: Commit (only if the build is green; otherwise defer to after Task 4 Step 2)**

```sh
git add TokenWatch/Services/ProviderPaths.swift TokenWatch.xcodeproj/project.pbxproj
git commit -m "Add ProviderPaths for auto-discovering provider data dirs"
```

---

### Task 3: Add `OpenCodeScanner` to the project + write the failing test

**Files:**
- Create: `TokenWatch/Services/OpenCodeScanner.swift` (stub for now)
- Create: `TokenWatchTests/OpenCodeScannerTests.swift`
- Modify: `TokenWatch.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `UsageEvent`, `TokenUsage`, `SourceHealth`, `ScanResult`, `UsageProvider` (all from `TokenWatch/Models/UsageModels.swift`). Requires `.openCode` on `UsageProvider` (added in Task 4) — so the build will only go green after Task 4. Land the stub + test file now; implement in Task 7.
- Produces:
  - `struct OpenCodeScanner: Sendable` with `func scan(root: URL?, now: Date = Date()) -> ScanResult`

- [ ] **Step 1: Register the source file in `project.pbxproj`**

In `TokenWatch.xcodeproj/project.pbxproj`:

1. Add a build-file entry after `A10000000000000000000016`:

```
		A10000000000000000000017 /* OpenCodeScanner.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000020 /* OpenCodeScanner.swift */; };
```

2. Add a file-ref entry after `A20000000000000000000019`:

```
		A20000000000000000000020 /* OpenCodeScanner.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OpenCodeScanner.swift; sourceTree = "<group>"; };
```

3. Add `A20000000000000000000020` to the Services group children list (after `A20000000000000000000019`).
4. Append `A10000000000000000000017` to the app Sources phase `A60000000000000000000001` `files` list.

- [ ] **Step 2: Register the test file in `project.pbxproj`**

1. Add a build-file entry after `A10000000000000000000014`:

```
		A10000000000000000000021 /* OpenCodeScannerTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000024 /* OpenCodeScannerTests.swift */; };
```

2. Add a file-ref entry after the last app file-ref:

```
		A20000000000000000000024 /* OpenCodeScannerTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OpenCodeScannerTests.swift; sourceTree = "<group>"; };
```

3. In the `TokenWatchTests` group `A30000000000000000000003`, add `A20000000000000000000024` to the children list:

```
		A30000000000000000000003 /* TokenWatchTests */ = {isa = PBXGroup; children = (A20000000000000000000013 /* UsageScannerTests.swift */, A20000000000000000000014 /* UsageSnapshotTests.swift */, A20000000000000000000024 /* OpenCodeScannerTests.swift */); path = TokenWatchTests; sourceTree = "<group>"; };
```

4. Append `A10000000000000000000021` to the test Sources phase `A60000000000000000000004` `files` list.

- [ ] **Step 3: Create the `OpenCodeScanner` stub**

Create `TokenWatch/Services/OpenCodeScanner.swift`:

```swift
import Foundation

struct OpenCodeScanner: Sendable {
    func scan(root: URL?, now: Date = Date()) -> ScanResult {
        ScanResult(events: [], sources: [])
    }
}
```

> The stub returns an empty result so the project compiles. Real implementation lands in Task 7.

- [ ] **Step 4: Write the failing tests**

Create `TokenWatchTests/OpenCodeScannerTests.swift`:

```swift
import Foundation
import XCTest
@testable import TokenWatch

final class OpenCodeScannerTests: XCTestCase {
    func testMissingDirectoryReportsMissingExpectedDirectory() throws {
        let root = try makeTemporaryDirectory()
        let result = OpenCodeScanner().scan(root: root, now: Date())

        let health = try XCTUnwrap(result.sources.first { $0.provider == .openCode })
        XCTAssertEqual(health.state, .missingExpectedDirectory)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testHappyPathEmitsOneEventPerSessionRow() throws {
        let root = try makeTemporaryDirectory()
        try createOpencodeDb(in: root, sessions: [
            (id: "ses_a", model: #"{"id":"glm-5.2","providerID":"ollama-cloud","variant":"max"}"#,
             input: 100, output: 20, cacheRead: 0, cacheWrite: 0, reasoning: 0, updatedMs: 1_783_636_290_026),
            (id: "ses_b", model: #"{"id":"claude-sonnet-4","providerID":"anthropic"}"#,
             input: 50, output: 10, cacheRead: 5, cacheWrite: 2, reasoning: 0, updatedMs: 1_783_636_300_000)
        ])

        let result = OpenCodeScanner().scan(root: root, now: Date())

        XCTAssertEqual(result.events.count, 2)
        let first = try XCTUnwrap(result.events.first { $0.model == "glm-5.2" })
        XCTAssertEqual(first.provider, .openCode)
        XCTAssertEqual(first.usage.input, 100)
        XCTAssertEqual(first.usage.output, 20)
        XCTAssertEqual(first.usage.recordedTotal, 120)
        let second = try XCTUnwrap(result.events.first { $0.model == "claude-sonnet-4" })
        XCTAssertEqual(second.usage.cacheRead, 5)
        XCTAssertEqual(second.usage.cacheWrite, 2)
        XCTAssertEqual(second.usage.recordedTotal, 67)
        let health = try XCTUnwrap(result.sources.first { $0.provider == .openCode })
        XCTAssertEqual(health.state, .ready)
        XCTAssertEqual(health.usageRecords, 2)
    }

    func testMalformedModelJsonFallsBackToUnknownAndCountsMalformed() throws {
        let root = try makeTemporaryDirectory()
        try createOpencodeDb(in: root, sessions: [
            (id: "ses_bad", model: "not-json",
             input: 10, output: 5, cacheRead: 0, cacheWrite: 0, reasoning: 0, updatedMs: 1_783_636_290_026)
        ])

        let result = OpenCodeScanner().scan(root: root, now: Date())

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.model, "Unknown model")
        let health = try XCTUnwrap(result.sources.first { $0.provider == .openCode })
        XCTAssertEqual(health.malformedLines, 1)
        XCTAssertEqual(health.usageRecords, 1)
    }

    func testMultipleDbFilesAreAggregated() throws {
        let root = try makeTemporaryDirectory()
        try createOpencodeDb(filename: "opencode.db", in: root, sessions: [
            (id: "ses_a", model: #"{"id":"glm-5.2"}"#, input: 10, output: 5, cacheRead: 0, cacheWrite: 0, reasoning: 0, updatedMs: 1_783_636_290_026)
        ])
        try createOpencodeDb(filename: "opencode-staging.db", in: root, sessions: [
            (id: "ses_b", model: #"{"id":"glm-5.2"}"#, input: 30, output: 15, cacheRead: 0, cacheWrite: 0, reasoning: 0, updatedMs: 1_783_636_300_000)
        ])

        let result = OpenCodeScanner().scan(root: root, now: Date())

        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.events.map(\.usage.input).sorted(), [10, 30])
        let health = try XCTUnwrap(result.sources.first { $0.provider == .openCode })
        XCTAssertEqual(health.scannedFiles, 2)
    }

    func testUnreadableDbFileIsReportedButOthersStillScan() throws {
        let root = try makeTemporaryDirectory()
        try Data("not a sqlite database".utf8).write(to: root.appendingPathComponent("opencode.db"))
        try createOpencodeDb(filename: "opencode-good.db", in: root, sessions: [
            (id: "ses_a", model: #"{"id":"glm-5.2"}"#, input: 10, output: 5, cacheRead: 0, cacheWrite: 0, reasoning: 0, updatedMs: 1_783_636_290_026)
        ])

        let result = OpenCodeScanner().scan(root: root, now: Date())

        XCTAssertEqual(result.events.count, 1)
        let health = try XCTUnwrap(result.sources.first { $0.provider == .openCode })
        XCTAssertEqual(health.unreadableFiles, 1)
        XCTAssertEqual(health.usageRecords, 1)
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func createOpencodeDb(
        filename: String = "opencode.db",
        in directory: URL,
        sessions: [(id: String, model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int, updatedMs: Int)]
    ) throws {
        let dbPath = directory.appendingPathComponent(filename)
        try runSqlite(dbPath, sql: """
            CREATE TABLE session (
                id TEXT PRIMARY KEY,
                model TEXT NOT NULL,
                tokens_input INTEGER NOT NULL,
                tokens_output INTEGER NOT NULL,
                tokens_cache_read INTEGER NOT NULL,
                tokens_cache_write INTEGER NOT NULL,
                tokens_reasoning INTEGER NOT NULL,
                cost REAL NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL
            );
            """)
        for s in sessions {
            let escapedModel = s.model.replacingOccurrences(of: "'", with: "''")
            try runSqlite(dbPath, sql: """
                INSERT INTO session (id, model, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write, tokens_reasoning, cost, time_created, time_updated)
                VALUES ('\(s.id)', '\(escapedModel)', \(s.input), \(s.output), \(s.cacheRead), \(s.cacheWrite), \(s.reasoning), 0.0, \(s.updatedMs), \(s.updatedMs));
                """)
        }
    }

    private func runSqlite(_ dbPath: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath.path, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("sqlite3 exited \(process.terminationStatus): \(output)")
            return
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they fail**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```
Expected: `testHappyPathEmitsOneEventPerSessionRow` and friends FAIL — the stub scanner returns empty results, so `result.events.count` is 0, not 2. (`testMissingDirectoryReportsMissingExpectedDirectory` will also fail because the stub returns an empty `sources` array, so `result.sources.first { … }` is `nil`.) This is the red phase.

> Note: this task requires `.openCode` on `UsageProvider`. If you haven't done Task 4 Step 2 yet, the build fails at compile with "cannot find 'openCode' in scope". Do Task 4 first in that case.

- [ ] **Step 6: Commit (red is fine — TDD red phase)**

```sh
git add TokenWatch/Services/OpenCodeScanner.swift TokenWatchTests/OpenCodeScannerTests.swift TokenWatch.xcodeproj/project.pbxproj
git commit -m "Add OpenCodeScanner stub and failing tests"
```

---

### Task 4: Add `.openCode` to `UsageProvider`; delete `selectedFolderName`

**Files:**
- Modify: `TokenWatch/Models/UsageModels.swift`
- Modify: `TokenWatch/Services/ProviderPaths.swift` (verification only — the switch from Task 2 becomes exhaustive)

**Interfaces:**
- Produces: `UsageProvider.openCode` with `displayName = "OpenCode"` and `expectedRelativeDirectory = "."`. `selectedFolderName` is removed.

- [ ] **Step 1: Add `.openCode` and remove `selectedFolderName`**

In `TokenWatch/Models/UsageModels.swift`, replace the whole `UsageProvider` enum (lines 3-29) with:

```swift
enum UsageProvider: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case claudeCode
    case codex
    case openCode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .openCode: "OpenCode"
        }
    }

    var expectedRelativeDirectory: String {
        switch self {
        case .claudeCode: "projects"
        case .codex: "sessions"
        case .openCode: "."
        }
    }
}
```

> `selectedFolderName` is deleted — its only callers (`FolderAccessStore`, `SettingsView`'s folder section) are deleted in later tasks. Do not leave it as dead code.

- [ ] **Step 2: Verify the project builds**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```
Expected: BUILD SUCCEEDED. `ProviderPaths.root(for:)` is now exhaustive. The stub `OpenCodeScanner` still compiles. (The existing tests reference `.claudeCode`/`.codex` only, so they still build; `UsageSnapshotTests.testEmptySnapshotProvidesBothProviders` will now have 3 providers in the empty snapshot — fix that in Task 11.)

- [ ] **Step 3: Commit**

```sh
git add TokenWatch/Models/UsageModels.swift
git commit -m "Add .openCode to UsageProvider; drop selectedFolderName"
```

---

### Task 5: Implement `OpenCodeScanner`

**Files:**
- Modify: `TokenWatch/Services/OpenCodeScanner.swift`

**Interfaces:**
- Consumes: `UsageEvent`, `TokenUsage`, `SourceHealth`, `ScanResult`, `UsageProvider.openCode`.
- Produces: the real `scan(root:now:)` implementation that the Task 3 tests exercise.

- [ ] **Step 1: Replace the stub with the implementation**

Replace the contents of `TokenWatch/Services/OpenCodeScanner.swift` with:

```swift
import Foundation

struct OpenCodeScanner: Sendable {
    func scan(root: URL?, now: Date = Date()) -> ScanResult {
        guard let root else { return ScanResult(events: [], sources: []) }
        var source = SourceHealth.unconfigured(.openCode)
        guard directoryExists(root) else {
            source.state = .missingExpectedDirectory
            source.lastRefresh = now
            return ScanResult(events: [], sources: [source])
        }

        source.state = .ready
        var events: [UsageEvent] = []
        var sessionTokens: [String: UUID] = [:]

        for url in openCodeDbFiles(in: root) {
            source.scannedFiles += 1
            do {
                try scanDb(at: url, events: &events, sessionTokens: &sessionTokens, source: &source, now: now)
            } catch {
                source.unreadableFiles += 1
            }
        }

        source.lastRefresh = now
        return ScanResult(events: events.sorted { $0.timestamp < $1.timestamp }, sources: [source])
    }

    private func scanDb(
        at url: URL,
        events: inout [UsageEvent],
        sessionTokens: inout [String: UUID],
        source: inout SourceHealth,
        now: Date
    ) throws {
        let json = try runSqliteJson(at: url)
        guard let data = json.data(using: .utf8) else {
            source.unreadableFiles += 1
            return
        }
        let rows = (try? JSONDecoder().decode([OpenCodeSessionRow].self, from: data)) ?? []
        for row in rows {
            let model = decodeModelId(row.model) ?? {
                source.malformedLines += 1
                return "Unknown model"
            }()
            let sessionToken = sessionTokens[row.id] ?? UUID()
            sessionTokens[row.id] = sessionToken
            events.append(
                UsageEvent(
                    id: UUID(),
                    provider: .openCode,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(row.timeUpdated) / 1000),
                    model: model,
                    sessionToken: sessionToken,
                    usage: TokenUsage(
                        input: row.tokensInput,
                        output: row.tokensOutput,
                        cacheRead: row.tokensCacheRead,
                        cacheWrite: row.tokensCacheWrite,
                        reasoningOutput: row.tokensReasoning
                    )
                )
            )
            source.usageRecords += 1
        }
    }

    private func decodeModelId(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(OpenCodeModel.self, from: data),
              let id = parsed.id, !id.isEmpty
        else { return nil }
        return id
    }

    private func runSqliteJson(at url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-json",
            "-readonly",
            url.path,
            """
            SELECT id, model, tokens_input, tokens_output, tokens_cache_read,
                   tokens_cache_write, tokens_reasoning, time_updated
            FROM session
            ORDER BY time_updated ASC
            """
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OpenCodeScannerError.unreadable
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func openCodeDbFiles(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard isOpenCodeDbFilename(url.lastPathComponent) else { continue }
            guard (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func isOpenCodeDbFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".db") else { return false }
        let stem = name.dropLast(3)
        if stem == "opencode" { return true }
        guard stem.hasPrefix("opencode-") else { return false }
        let channel = stem.dropFirst("opencode-".count)
        return !channel.isEmpty && channel.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
    }
}

private enum OpenCodeScannerError: Error {
    case unreadable
}

private struct OpenCodeSessionRow: Decodable {
    let id: String
    let model: String
    let tokensInput: Int
    let tokensOutput: Int
    let tokensCacheRead: Int
    let tokensCacheWrite: Int
    let tokensReasoning: Int
    let timeUpdated: Int

    enum CodingKeys: String, CodingKey {
        case id
        case model
        case tokensInput = "tokens_input"
        case tokensOutput = "tokens_output"
        case tokensCacheRead = "tokens_cache_read"
        case tokensCacheWrite = "tokens_cache_write"
        case tokensReasoning = "tokens_reasoning"
        case timeUpdated = "time_updated"
    }
}

private struct OpenCodeModel: Decodable {
    let id: String?
}
```

- [ ] **Step 2: Run the OpenCodeScanner tests to verify they pass**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' -only-testing:TokenWatchTests/OpenCodeScannerTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```
Expected: all 5 `OpenCodeScannerTests` cases PASS. (If `testMultipleDbFilesAreAggregated` or `testUnreadableDbFileIsReportedButOthersStillScan` is flaky because the enumerator picks up the `-wal`/`-shm` sidecars from the fixture db, the `isOpenCodeDbFilename` filter excludes them — only `*.db` matching the stem rule passes. The `opencode-good.db` and `opencode-staging.db` names both match.)

- [ ] **Step 3: Commit**

```sh
git add TokenWatch/Services/OpenCodeScanner.swift
git commit -m "Implement OpenCodeScanner reading session table via sqlite3 CLI"
```

---

### Task 6: Wire `openCodeRoot` through `TranscriptScanner.scan`

**Files:**
- Modify: `TokenWatch/Services/TranscriptScanner.swift`
- Modify: `TokenWatchTests/UsageScannerTests.swift`

**Interfaces:**
- Consumes: `OpenCodeScanner.scan(root:now:)` (from Task 5).
- Produces: `TranscriptScanner.scan(claudeRoot:codexRoot:openCodeRoot:now:)`.

- [ ] **Step 1: Update the `scan` signature and fold in `OpenCodeScanner`**

In `TokenWatch/Services/TranscriptScanner.swift`, replace the top of the struct (lines 4-18) so the signature gains `openCodeRoot` and the body calls `OpenCodeScanner`:

```swift
struct TranscriptScanner: Sendable {
    func scan(claudeRoot: URL?, codexRoot: URL?, openCodeRoot: URL?, now: Date = Date()) -> ScanResult {
        var events: [UsageEvent] = []
        var healthByProvider = Dictionary(
            uniqueKeysWithValues: UsageProvider.allCases.map { ($0, SourceHealth.unconfigured($0)) }
        )

        scanClaude(root: claudeRoot, events: &events, health: &healthByProvider[.claudeCode], now: now)
        scanCodex(root: codexRoot, events: &events, health: &healthByProvider[.codex], now: now)
        scanOpenCode(root: openCodeRoot, events: &events, health: &healthByProvider[.openCode], now: now)

        return ScanResult(
            events: events.sorted { $0.timestamp < $1.timestamp },
            sources: UsageProvider.allCases.compactMap { healthByProvider[$0] }
        )
    }
```

Then add a new private method just before `private func scanCodex(` (before the existing line 108):

```swift
    private func scanOpenCode(
        root: URL?,
        events: inout [UsageEvent],
        health: inout SourceHealth?,
        now: Date
    ) {
        let result = OpenCodeScanner().scan(root: root, now: now)
        events.append(contentsOf: result.events)
        if let openCodeHealth = result.sources.first {
            health = openCodeHealth
        }
    }
```

> `OpenCodeScanner` already returns a fully-formed `SourceHealth` (including the `missingExpectedDirectory` / `inaccessible` cases), so we overwrite the placeholder health from `healthByProvider[.openCode]` with the real one. The other two providers keep their existing in-place mutation pattern.

- [ ] **Step 2: Update the existing Claude/Codex tests to pass `openCodeRoot: nil`**

In `TokenWatchTests/UsageScannerTests.swift`, every existing `TranscriptScanner().scan(...)` call gains an `openCodeRoot: nil` argument:

- `testClaudeAssistantUsageIsDeduplicatedAndMalformedLinesAreReported`: `TranscriptScanner().scan(claudeRoot: root, codexRoot: nil, openCodeRoot: nil)`
- `testCodexUsesCumulativeDeltasAndAssociatesTurnModel`: `TranscriptScanner().scan(claudeRoot: nil, codexRoot: root, openCodeRoot: nil)`
- `testMissingExpectedDirectoryIsVisibleAsSourceHealth`: `TranscriptScanner().scan(claudeRoot: root, codexRoot: nil, openCodeRoot: nil)`
- `testClaudeSyntheticModelRecordsAreSkipped`: `TranscriptScanner().scan(claudeRoot: root, codexRoot: nil, openCodeRoot: nil)`

- [ ] **Step 3: Add a three-provider merge test**

Append to `TokenWatchTests/UsageScannerTests.swift` (inside the class, before the private `makeTemporaryDirectory` helper at the bottom):

```swift
    func testThreeProvidersMergeThroughTranscriptScanner() throws {
        let claudeRoot = try makeTemporaryDirectory(named: ".claude")
        let projects = claudeRoot.appendingPathComponent("projects/session", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Data(#"{"type":"assistant","timestamp":"2026-07-09T10:00:00Z","sessionId":"s1","uuid":"m1","message":{"id":"m1","model":"claude-test","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}}\n"#.utf8)
            .write(to: projects.appendingPathComponent("session.jsonl"))

        let codexRoot = try makeTemporaryDirectory(named: ".codex")
        let sessions = codexRoot.appendingPathComponent("sessions/2026/07/09", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data(#"{"type":"event_msg","timestamp":"2026-07-09T10:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5,"output_tokens":5,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":10},"last_token_usage":{"input_tokens":5,"output_tokens":5,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":10}}}}\n"#.utf8)
            .write(to: sessions.appendingPathComponent("rollout.jsonl"))

        let openCodeRoot = try makeTemporaryDirectory(named: "opencode")
        let dbPath = openCodeRoot.appendingPathComponent("opencode.db")
        try runSqliteCli(dbPath, sql: "CREATE TABLE session (id TEXT PRIMARY KEY, model TEXT NOT NULL, tokens_input INTEGER NOT NULL, tokens_output INTEGER NOT NULL, tokens_cache_read INTEGER NOT NULL, tokens_cache_write INTEGER NOT NULL, tokens_reasoning INTEGER NOT NULL, cost REAL NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL);")
        try runSqliteCli(dbPath, sql: "INSERT INTO session (id, model, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write, tokens_reasoning, cost, time_created, time_updated) VALUES ('ses_a', '{\"id\":\"glm-5.2\"}', 100, 20, 0, 0, 0, 0.0, 1783636290026, 1783636290026);")

        let result = TranscriptScanner().scan(claudeRoot: claudeRoot, codexRoot: codexRoot, openCodeRoot: openCodeRoot)

        let providerCounts = Dictionary(grouping: result.events.map(\.provider), by: { $0 }).mapValues(\.count)
        XCTAssertEqual(providerCounts[.claudeCode], 1)
        XCTAssertEqual(providerCounts[.codex], 1)
        XCTAssertEqual(providerCounts[.openCode], 1)
        XCTAssertEqual(result.sources.count, 3)
        let readyProviders = result.sources.filter { $0.state == .ready }
        XCTAssertEqual(readyProviders.count, 3)
    }

    private func runSqliteCli(_ dbPath: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "sqlite3 failed for SQL: \(sql)")
    }
```

- [ ] **Step 4: Run all scanner tests to verify they pass**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```
Expected: all `UsageScannerTests` (now 5 cases) PASS, `OpenCodeScannerTests` PASS. (`UsageSnapshotTests.testEmptySnapshotProvidesBothProviders` may still pass by coincidence — `providers.count` is now 3, not 2; fix that explicitly in Task 11.)

- [ ] **Step 5: Commit**

```sh
git add TokenWatch/Services/TranscriptScanner.swift TokenWatchTests/UsageScannerTests.swift
git commit -m "Wire OpenCodeScanner into TranscriptScanner.scan"
```

---

### Task 7: Rewrite `UsageStore` to use `ProviderPaths` + auto-discovery

**Files:**
- Modify: `TokenWatch/Stores/UsageStore.swift`

**Interfaces:**
- Consumes: `ProviderPaths.root(for:)` (Task 2), `TranscriptScanner.scan(claudeRoot:codexRoot:openCodeRoot:now:)` (Task 6). NOTE: this task does NOT yet delete `chooseFolder`/`revokeFolder` — those still reference `FolderAccessStore`, which still exists. We delete both files in Task 10. This task only rewrites the refresh path to drop `FolderAccessStore.url(for:)` and the security-scope toggling; `chooseFolder`/`revokeFolder` stay (now no-ops against `FolderAccessStore`, removed in Task 10). To avoid a transient dead-code state, this task also deletes `chooseFolder`/`revokeFolder` from `UsageStore` and deletes `FolderAccessStore.swift` + its pbxproj entries — do all of that here, not in Task 10. (Task 10 becomes SourcesView + SettingsView only.)

> **Re-scope note:** Task 7 now also does the `FolderAccessStore` deletion (originally planned for Task 10) so that `UsageStore` never has a transient state where it calls into a deleted file. Task 10 then only handles `SourcesView` + `SettingsView`.

- [ ] **Step 1: Rewrite the `UsageStore` class body**

In `TokenWatch/Stores/UsageStore.swift`, replace everything from `@MainActor final class UsageStore: ObservableObject {` (line 6) up to but not including `enum UsageAggregator {` (line 80). Leave `UsageAggregator` and everything below it unchanged. The new class body:

```swift
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var events: [UsageEvent] = []
    @Published private(set) var sources: [SourceHealth] = UsageProvider.allCases.map(SourceHealth.unconfigured)
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastMessage: String?

    private let watcher = TranscriptWatcher()

    deinit {
        watcher.stopAll()
    }

    func start() {
        watcher.onChange = { [weak self] _ in self?.refresh() }
        refresh()
        for provider in UsageProvider.allCases {
            if let url = ProviderPaths.root(for: provider) {
                watcher.start(for: provider, directory: url)
            }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastMessage = nil

        let claudeRoot = ProviderPaths.claudeRoot()
        let codexRoot = ProviderPaths.codexRoot()
        let openCodeRoot = ProviderPaths.openCodeRoot()
        let scanner = TranscriptScanner()

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                scanner.scan(
                    claudeRoot: claudeRoot,
                    codexRoot: codexRoot,
                    openCodeRoot: openCodeRoot
                )
            }.value

            guard let self else { return }
            self.events = result.events
            self.sources = result.sources
            self.isRefreshing = false
        }
    }

    func manualSync() {
        refresh()
    }

    func snapshot(for range: UsageRange, now: Date = Date()) -> UsageSnapshot {
        UsageAggregator.snapshot(events: events, range: range, sources: sources, now: now)
    }
}
```

> Removed: `refreshTimer`, the 60s `Task.sleep` loop, `chooseFolder(for:)`, `revokeFolder(for:)`, the `FolderAccessStore.url(for:)` resolution, and the `startAccessingSecurityScopedResource`/`stopAccessingSecurityScopedResource` toggling. `TranscriptWatcher` (Task 8) is referenced — if its `start(for:directory:)` / `stopAll()` / `onChange` APIs aren't yet present (Task 8 hasn't landed), this won't compile. Do Task 8 first in that case. The recommended order is Task 8 then Task 7.

- [ ] **Step 2: Delete `FolderAccessStore.swift` and unregister it from `project.pbxproj`**

Delete `TokenWatch/Services/FolderAccessStore.swift` (whole file).

In `TokenWatch.xcodeproj/project.pbxproj`:

1. Delete the line `A10000000000000000000003 /* FolderAccessStore.swift in Sources */ = ...`.
2. Delete the line `A20000000000000000000003 /* FolderAccessStore.swift */ = ...`.
3. In the Services group `A30000000000000000000007`, remove `A20000000000000000000003` from the children list. After this task the group should read:
   ```
		A30000000000000000000007 /* Services */ = {isa = PBXGroup; children = (A20000000000000000000004 /* TranscriptScanner.swift */, A20000000000000000000019 /* TranscriptWatcher.swift */, A20000000000000000000020 /* OpenCodeScanner.swift */, A20000000000000000000021 /* ProviderPaths.swift */); path = Services; sourceTree = "<group>"; };
   ```
4. In the app Sources phase `A60000000000000000000001`, remove `A10000000000000000000003` from the `files = (...)` list.

- [ ] **Step 3: Delete `SourcesView.swift` and unregister it from `project.pbxproj`**

Delete `TokenWatch/Views/SourcesView.swift` (whole file). (It is still referenced by `DashboardView` — that reference is removed in Task 9. To keep the build green, do Task 9's `DashboardView` edit before committing this task. The plan orders Task 9 before Task 7's commit for that reason — see Task 9.)

> **Ordering:** Do Task 9 (remove the `Sources` section from `DashboardView`) BEFORE this step's commit, otherwise the app target won't compile. This plan lists the tasks in dependency order: Task 9 then Task 7.

- [ ] **Step 4: Verify the project builds**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```
Expected: BUILD SUCCEEDED. (Requires Task 8 `TranscriptWatcher` to be implemented and Task 9 `DashboardView` to no longer reference `SourcesView`.)

- [ ] **Step 5: Commit**

```sh
git add TokenWatch/Stores/UsageStore.swift TokenWatch/Services/FolderAccessStore.swift TokenWatch/Views/SourcesView.swift TokenWatch.xcodeproj/project.pbxproj
git commit -m "Replace FolderAccessStore with ProviderPaths auto-discovery; drop 60s poll"
```

> Note: `git add` on a deleted file records the deletion. If `git status` shows the deletions as unstaged, use `git add -A TokenWatch/Services/FolderAccessStore.swift TokenWatch/Views/SourcesView.swift` to stage them.

---

### Task 8: Implement `TranscriptWatcher` with FSEventStream

**Files:**
- Modify: `TokenWatch/Services/TranscriptWatcher.swift`
- Create: `TokenWatchTests/TranscriptWatcherTests.swift`
- Modify: `TokenWatch.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `UsageProvider` (all three cases).
- Produces:
  - `@MainActor final class TranscriptWatcher`
  - `var onChange: ((UsageProvider) -> Void)?`
  - `func start(for provider: UsageProvider, directory: URL)` — creates + starts an `FSEventStream` for `directory` at `latency = 0.5`, flags `[.fileEvents, .watchRoot]`, scheduled on `kCFRunLoopMain`. Replaces any existing stream for `provider`.
  - `func stop(for provider: UsageProvider)` — stops + invalidates + releases the stream for `provider`.
  - `func stopAll()` — stops every active stream.
  - `func isWatching(for provider: UsageProvider) -> Bool`

- [ ] **Step 1: Register the test file in `project.pbxproj`**

1. Add a build-file entry after `A10000000000000000000021`:
   ```
		A10000000000000000000020 /* TranscriptWatcherTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000023 /* TranscriptWatcherTests.swift */; };
   ```
2. Add a file-ref entry after `A20000000000000000000021`:
   ```
		A20000000000000000000023 /* TranscriptWatcherTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TranscriptWatcherTests.swift; sourceTree = "<group>"; };
   ```
3. Add `A20000000000000000000023` to the `TokenWatchTests` group `A30000000000000000000003` children list (after `A20000000000000000000024` — order in the list doesn't matter for build correctness).
4. Append `A10000000000000000000020` to the test Sources phase `A60000000000000000000004`.

- [ ] **Step 2: Write the failing tests**

Create `TokenWatchTests/TranscriptWatcherTests.swift`:

```swift
import Foundation
import XCTest
@testable import TokenWatch

@MainActor
final class TranscriptWatcherTests: XCTestCase {
    func testStartAndStopLifecycleDoesNotLeakStreams() throws {
        let dir = try makeTemporaryDirectory()
        let watcher = TranscriptWatcher()
        var fired: Int = 0
        watcher.onChange = { _ in fired &+= 1 }

        XCTAssertFalse(watcher.isWatching(for: .claudeCode))
        watcher.start(for: .claudeCode, directory: dir)
        XCTAssertTrue(watcher.isWatching(for: .claudeCode))

        watcher.stop(for: .claudeCode)
        XCTAssertFalse(watcher.isWatching(for: .claudeCode))

        watcher.stopAll()
        XCTAssertEqual(fired, 0, "No file changes -> no callbacks during lifecycle test")
    }

    func testStartReplacesExistingStreamForSameProvider() throws {
        let dir = try makeTemporaryDirectory()
        let watcher = TranscriptWatcher()

        watcher.start(for: .claudeCode, directory: dir)
        watcher.start(for: .claudeCode, directory: dir)

        XCTAssertTrue(watcher.isWatching(for: .claudeCode))
        watcher.stopAll()
    }

    func testStopAllClearsEveryProvider() throws {
        let dir = try makeTemporaryDirectory()
        let watcher = TranscriptWatcher()
        watcher.start(for: .claudeCode, directory: dir)
        watcher.start(for: .codex, directory: dir)
        watcher.start(for: .openCode, directory: dir)

        watcher.stopAll()
        XCTAssertFalse(watcher.isWatching(for: .claudeCode))
        XCTAssertFalse(watcher.isWatching(for: .codex))
        XCTAssertFalse(watcher.isWatching(for: .openCode))
    }

    func testOnChangeFiresCorrectProviderWhenFileChanges() throws {
        let dir = try makeTemporaryDirectory()
        let projects = dir.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        let watcher = TranscriptWatcher()
        var firedProviders: [UsageProvider] = []
        watcher.onChange = { firedProviders.append($0) }

        watcher.start(for: .claudeCode, directory: dir)

        let file = projects.appendingPathComponent("session.jsonl")
        try Data("{\"type\":\"assistant\"}\n".utf8).write(to: file)

        let expectation = expectation(description: "watcher fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { expectation.fulfill() }
        wait(for: [expectation], timeout: 5.0)

        watcher.stopAll()
        XCTAssertTrue(firedProviders.contains(.claudeCode), "Expected .claudeCode to fire; got \(firedProviders)")
        XCTAssertFalse(firedProviders.contains(.codex), ".codex should never fire for a .claudeCode stream")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenWatchWatcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```
Expected: `testStartAndStopLifecycleDoesNotLeakStreams` and friends FAIL — `start(for:directory:)`, `stop(for:)`, `isWatching(for:)`, `stopAll()` don't exist on the stub.

- [ ] **Step 4: Implement `TranscriptWatcher`**

Replace the contents of `TokenWatch/Services/TranscriptWatcher.swift` with:

```swift
import CoreServices
import Foundation

@MainActor
final class TranscriptWatcher {
    var onChange: ((UsageProvider) -> Void)?

    private struct Watch {
        let stream: FSEventStreamRef
        let directory: URL
        let provider: UsageProvider
    }

    private var watches: [UsageProvider: Watch] = [:]

    deinit {
        for watch in watches.values {
            FSEventStreamStop(watch.stream)
            FSEventStreamInvalidate(watch.stream)
            FSEventStreamRelease(watch.stream)
        }
    }

    func start(for provider: UsageProvider, directory: URL) {
        stop(for: provider)

        let infoBox = WatchInfoBox(provider: provider, watcher: self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(infoBox).toOpaque(),
            retain: nil,
            release: { info in
                if let info { Unmanaged<WatchInfoBox>.fromOpaque(info).release() }
            },
            copyDescription: nil
        )
        let flags: FSEventStreamCreateFlags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let box = Unmanaged<WatchInfoBox>.fromOpaque(info).takeUnretainedValue()
                DispatchQueue.main.async { box.watcher.dispatchChange(box.provider) }
            },
            &context,
            [directory] as CFArray,
            .distantPast,
            0.5,
            flags
        ) else {
            Unmanaged<WatchInfoBox>.fromOpaque(context.info!).release()
            return
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        watches[provider] = Watch(stream: stream, directory: directory, provider: provider)
    }

    func stop(for provider: UsageProvider) {
        guard let watch = watches.removeValue(forKey: provider) else { return }
        FSEventStreamStop(watch.stream)
        FSEventStreamInvalidate(watch.stream)
        FSEventStreamRelease(watch.stream)
    }

    func stopAll() {
        for provider in watches.keys {
            stop(for: provider)
        }
    }

    func isWatching(for provider: UsageProvider) -> Bool {
        watches[provider] != nil
    }

    @MainActor
    fileprivate func dispatchChange(_ provider: UsageProvider) {
        onChange?(provider)
    }

    private final class WatchInfoBox {
        let provider: UsageProvider
        let watcher: TranscriptWatcher
        init(provider: UsageProvider, watcher: TranscriptWatcher) {
            self.provider = provider
            self.watcher = watcher
        }
    }
}
```

> Differences from the superseded 2026-07-09 plan: no `securityScope` field (sandbox is gone; `startAccessingSecurityScopedResource` is no longer called). `WatchInfoBox` is `private` (file-scoped), and `dispatchChange` is `fileprivate` so the callback closure (which captures the box) can call it without exposing it. The `deinit` does not stop accessing a security scope (there isn't one).

- [ ] **Step 5: Run all watcher tests to verify they pass**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' -only-testing:TokenWatchTests/TranscriptWatcherTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```
Expected: all 4 `TranscriptWatcherTests` cases PASS. If `testOnChangeFiresCorrectProviderWhenFileChanges` is flaky, bump the `asyncAfter` deadline to `3.0` and timeout to `8.0`. Do not remove the test.

- [ ] **Step 6: Commit**

```sh
git add TokenWatch/Services/TranscriptWatcher.swift TokenWatchTests/TranscriptWatcherTests.swift TokenWatch.xcodeproj/project.pbxproj
git commit -m "Implement TranscriptWatcher with FSEventStream"
```

---

### Task 9: Remove the `Sources` section from `DashboardView`; reword empty state; provider `switch`

**Files:**
- Modify: `TokenWatch/Views/DashboardView.swift`

> Do this BEFORE Task 7's commit (Task 7 deletes `SourcesView`, which `DashboardView` still references).

- [ ] **Step 1: Remove `DashboardSection.sources`**

In `TokenWatch/Views/DashboardView.swift`, replace the enum (lines 4-20) with:

```swift
private enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case models

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .models: "cpu"
        }
    }
}
```

- [ ] **Step 2: Remove the `.sources` switch arm**

In the `body`'s `detail:` switch (lines 40-47), replace with:

```swift
        } detail: {
            switch section ?? .overview {
            case .overview:
                OverviewView(snapshot: store.snapshot(for: selectedRange))
            case .models:
                ModelsView(snapshot: store.snapshot(for: selectedRange))
            }
        }
```

- [ ] **Step 3: Reword the `ContentUnavailableView` description**

In the `OverviewView`, find the `ContentUnavailableView(...)` (around line 131-135) and change the `description:` text from `"Choose your Claude Code or Codex folder in Sources to begin."` to `"Open Claude Code, Codex, or OpenCode to begin recording token metadata."`. The updated view:

```swift
                        ContentUnavailableView(
                            "No recorded token activity",
                            systemImage: "chart.bar.xaxis",
                            description: Text("Open Claude Code, Codex, or OpenCode to begin recording token metadata.")
                        )
```

- [ ] **Step 4: Switch the provider-split `GroupBox` from ternary to `switch` with `"curlybraces"`**

In `OverviewView`, the provider-split `GroupBox` (around line 158) currently has:

```swift
                                Label(provider.provider.displayName, systemImage: provider.provider == .claudeCode ? "sparkles" : "terminal")
```

Replace with a `switch` using a helper. Add this private helper at the bottom of `DashboardView.swift` (after the `OverviewView` struct closes, before the final `Label` at the end of the file):

```swift
private func providerSymbol(_ provider: UsageProvider) -> String {
    switch provider {
    case .claudeCode: "sparkles"
    case .codex: "terminal"
    case .openCode: "curlybraces"
    }
}
```

And in the `GroupBox`, change the `Label` line to:

```swift
                                Label(provider.provider.displayName, systemImage: providerSymbol(provider.provider))
```

> The helper is a free function (not a method on the struct) so both `OverviewView` and other views can reuse it if needed; keep it `private` (file-scoped).

- [ ] **Step 5: Verify the project builds (without `SourcesView` yet)**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```
Expected: BUILD SUCCEEDED. `SourcesView` still exists at this point (Task 7 deletes it), but `DashboardView` no longer references it — that's what matters. The build is green because the `DashboardSection.sources` case and its switch arm are gone.

- [ ] **Step 6: Commit**

```sh
git add TokenWatch/Views/DashboardView.swift
git commit -m "Remove Sources section; reword empty state; provider-symbol switch"
```

---

### Task 10: Rewrite `SettingsView` (remove folder picker, add Sync Now, move privacy labels)

**Files:**
- Modify: `TokenWatch/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `store.manualSync()` (added in Task 7), `store.isRefreshing` (existing).

- [ ] **Step 1: Replace the whole `SettingsView` body**

Replace the contents of `TokenWatch/Views/SettingsView.swift` with:

```swift
import SwiftUI

struct TokenWatchSettingsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Form {
            Section("Refresh") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic refresh")
                        Text("Token Watch auto-discovers ~/.claude, ~/.codex, and ~/.local/share/opencode on launch and updates automatically when local transcript files change. Use Sync Now if anything looks out of date.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sync Now") { store.manualSync() }
                        .disabled(store.isRefreshing)
                }
            }

            Section("Privacy boundary") {
                Label("No network entitlement or network features", systemImage: "network.slash")
                Label("No prompts, responses, source files, paths, or session IDs are shown or persisted", systemImage: "lock")
                Label("No cost, quota, account, credential, or rate-limit tracking", systemImage: "nosign")
            }

            Section("Privacy and status") {
                Text("This app has no network entitlement and makes no provider requests. It keeps only interface preferences; observed token metadata is rebuilt in memory from local files.")
                Text("Token Watch is not affiliated with or endorsed by Anthropic, OpenAI, or OpenCode. Recorded tokens are not an official provider quota, invoice, or account balance.")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 620)
    }
}
```

> Removed: the "Local data access" section with per-provider folder pickers (the only caller of the now-deleted `store.chooseFolder(for:)` and `provider.selectedFolderName`). Added: the three privacy-boundary `Label`s moved from the now-deleted `SourcesView`. Updated: the affiliation disclaimer mentions OpenAI; the "Refresh" section describes auto-discovery + the Sync Now button. Dropped the "folder bookmarks" wording (no bookmarks anymore).

- [ ] **Step 2: Verify the project builds**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```sh
git add TokenWatch/Views/SettingsView.swift
git commit -m "Rewrite SettingsView for auto-discovery + Sync Now + privacy labels"
```

---

### Task 11: Update `ModelsView` and `MenuBarPopover` provider-symbol switches; fix snapshot test count

**Files:**
- Modify: `TokenWatch/Views/ModelsView.swift`
- Modify: `TokenWatch/Views/MenuBarPopover.swift`
- Modify: `TokenWatchTests/UsageSnapshotTests.swift`

- [ ] **Step 1: `ModelsView` — ternary to switch**

In `TokenWatch/Views/ModelsView.swift`, the ternary at line 22 is:

```swift
                        Image(systemName: model.provider == .claudeCode ? "sparkles" : "terminal")
```

Replace with:

```swift
                        Image(systemName: model.provider == .claudeCode ? "sparkles" : (model.provider == .codex ? "terminal" : "curlybraces"))
```

> Keeping it as a nested ternary matches the one-line style of the existing code; a `switch` would require extracting a helper. Either is fine — the nested ternary is the smaller diff and stays consistent with the file's existing style.

- [ ] **Step 2: `MenuBarPopover` — ternary to switch**

In `TokenWatch/Views/MenuBarPopover.swift`, the ternary at line 96 is:

```swift
                            Image(systemName: model.provider == .claudeCode ? "sparkles" : "terminal")
```

Replace with:

```swift
                            Image(systemName: model.provider == .claudeCode ? "sparkles" : (model.provider == .codex ? "terminal" : "curlybraces"))
```

- [ ] **Step 3: Fix `UsageSnapshotTests` count**

In `TokenWatchTests/UsageSnapshotTests.swift`, the test at line 38 is:

```swift
    func testEmptySnapshotProvidesBothProviders() {
```

Rename it to `testEmptySnapshotProvidesAllProviders` and change the assertion at line 46 from `XCTAssertEqual(snapshot.providers.count, 2)` to `XCTAssertEqual(snapshot.providers.count, 3)`. The full updated test:

```swift
    func testEmptySnapshotProvidesAllProviders() {
        let snapshot = UsageAggregator.snapshot(
            events: [],
            range: .month,
            sources: UsageProvider.allCases.map(SourceHealth.unconfigured),
            now: Date()
        )

        XCTAssertEqual(snapshot.providers.count, 3)
        XCTAssertEqual(snapshot.usage.recordedTotal, 0)
        XCTAssertTrue(snapshot.models.isEmpty)
    }
```

- [ ] **Step 4: Run all tests to verify they pass**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```
Expected: all tests PASS (scanner, snapshot with count 3, watcher, opencode scanner).

- [ ] **Step 5: Commit**

```sh
git add TokenWatch/Views/ModelsView.swift TokenWatch/Views/MenuBarPopover.swift TokenWatchTests/UsageSnapshotTests.swift
git commit -m "Add OpenCode symbol to ModelsView and MenuBarPopover; fix snapshot provider count"
```

---

### Task 11.5: Add `UsageStoreSyncTests` (manualSync test)

**Files:**
- Create: `TokenWatchTests/UsageStoreSyncTests.swift`
- Modify: `TokenWatch.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `UsageStore.manualSync()` (from Task 7).

- [ ] **Step 1: Register the test file in `project.pbxproj`**

1. Add a build-file entry after `A10000000000000000000020`:
   ```
		A10000000000000000000019 /* UsageStoreSyncTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000022 /* UsageStoreSyncTests.swift */; };
   ```
2. Add a file-ref entry after `A20000000000000000000021`:
   ```
		A20000000000000000000022 /* UsageStoreSyncTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UsageStoreSyncTests.swift; sourceTree = "<group>"; };
   ```
3. Add `A20000000000000000000022` to the `TokenWatchTests` group `A30000000000000000000003` children list.
4. Append `A10000000000000000000019` to the test Sources phase `A60000000000000000000004` `files` list.

- [ ] **Step 2: Write the test**

Create `TokenWatchTests/UsageStoreSyncTests.swift`:

```swift
import Foundation
import XCTest
@testable import TokenWatch

@MainActor
final class UsageStoreSyncTests: XCTestCase {
    func testManualSyncTriggersRefresh() async {
        let store = UsageStore()
        store.manualSync()
        // The refresh runs in a detached Task; give it a moment to complete.
        try? await Task.sleep(for: .milliseconds(200))
        let health = store.sources.first { $0.provider == .openCode }
        XCTAssertNotNil(health?.lastRefresh, "manualSync should drive a refresh; lastRefresh should be set")
    }
}
```

> The test awaits briefly because `UsageStore.refresh()` dispatches its scan to a detached `Task` and publishes the result asynchronously. Asserting `isRefreshing` immediately is racy; asserting `lastRefresh` after a short wait is stable.

- [ ] **Step 3: Run the test to verify it passes**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' -only-testing:TokenWatchTests/UsageStoreSyncTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```
Expected: `testManualSyncTriggersRefresh` PASSES. (`lastRefresh` is set when `scan()` writes `SourceHealth` back, which happens on the detached task within the 200ms window.)

- [ ] **Step 4: Commit**

```sh
git add TokenWatchTests/UsageStoreSyncTests.swift TokenWatch.xcodeproj/project.pbxproj
git commit -m "Add UsageStoreSyncTests for manualSync"
```

---

### Task 12: Drop the App Sandbox from entitlements; delete superseded docs

**Files:**
- Modify: `TokenWatch/TokenWatch.entitlements`
- Delete: `docs/superpowers/specs/2026-07-09-file-system-driven-refresh-design.md`
- Delete: `docs/superpowers/plans/2026-07-09-file-system-driven-refresh.md`

- [ ] **Step 1: Empty the entitlements file**

Replace the contents of `TokenWatch/TokenWatch.entitlements` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
```

> The `CODE_SIGN_ENTITLEMENTS` build setting in `project.pbxproj` keeps pointing at this now-empty file. An empty entitlements dict is a no-op; leaving the setting avoids pbxproj churn.

- [ ] **Step 2: Delete the superseded spec and plan**

```sh
git rm docs/superpowers/specs/2026-07-09-file-system-driven-refresh-design.md
git rm docs/superpowers/plans/2026-07-09-file-system-driven-refresh.md
```

- [ ] **Step 3: Verify the build (the empty entitlements file should not break signing in a CODE_SIGNING_ALLOWED=NO build)**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```sh
git add TokenWatch/TokenWatch.entitlements
git commit -m "Drop App Sandbox entitlements; remove superseded file-watch spec and plan"
```

---

### Task 13: Update `README.md` for auto-discovery + OpenCode

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite the "Local-only boundary" section**

Replace lines 1-12 of `README.md` (the title + "Local-only boundary" section, up to but not including "Recorded token totals…") with:

```markdown
# Token Watch

Token Watch is an original macOS 26+ SwiftUI menu-bar utility for observing token metadata already present in local Claude Code, Codex, and OpenCode data.

## Local-only boundary

- The app auto-discovers `~/.claude/projects/**/*.jsonl`, `~/.codex/sessions/**/*.jsonl`, and `~/.local/share/opencode/opencode.db` on launch. Access is read-only; no folder picker is shown.
- For Claude Code and Codex it decodes only whitelisted timestamp, model, and token-usage fields from the JSONL transcripts. For OpenCode it reads only the `session` table's token-total columns and `model` id from `opencode.db` via the system `sqlite3` CLI. Record-type and deduplication identifiers are read in memory only, never displayed or persisted.
- Prompts, model responses, source code, paths, session IDs, credentials, account data, costs, rate limits, and provider quotas are not shown or persisted.
- The project declares no network entitlement and ships a privacy audit that rejects common networking APIs.
```

And update the affiliation disclaimer (currently line 12) to read:

```markdown
Recorded token totals are local transcript metadata, not an official provider quota, invoice, or account balance. Token Watch is not affiliated with or endorsed by Anthropic, OpenAI, or OpenCode. Keep it private until you have confirmed that this local-metadata use fits your provider and organizational policies.
```

And update the opening line of the "Build and test" section (currently "The app target includes the App Sandbox and user-selected read-only file-access entitlements…") to read:

```markdown
The app target ships with no App Sandbox and no network entitlement. A locally unsigned debug build is sufficient for parser and UI development; select an appropriate signing team before distributing an app bundle.
```

> If the README has no such line, skip that edit — only edit what's there. Re-read the file before editing to confirm line numbers (they may have shifted from the version this plan was written against).

- [ ] **Step 2: Commit**

```sh
git add README.md
git commit -m "Update README for auto-discovery and OpenCode provider"
```

---

### Task 14: Final verification — privacy audit, verify build, full test run

**Files:** No file changes. Verification only.

- [ ] **Step 1: Run the privacy audit**

Run:
```sh
./script/audit_privacy.sh
```
Expected: exits 0 with "Privacy audit passed: no network entitlements or networking APIs found." The audit checks the entitlements file (now empty — no `network.client`/`network.server`) and greps for `URLSession|URLRequest|NWConnection|NWPathMonitor|WebSocket|HTTPClient` in `*.swift` — none of these are used (we use `Process`, which is not in the audit's list).

- [ ] **Step 2: Run the verify build**

Run:
```sh
./script/build_and_run.sh --verify
```
Expected: app launches, stays alive ~1s, then is killed; script exits 0.

- [ ] **Step 3: Run the full test suite**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -40
```
Expected: all tests PASS — `UsageScannerTests` (5 cases incl. the 3-provider merge), `UsageSnapshotTests` (3 cases, count 3), `OpenCodeScannerTests` (5 cases), `TranscriptWatcherTests` (4 cases), `UsageStoreSyncTests` (1 case).

- [ ] **Step 4: Dead-code confirmation grep**

Run:
```sh
rg 'FolderAccessStore|chooseFolder|revokeFolder|selectedFolderName|refreshTimer|Task\.sleep' TokenWatch/
```
Expected: no matches. (All of those symbols are gone from the app target.)

- [ ] **Step 5: Deleted-files confirmation**

Run:
```sh
test ! -f TokenWatch/Services/FolderAccessStore.swift && echo "FolderAccessStore.swift gone"
test ! -f TokenWatch/Views/SourcesView.swift && echo "SourcesView.swift gone"
test ! -f docs/superpowers/specs/2026-07-09-file-system-driven-refresh-design.md && echo "superseded spec gone"
test ! -f docs/superpowers/plans/2026-07-09-file-system-driven-refresh.md && echo "superseded plan gone"
```
Expected: all four "gone" lines printed.

- [ ] **Step 6: Final commit if any verification touched tracked files**

```sh
git status --porcelain
```
If empty, nothing to commit. If non-empty, inspect and commit with a descriptive message (no secrets).

---

## Acceptance check

- [ ] `UsageProvider.allCases` contains `.claudeCode`, `.codex`, `.openCode`.
- [ ] Launching the app with all three sources present shows non-zero totals from each within ~1s.
- [ ] A change to `~/.claude/projects/*.jsonl`, `~/.codex/sessions/*.jsonl`, or `~/.local/share/opencode/opencode.db` updates stats within ~1s on a running app (manual smoke test: launch app, append to a transcript or run an OpenCode session, observe the menu-bar count change).
- [ ] `./script/audit_privacy.sh` passes.
- [ ] `./script/build_and_run.sh --verify` passes.
- [ ] `xcodebuild … test` passes.
- [ ] `rg 'FolderAccessStore|chooseFolder|revokeFolder|selectedFolderName|refreshTimer|Task\.sleep' TokenWatch/` returns nothing.
- [ ] `SourcesView.swift` and `FolderAccessStore.swift` no longer exist; the superseded spec and plan are deleted.

---

## Self-review notes

- **Spec coverage:** Every section of `2026-07-09-opencode-auto-discovery-design.md` maps to a task: posture drop (Task 12), OpenCode scanner (Tasks 3+5), file-watching (Tasks 1+8), `ProviderPaths` (Task 2), `TranscriptScanner.scan` signature (Task 6), `UsageStore` rewrite (Task 7), `UsageProvider.openCode` + `selectedFolderName` deletion (Task 4), view updates (Tasks 9+10+11), entitlements (Task 12), README (Task 13), dead-code removal (Tasks 7+12), verification (Task 14).
- **Placeholder scan:** No TBD/TODO. All code blocks are complete.
- **Type consistency:** `ProviderPaths.root(for:)` signature matches across Tasks 2 and 7. `TranscriptScanner.scan(claudeRoot:codexRoot:openCodeRoot:now:)` matches across Tasks 6 and 7. `TranscriptWatcher.start(for:directory:)`, `stop(for:)`, `stopAll()`, `isWatching(for:)`, `onChange` match across Tasks 7 and 8. `OpenCodeScanner.scan(root:now:)` matches across Tasks 3, 5, 6. `UsageStore.manualSync()` matches across Tasks 7 and 11.5.
- **Ordering hazard:** Task 7's commit depends on Task 8 (TranscriptWatcher implemented) and Task 9 (DashboardView no longer references SourcesView). The plan flags this in Task 7 Step 1 and Step 3. Recommended execution order: 1, 2, 4, 3, 5, 6, 8, 9, 7, 10, 11, 11.5, 12, 13, 14. The tasks are numbered for dependency reference, not strict execution order — an executor should follow the recommended order above.