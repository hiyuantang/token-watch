# File-system-driven refresh — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `UsageStore`'s fixed 60-second poll with FSEventStream-based file watching so stats update ~0.5s after a transcript file changes, plus a manual "Sync Now" button in Settings.

**Architecture:** A new `TranscriptWatcher` (CoreServices `FSEventStream`) holds one stream per configured provider directory at `latency = 0.5s` (the OS coalesces bursts into one callback — that *is* the debounce). It forwards change events to `UsageStore.refresh()`, which is otherwise unchanged. The 60s `Task.sleep` loop is deleted. No scanner, aggregator, model, or view (other than Settings) changes.

**Tech Stack:** Swift 6 (strict concurrency), CoreServices `FSEventStream`, AppKit/SwiftUI, XCTest.

## Global constraints

- macOS 26+ deployment target; Swift 6.0; `SWIFT_STRICT_CONCURRENCY = complete`.
- App Sandbox + user-selected read-only file-access entitlements. No network entitlement. The privacy audit (`script/audit_privacy.sh`) must keep passing — no new APIs it rejects.
- `FSEventStream` is a CoreServices C API. Wrap it in a Swift class owned by `UsageStore` (a `@MainActor` `ObservableObject`). The stream is scheduled on the main run loop so callbacks arrive on the main actor; no cross-actor hops for state mutation.
- The `project.pbxproj` uses hand-maintained synthetic IDs of the form `A1000000000000000000000N` (build files), `A2000000000000000000000N` (file refs), `A3000000000000000000000N` (groups). The next free index for app sources is **16** (A20000000000000000000016 is the app product; the next *source-file* ref after the existing ones is A20000000000000000000019). Use **A10000000000000000000016** for the new build-file entry, **A20000000000000000000019** for the new file reference, and add it to the Services group `A30000000000000000000007` and the Sources phase `A60000000000000000000001`.
- No comments in code unless asked (repo convention).

---

## File structure

- **Create:** `TokenWatch/Services/TranscriptWatcher.swift` — wraps `FSEventStream` per provider; main-actor-owned; `onChange` callback.
- **Create:** `TokenWatchTests/TranscriptWatcherTests.swift` — lifecycle + main-actor callback tests.
- **Modify:** `TokenWatch/Stores/UsageStore.swift` — delete 60s timer; own a `TranscriptWatcher`; wire `start`/`chooseFolder`/`revokeFolder`; add `manualSync()`.
- **Modify:** `TokenWatch/Views/SettingsView.swift` — replace the "every 60 seconds" text; add a "Sync Now" button bound to `store.manualSync()`.
- **Modify:** `TokenWatch.xcodeproj/project.pbxproj` — register `TranscriptWatcher.swift` and `TranscriptWatcherTests.swift` in the build (app sources + test sources).

---

### Task 1: Add `TranscriptWatcher` to the Xcode project

**Files:**
- Modify: `TokenWatch.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: a compiled `TranscriptWatcher.swift` in the `TokenWatch` app module (referenced as `import`-able once Task 2 lands the file).

- [ ] **Step 1: Create the empty source file so the project compiles after the pbxproj edit**

Create `TokenWatch/Services/TranscriptWatcher.swift` with a stub:

```swift
import Foundation

@MainActor
final class TranscriptWatcher {
}
```

- [ ] **Step 2: Register the file in `project.pbxproj`**

In `TokenWatch.xcodeproj/project.pbxproj`:

1. After line 19 (the `A10000000000000000000015 /* Assets.xcassets in Resources */ ...` build-file entry), add a new build-file entry:

```
		A10000000000000000000016 /* TranscriptWatcher.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000019 /* TranscriptWatcher.swift */; };
```

2. After line 41 (the `A20000000000000000000018 /* Assets.xcassets */ ...` file-ref entry), add a new file-ref entry:

```
		A20000000000000000000019 /* TranscriptWatcher.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TranscriptWatcher.swift; sourceTree = "<group>"; };
```

3. In the Services group (line 49), insert the new ref into the children list so it reads:

```
		A30000000000000000000007 /* Services */ = {isa = PBXGroup; children = (A20000000000000000000003 /* FolderAccessStore.swift */, A20000000000000000000004 /* TranscriptScanner.swift */, A20000000000000000000019 /* TranscriptWatcher.swift */); path = Services; sourceTree = "<group>"; };
```

4. In the app Sources phase (line 61), append the new build-file ID `A10000000000000000000016` to the `files = (...)` list so the end of the list becomes `..., A10000000000000000000012, A10000000000000000000016);`.

- [ ] **Step 3: Verify the project still builds**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO
```
Expected: BUILD SUCCEEDED (the stub class compiles and is unused).

- [ ] **Step 4: Commit**

```sh
git add TokenWatch/Services/TranscriptWatcher.swift TokenWatch.xcodeproj/project.pbxproj
git commit -m "Add TranscriptWatcher.swift to project"
```

---

### Task 2: Implement `TranscriptWatcher` with FSEventStream

**Files:**
- Modify: `TokenWatch/Services/TranscriptWatcher.swift`

**Interfaces:**
- Consumes: `UsageProvider` (from `TokenWatch/Models/UsageModels.swift`).
- Produces:
  - `@MainActor final class TranscriptWatcher`
  - `var onChange: (@MainActor (UsageProvider) -> Void)?`
  - `func start(for provider: UsageProvider, directory: URL)`

    - Creates an `FSEventStream` for `directory` with flags `[.fileEvents, .watchRoot]`, `latency = 0.5`, schedules it on the main run loop (`kCFRunLoopMain`), and starts it. If a stream already exists for `provider`, stops and replaces it. Stores the stream + its security-scoped URL.

  - `func stop(for provider: UsageProvider)`

    - Stops and invalidates the stream for `provider`, stops accessing the security-scoped resource, and removes it from the map.

  - `func stopAll()`

    - Calls `stop(for:)` for every provider. Safe to call when no streams exist.

  - `func isWatching(for provider: UsageProvider) -> Bool`

    - Used by tests.

- [ ] **Step 1: Write the failing test**

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

        watcher.stopAll()
        XCTAssertFalse(watcher.isWatching(for: .claudeCode))
        XCTAssertFalse(watcher.isWatching(for: .codex))
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

- [ ] **Step 2: Register the test file in `project.pbxproj`**

In `TokenWatch.xcodeproj/project.pbxproj`:

1. After the `A10000000000000000000016` build-file entry added in Task 1, add:

```
		A10000000000000000000017 /* TranscriptWatcherTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000020 /* TranscriptWatcherTests.swift */; };
```

2. After the `A20000000000000000000019` file-ref entry, add:

```
		A20000000000000000000020 /* TranscriptWatcherTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TranscriptWatcherTests.swift; sourceTree = "<group>"; };
```

3. In the `TokenWatchTests` group (line 45), add the new ref to the children list:

```
		A30000000000000000000003 /* TokenWatchTests */ = {isa = PBXGroup; children = (A20000000000000000000013 /* UsageScannerTests.swift */, A20000000000000000000014 /* UsageSnapshotTests.swift */, A20000000000000000000020 /* TranscriptWatcherTests.swift */); path = TokenWatchTests; sourceTree = "<group>"; };
```

4. In the test Sources phase (line 64), append `A10000000000000000000017` so it reads:

```
		A60000000000000000000004 /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A10000000000000000000013, A10000000000000000000014, A10000000000000000000017); runOnlyForDeploymentPostprocessing = 0; };
```

- [ ] **Step 3: Run the tests to verify they fail**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```
Expected: the three `TranscriptWatcherTests` cases FAIL — `start(for:directory:)`, `stop(for:)`, `isWatching(for:)`, `stopAll()` do not exist.

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
        let securityScope: URL
    }

    private var watches: [UsageProvider: Watch] = [:]

    deinit {
        for watch in watches.values {
            FSEventStreamStop(watch.stream)
            FSEventStreamInvalidate(watch.stream)
            FSEventStreamRelease(watch.stream)
            watch.securityScope.stopAccessingSecurityScopedResource()
        }
    }

    func start(for provider: UsageProvider, directory: URL) {
        stop(for: provider)

        guard directory.startAccessingSecurityScopedResource() else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags: FSEventStreamCreateFlags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, flags in
                guard let info else { return }
                let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
                let provider = Self.providerFromFlags(flags)
                DispatchQueue.main.async { watcher.dispatchChange(provider) }
            },
            &context,
            [directory] as CFArray,
            .distantPast,
            0.5,
            flags
        ) else {
            directory.stopAccessingSecurityScopedResource()
            return
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        watches[provider] = Watch(stream: stream, securityScope: directory)
    }

    func stop(for provider: UsageProvider) {
        guard let watch = watches.removeValue(forKey: provider) else { return }
        FSEventStreamStop(watch.stream)
        FSEventStreamInvalidate(watch.stream)
        FSEventStreamRelease(watch.stream)
        watch.securityScope.stopAccessingSecurityScopedResource()
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
    private func dispatchChange(_ provider: UsageProvider) {
        onChange?(provider)
    }

    private static func providerFromFlags(_ flags: FSEventStreamEventFlags) -> UsageProvider {
        return .claudeCode
    }
}
```

> Note on the `providerFromFlags` stub: FSEventStream callbacks do not carry the provider; the real mapping uses a per-stream info context. Task 3 fixes this by replacing the single shared context with a per-stream retained info pointer that encodes the provider. For Task 2, keep the stub so the lifecycle tests compile and pass — `providerFromFlags` is never exercised by those tests because no file changes are made.

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```
Expected: all three `TranscriptWatcherTests` cases PASS; existing `UsageScannerTests` and `UsageSnapshotTests` still PASS.

- [ ] **Step 6: Commit**

```sh
git add TokenWatch/Services/TranscriptWatcher.swift TokenWatchTests/TranscriptWatcherTests.swift TokenWatch.xcodeproj/project.pbxproj
git commit -m "Implement TranscriptWatcher with FSEventStream"
```

---

### Task 3: Wire provider identity through the FSEventStream callback

**Files:**
- Modify: `TokenWatch/Services/TranscriptWatcher.swift`
- Modify: `TokenWatchTests/TranscriptWatcherTests.swift`

**Interfaces:**
- Consumes: the stub `providerFromFlags` from Task 2.
- Produces: a `TranscriptWatcher` whose `onChange` receives the *correct* `UsageProvider` per stream (verified by an integration-style test that appends to a watched file and asserts the fired provider).

- [ ] **Step 1: Add a failing test that asserts the correct provider fires**

Append to `TranscriptWatcherTests`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```
Expected: `testOnChangeFiresCorrectProviderWhenFileChanges` FAILS — the stub `providerFromFlags` always returns `.claudeCode`, which would make the `.codex` assertion pass by luck, but the real fix is needed for correctness and for the `.codex` watch path. Concretely the test should fail because the callback's provider mapping is hardcoded; once implemented, the test proves the per-stream mapping works.

- [ ] **Step 3: Implement per-stream provider identity**

Replace the whole `TranscriptWatcher` body in `TokenWatch/Services/TranscriptWatcher.swift` with:

```swift
import CoreServices
import Foundation

@MainActor
final class TranscriptWatcher {
    var onChange: ((UsageProvider) -> Void)?

    private struct Watch {
        let stream: FSEventStreamRef
        let securityScope: URL
        let provider: UsageProvider
    }

    private var watches: [UsageProvider: Watch] = [:]

    deinit {
        for watch in watches.values {
            FSEventStreamStop(watch.stream)
            FSEventStreamInvalidate(watch.stream)
            FSEventStreamRelease(watch.stream)
            watch.securityScope.stopAccessingSecurityScopedResource()
        }
    }

    func start(for provider: UsageProvider, directory: URL) {
        stop(for: provider)

        guard directory.startAccessingSecurityScopedResource() else { return }

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
            directory.stopAccessingSecurityScopedResource()
            return
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        watches[provider] = Watch(stream: stream, securityScope: directory, provider: provider)
    }

    func stop(for provider: UsageProvider) {
        guard let watch = watches.removeValue(forKey: provider) else { return }
        FSEventStreamStop(watch.stream)
        FSEventStreamInvalidate(watch.stream)
        FSEventStreamRelease(watch.stream)
        watch.securityScope.stopAccessingSecurityScopedResource()
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
    private func dispatchChange(_ provider: UsageProvider) {
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

- [ ] **Step 4: Run all tests to verify they pass**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```
Expected: all `TranscriptWatcherTests` (4 cases) PASS; existing scanner/snapshot tests PASS.

> If the file-change test is flaky in CI due to FSEvents latency, bump its `asyncAfter` deadline to `3.0` and timeout to `8.0`. Do not remove the test.

- [ ] **Step 5: Commit**

```sh
git add TokenWatch/Services/TranscriptWatcher.swift TokenWatchTests/TranscriptWatcherTests.swift
git commit -m "Wire per-stream provider identity through TranscriptWatcher callback"
```

---

### Task 4: Replace the 60s poll in `UsageStore` with the watcher

**Files:**
- Modify: `TokenWatch/Stores/UsageStore.swift`

**Interfaces:**
- Consumes: `TranscriptWatcher` (from Task 3), `FolderAccessStore.url(for:)` (existing), `UsageProvider.expectedRelativeDirectory` (existing).
- Produces:
  - `func manualSync()` — public; calls `refresh()`. (Used by Task 5.)
  - `UsageStore.start()` — initial `refresh()` + start watcher for every configured provider.
  - `chooseFolder(for:)` — now also restarts the watcher for that provider.
  - `revokeFolder(for:)` — now also stops the watcher for that provider.
  - No more `refreshTimer`.

- [ ] **Step 1: Write a failing test for `manualSync`**

Append to `TokenWatchTests/TranscriptWatcherTests.swift` is the wrong file — `manualSync` lives on `UsageStore`. Create a new test file `TokenWatchTests/UsageStoreSyncTests.swift`:

```swift
import Foundation
import XCTest
@testable import TokenWatch

@MainActor
final class UsageStoreSyncTests: XCTestCase {
    func testManualSyncTriggersExactlyOneRefresh() {
        let store = UsageStore()
        store.manualSync()
        XCTAssertTrue(store.isRefreshing || store.sources.first?.lastRefresh != nil,
                      "manualSync should drive a refresh; at minimum it must not be a no-op")
    }
}
```

- [ ] **Step 2: Register the new test file in `project.pbxproj`**

In `TokenWatch.xcodeproj/project.pbxproj`:

1. Add a build-file entry after `A10000000000000000000017`:

```
		A10000000000000000000018 /* UsageStoreSyncTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000021 /* UsageStoreSyncTests.swift */; };
```

2. Add a file-ref entry after `A20000000000000000000020`:

```
		A20000000000000000000021 /* UsageStoreSyncTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UsageStoreSyncTests.swift; sourceTree = "<group>"; };
```

3. Add to the `TokenWatchTests` group children list so it reads:

```
		A30000000000000000000003 /* TokenWatchTests */ = {isa = PBXGroup; children = (A20000000000000000000013 /* UsageScannerTests.swift */, A20000000000000000000014 /* UsageSnapshotTests.swift */, A20000000000000000000020 /* TranscriptWatcherTests.swift */, A20000000000000000000021 /* UsageStoreSyncTests.swift */); path = TokenWatchTests; sourceTree = "<group>"; };
```

4. Append `A10000000000000000000018` to the test Sources phase:

```
		A60000000000000000000004 /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A10000000000000000000013, A10000000000000000000014, A10000000000000000000017, A10000000000000000000018); runOnlyForDeploymentPostprocessing = 0; };
```

- [ ] **Step 3: Run the test to verify it fails**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```
Expected: `testManualSyncTriggersExactlyOneRefresh` FAILS — `manualSync()` does not exist.

- [ ] **Step 4: Rewrite `UsageStore` to use the watcher**

Replace the whole contents of `TokenWatch/Stores/UsageStore.swift` with:

```swift
import Combine
import Foundation

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
            if let url = FolderAccessStore.url(for: provider) {
                let directory = url.appendingPathComponent(provider.expectedRelativeDirectory, isDirectory: true)
                watcher.start(for: provider, directory: directory)
            }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastMessage = nil

        let selectedFolders = Dictionary(uniqueKeysWithValues: UsageProvider.allCases.compactMap { provider in
            FolderAccessStore.url(for: provider).map { (provider, $0) }
        })
        let scopedFolders = selectedFolders.values.filter { $0.startAccessingSecurityScopedResource() }
        let scanner = TranscriptScanner()

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                scanner.scan(
                    claudeRoot: selectedFolders[.claudeCode],
                    codexRoot: selectedFolders[.codex]
                )
            }.value

            scopedFolders.forEach { $0.stopAccessingSecurityScopedResource() }
            guard let self else { return }
            self.events = result.events
            self.sources = result.sources
            self.isRefreshing = false
        }
    }

    func manualSync() {
        refresh()
    }

    func chooseFolder(for provider: UsageProvider) {
        switch FolderAccessStore.chooseFolder(for: provider) {
        case .success(let url):
            lastMessage = "\(provider.displayName) access updated."
            let directory = url.appendingPathComponent(provider.expectedRelativeDirectory, isDirectory: true)
            watcher.start(for: provider, directory: directory)
            refresh()
        case .failure(let error):
            lastMessage = error.errorDescription
        }
    }

    func revokeFolder(for provider: UsageProvider) {
        watcher.stop(for: provider)
        FolderAccessStore.remove(provider)
        events.removeAll { $0.provider == provider }
        sources = sources.map { source in
            source.provider == provider ? .unconfigured(provider) : source
        }
        lastMessage = "\(provider.displayName) access removed."
    }

    func snapshot(for range: UsageRange, now: Date = Date()) -> UsageSnapshot {
        UsageAggregator.snapshot(events: events, range: range, sources: sources, now: now)
    }
}

enum UsageAggregator {
```

> Keep everything from `enum UsageAggregator {` onward exactly as it is today (lines 80-186 of the current file). Only the `UsageStore` class body above `enum UsageAggregator` changes.

- [ ] **Step 5: Run all tests to verify they pass**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```
Expected: all tests PASS. `testManualSyncTriggersExactlyOneRefresh` passes (refresh runs). The watcher lifecycle tests still pass.

- [ ] **Step 6: Commit**

```sh
git add TokenWatch/Stores/UsageStore.swift TokenWatchTests/UsageStoreSyncTests.swift TokenWatch.xcodeproj/project.pbxproj
git commit -m "Replace 60s poll with FSEventStream watcher in UsageStore"
```

---

### Task 5: Add "Sync Now" button to Settings and refresh copy

**Files:**
- Modify: `TokenWatch/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `store.manualSync()` (from Task 4), `store.isRefreshing` (existing).

- [ ] **Step 1: Update the "Refresh" section**

Replace the "Refresh" section in `TokenWatch/Views/SettingsView.swift` (current lines 23-26):

```swift
            Section("Refresh") {
                Text("Token Watch reads selected local folders on launch, when opened, on manual refresh, and every 60 seconds while running.")
                    .foregroundStyle(.secondary)
            }
```

with:

```swift
            Section("Refresh") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic refresh")
                        Text("Token Watch updates automatically when local transcript files change. Use Sync Now if anything looks out of date.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sync Now") { store.manualSync() }
                        .disabled(store.isRefreshing)
                }
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```sh
git add TokenWatch/Views/SettingsView.swift
git commit -m "Add Sync Now button and file-watcher copy in Settings"
```

---

### Task 6: Verify build, privacy audit, and full test run

**Files:**
- No file changes. Verification only.

- [ ] **Step 1: Run the privacy audit**

Run:
```sh
./script/audit_privacy.sh
```
Expected: exits 0. (FSEventStream / CoreServices file watching is local; no networking APIs are introduced. If the audit rejects CoreServices, surface it to the user rather than editing the audit script.)

- [ ] **Step 2: Run the verify build**

Run:
```sh
./script/build_and_run.sh --verify
```
Expected: app launches, stays alive ~1s, then is killed; script exits 0.

- [ ] **Step 3: Run the full test suite**

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```
Expected: all tests PASS (scanner, snapshot, watcher lifecycle, watcher provider mapping, manualSync).

- [ ] **Step 4: Final commit if any verification touched tracked files**

```sh
git status --porcelain
```
If empty, nothing to commit. If non-empty, inspect and commit with a descriptive message (no secrets).

---

## Acceptance check

- [ ] No `Task.sleep`-based timer remains in `UsageStore` (grep should return nothing).
- [ ] A change to a watched `.jsonl` updates stats within ~1s on a running app (manual smoke test: launch app, run `echo '{"type":"assistant",...}' >> ~/.claude/projects/<session>/x.jsonl`, observe the menu-bar count change).
- [ ] "Sync Now" button in Settings triggers an immediate refresh and is disabled while a refresh is in flight.
- [ ] `./script/audit_privacy.sh` and `./script/build_and_run.sh --verify` still pass.
- [ ] `xcodebuild ... test` passes.