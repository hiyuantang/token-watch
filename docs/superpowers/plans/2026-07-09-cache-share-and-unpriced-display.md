# Cache-share accuracy & unpriced-model display Implementation Plan

**Goal:** Make the cache-read share meaningful for users of non-reporting providers (e.g. ollama-cloud via OpenCode) and replace the blanket "unpriced" label with a true $0 for codex-auto-review and "-" for genuinely unknown models.

**Architecture:** A denylist of OpenCode providerIDs gates which events contribute to the cache-read-share denominator. A step-back fallback recomputes the share from progressively wider ranges when the selected range yields no cache-reporting data, marked as inferred in the UI. A zero-rate catalog entry prices codex-auto-review at $0. Unknown models display "-".

**Tech Stack:** Swift 6, SwiftUI, SQLite via /usr/bin/sqlite3 (no library), XCTest. macOS 26+ deployment target. SWIFT_STRICT_CONCURRENCY = complete.

## Global Constraints

- No networking, ever. No URLSession, URLRequest, NWConnection, NWPathMonitor, WebSocket, or HTTPClient may be added to any file under TokenWatch/. audit_privacy.sh fails the build if they appear.
- Read-only transcript access. Scanners only decode whitelisted timestamp/model/token-usage fields.
- UsageEvent.sessionToken is an in-memory UUID, not a provider session ID. The new openCodeProviderID field is a short routing tag, not user content; not persisted.
- macOS 26.0+ deployment target. MenuBarExtra .window style, MenuBarLabel, etc. — don't lower it.
- Swift 6 with SWIFT_STRICT_CONCURRENCY = complete. Anything touching UsageStore or the watcher must be @MainActor or Sendable.
- Tests run hosted in the app via TEST_HOST. UsageStoreSyncTests can be slow (up to ~30s); other tests are fast.
- ripgrep must be installed for audit_privacy.sh.
- Commit message style: short imperative summary; feat:, fix:, test:, docs:, refactor:.
- No new files unless required. Prefer editing existing files.
- No comments unless tied to a non-obvious decision. Match the existing repo's terse comment style.

---

## File map

| File | Touched in |
|---|---|
| TokenWatch/Support/Pricing.swift | Task 1, Task 2 |
| TokenWatch/Models/UsageModels.swift | Task 3 |
| TokenWatch/Services/OpenCodeScanner.swift | Task 4 |
| TokenWatch/Stores/UsageStore.swift | Task 3, Task 5 |
| TokenWatch/Views/DashboardView.swift | Task 6 |
| TokenWatch/Views/MenuBarPopover.swift | Task 6 |
| TokenWatch/Views/ModelsView.swift | Task 6 |
| TokenWatch/Support/Formatting.swift | Task 5 |
| docs/pricing.md | Task 7 |
| TokenWatchTests/PricingTests.swift | Task 1, Task 2 |
| TokenWatchTests/UsageSnapshotTests.swift | Task 3, Task 5 |
| TokenWatchTests/OpenCodeScannerTests.swift | Task 4 |

---

## Task 1: Add the CacheReporting denylist constant

**Files:**
- Modify: TokenWatch/Support/Pricing.swift (append at end of file)
- Test: TokenWatchTests/PricingTests.swift (append new test)

**Interfaces:**
- Consumes: nothing
- Produces: enum CacheReporting { static let nonReportingOpenCodeProviders: Set<String> }

The denylist starts with just "ollama-cloud" (verified against the user's OpenCode DB: 40 sessions, all tokens_cache_read = 0).

- [ ] Step 1: Write the failing test

Append to TokenWatchTests/PricingTests.swift (inside the PricingTests class, before the closing brace):

```swift
func testCacheReportingDenylistStartsWithOllamaCloud() {
    XCTAssertTrue(CacheReporting.nonReportingOpenCodeProviders.contains("ollama-cloud"))
    // An empty string must never be considered non-reporting — events with a
    // missing providerID default to "reporting" so they aren't silently dropped.
    XCTAssertFalse(CacheReporting.nonReportingOpenCodeProviders.contains(""))
}
```

- [ ] Step 2: Run test to verify it fails

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TokenWatchTests/PricingTests/testCacheReportingDenylistStartsWithOllamaCloud test
```

Expected: FAIL — compile error `cannot find 'CacheReporting' in scope`.

- [ ] Step 3: Add the CacheReporting enum

Append at the end of TokenWatch/Support/Pricing.swift:

```swift
/// Identifies OpenCode model-provider IDs that do NOT report cache-read/cache-write
/// tokens in their usage object. Events routed through these providers are excluded
/// from the cache-read-share denominator so the percentage reflects only providers
/// that actually report cache metrics.
///
/// Claude Code and Codex always report cache, so this denylist applies only to
/// providerID values found in OpenCode's session.model JSON column.
/// Keep this list in sync with docs/pricing.md's "Cache reporting" section.
enum CacheReporting {
    static let nonReportingOpenCodeProviders: Set<String> = ["ollama-cloud"]
}
```

- [ ] Step 4: Run test to verify it passes

Run the same xcodebuild command from Step 2. Expected: PASS.

- [ ] Step 5: Run audit_privacy

Run: ./script/audit_privacy.sh
Expected: exit 0, no privacy regressions.

- [ ] Step 6: Commit

```sh
git add TokenWatch/Support/Pricing.swift TokenWatchTests/PricingTests.swift
git commit -m "feat: add CacheReporting denylist (ollama-cloud)"
```

---

## Task 2: Add codex-auto-review zero-rate entry

**Files:**
- Modify: TokenWatch/Support/Pricing.swift (add one list.append in entries)
- Test: TokenWatchTests/PricingTests.swift (append new test)

**Interfaces:**
- Consumes: nothing
- Produces: Pricing.rate(for: "codex-auto-review") returns a non-nil zero rate.

Exact-match entry — no substring matchers.

- [ ] Step 1: Write the failing test

Append to TokenWatchTests/PricingTests.swift:

```swift
func testCodexAutoReviewIsZeroRateAndPriced() {
    let rate = Pricing.rate(for: "codex-auto-review")
    XCTAssertNotNil(rate)
    XCTAssertEqual(rate?.inputPerMTok, 0)
    XCTAssertEqual(rate?.outputPerMTok, 0)
    XCTAssertEqual(rate?.cachedInputPerMTok, 0)
    // Sanity: must be free at any volume.
    let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)
    XCTAssertEqual(Pricing.cost(of: usage, at: rate!), 0)
}

func testCodexAutoReviewMatchingIsExact() {
    // Substrings must NOT match (no fallback to a different model).
    XCTAssertNil(Pricing.rate(for: "codex-auto-review-fork"))
    XCTAssertNil(Pricing.rate(for: "codex"))
}
```

- [ ] Step 2: Run test to verify it fails

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TokenWatchTests/PricingTests/testCodexAutoReviewIsZeroRateAndPriced \
  -only-testing:TokenWatchTests/PricingTests/testCodexAutoReviewMatchingIsExact test
```

Expected: FAIL — XCTAssertNotNil fails because Pricing.rate returns nil.

- [ ] Step 3: Add the catalog entry

In TokenWatch/Support/Pricing.swift, inside the entries closure, add at the end (just before `return list`):

```swift
// Codex internal routing label — not a billable model. Exact match only.
list.append(.init(matchers: ["codex-auto-review"], rate: .init(inputPerMTok: 0, cachedInputPerMTok: 0, outputPerMTok: 0)))
```

- [ ] Step 4: Run test to verify it passes

Run the same xcodebuild command from Step 2. Expected: PASS.

- [ ] Step 5: Commit

```sh
git add TokenWatch/Support/Pricing.swift TokenWatchTests/PricingTests.swift
git commit -m "feat: price codex-auto-review at zero (internal routing label)"
```

---

## Task 3: Introduce CacheShare struct and UsageEvent.openCodeProviderID

**Files:**
- Modify: TokenWatch/Models/UsageModels.swift
- Modify: TokenWatch/Stores/UsageStore.swift (update aggregator to use new type — pure wrap, no behavior change)
- Test: TokenWatchTests/UsageSnapshotTests.swift (update existing test)

**Interfaces:**
- Consumes: nothing
- Produces:
  - struct CacheShare: Sendable, Hashable { let value: Double; let inferred: Bool }
  - UsageEvent.openCodeProviderID: String? (default nil)
  - UsageSnapshot.cacheReadShare: CacheShare? (was Double)

This is a pure type change. The aggregator still computes the same value for now, just wrapped. Filter logic and step-back come in Task 5.

- [ ] Step 1: Update the existing snapshot test (TDD — see it fail)

In TokenWatchTests/UsageSnapshotTests.swift, replace line 33:

```swift
        XCTAssertEqual(snapshot.cacheReadShare, 0.5, accuracy: 0.0001)
```

with:

```swift
        XCTAssertEqual(snapshot.cacheReadShare?.value, 0.5, accuracy: 0.0001)
        XCTAssertFalse(snapshot.cacheReadShare?.inferred ?? true)
```

- [ ] Step 2: Run the test to verify it fails

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TokenWatchTests/UsageSnapshotTests/testDayRangeExcludesPriorCalendarDayAndCalculatesCacheShare test
```

Expected: FAIL — compile error `Type 'Double' has no member 'value'`.

- [ ] Step 3: Add CacheShare and the openCodeProviderID field, change cacheReadShare type

In TokenWatch/Models/UsageModels.swift:

1. Add the CacheShare struct (place it right above struct UsageEvent, after TokenUsage's closing brace on line 95):

```swift
/// A cache-read share value with a flag indicating whether it was computed from
/// the selected range or stepped back from a wider range (because the selected
/// range had no cache-reporting events). UI surfaces `inferred` via a `~` prefix.
struct CacheShare: Sendable, Hashable {
    let value: Double
    let inferred: Bool
}
```

2. Update UsageEvent — add openCodeProviderID: String? = nil:

```swift
struct UsageEvent: Hashable, Sendable, Identifiable {
    let id: UUID
    let provider: UsageProvider
    let timestamp: Date
    let model: String
    let sessionToken: UUID
    let usage: TokenUsage
    /// OpenCode model-provider routing tag (e.g. "ollama-cloud", "anthropic",
    /// "minimax"). `nil` for Claude Code and Codex events. Used only to gate
    /// which events count toward the cache-read-share denominator.
    var openCodeProviderID: String? = nil
}
```

`var` (not `let`) so existing call sites that use the implicit memberwise initializer without passing it still compile. `nil` default means every existing call site is a no-op.

3. Change UsageSnapshot.cacheReadShare:

```swift
    let cacheReadShare: CacheShare?
```

4. Update UsageSnapshot.empty(...) cacheReadShare to nil:

```swift
            cacheReadShare: nil,
```

- [ ] Step 4: Update the aggregator to wrap the current computation

In TokenWatch/Stores/UsageStore.swift, replace the cacheReadShare computation:

```swift
        let cacheDenominator = usage.input + usage.cacheRead
        let cacheReadShare: CacheShare? = cacheDenominator == 0
            ? nil
            : .init(value: Double(usage.cacheRead) / Double(cacheDenominator), inferred: false)
```

- [ ] Step 5: Run the test to verify it passes

Run the same xcodebuild command from Step 2. Expected: PASS.

- [ ] Step 6: Run full snapshot test file

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TokenWatchTests/UsageSnapshotTests test
```

Expected: all PASS.

- [ ] Step 7: Audit + commit

```sh
./script/audit_privacy.sh
git add TokenWatch/Models/UsageModels.swift TokenWatch/Stores/UsageStore.swift TokenWatchTests/UsageSnapshotTests.swift
git commit -m "refactor: introduce CacheShare type and UsageEvent.openCodeProviderID"
```

---

## Task 4: OpenCodeScanner decodes providerID from model JSON

**Files:**
- Modify: TokenWatch/Services/OpenCodeScanner.swift
- Test: TokenWatchTests/OpenCodeScannerTests.swift

**Interfaces:**
- Consumes: existing OpenCodeSessionRow.model (JSON string)
- Produces: providerID plumbed into the UsageEvent.openCodeProviderID field

- [ ] Step 1: Write the failing test

Append to TokenWatchTests/OpenCodeScannerTests.swift (inside OpenCodeScannerTests, before the // MARK: - Helpers line):

```swift
func testModelJsonProviderIDIsPlumbedIntoEvent() throws {
    let root = try makeTemporaryDirectory()
    try createOpencodeDb(in: root, sessions: [
        (id: "ses_a", model: #"{"id":"glm-5.2","providerID":"ollama-cloud","variant":"max"}"#,
         input: 10, output: 5, cacheRead: 0, cacheWrite: 0, reasoning: 0, updatedMs: 1_783_636_290_026),
        (id: "ses_b", model: #"{"id":"claude-sonnet-4","providerID":"anthropic"}"#,
         input: 50, output: 10, cacheRead: 5, cacheWrite: 2, reasoning: 0, updatedMs: 1_783_636_300_000)
    ])

    let result = OpenCodeScanner().scan(root: root, now: Date())

    let ollama = try XCTUnwrap(result.events.first { $0.model == "glm-5.2" })
    XCTAssertEqual(ollama.openCodeProviderID, "ollama-cloud")
    let anthropic = try XCTUnwrap(result.events.first { $0.model == "claude-sonnet-4" })
    XCTAssertEqual(anthropic.openCodeProviderID, "anthropic")
}

func testModelJsonMissingProviderIDYieldsNil() throws {
    let root = try makeTemporaryDirectory()
    try createOpencodeDb(in: root, sessions: [
        (id: "ses_a", model: #"{"id":"glm-5.2"}"#,
         input: 10, output: 5, cacheRead: 0, cacheWrite: 0, reasoning: 0, updatedMs: 1_783_636_290_026)
    ])

    let result = OpenCodeScanner().scan(root: root, now: Date())

    let event = try XCTUnwrap(result.events.first)
    XCTAssertNil(event.openCodeProviderID)
}
```

- [ ] Step 2: Run tests to verify they fail

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TokenWatchTests/OpenCodeScannerTests/testModelJsonProviderIDIsPlumbedIntoEvent \
  -only-testing:TokenWatchTests/OpenCodeScannerTests/testModelJsonMissingProviderIDYieldsNil test
```

Expected: FAIL — XCTAssertEqual(ollama.openCodeProviderID, "ollama-cloud") fails because the field is never set.

- [ ] Step 3: Update OpenCodeModel to decode providerID

In TokenWatch/Services/OpenCodeScanner.swift, update the private OpenCodeModel struct:

```swift
private struct OpenCodeModel: Decodable {
    let id: String?
    let providerID: String?
}
```

- [ ] Step 4: Replace decodeModelId with a richer helper

Replace the helper decodeModelId with:

```swift
    private struct DecodedModel: Sendable {
        let id: String
        let providerID: String?
    }

    private func decodeModel(_ json: String) -> DecodedModel? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(OpenCodeModel.self, from: data),
              let id = parsed.id, !id.isEmpty
        else { return nil }
        return DecodedModel(id: id, providerID: parsed.providerID)
    }
```

Then in scanDb, replace the model-resolution and event-creation block:

```swift
        for row in rows {
            let model = row.model.flatMap(decodeModel)
            if model == nil { source.malformedLines += 1 }
            let sessionToken = sessionTokens[row.id] ?? UUID()
            sessionTokens[row.id] = sessionToken
            events.append(
                UsageEvent(
                    id: UUID(),
                    provider: .openCode,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(row.timeUpdated) / 1000),
                    model: model?.id ?? "Unknown model",
                    sessionToken: sessionToken,
                    usage: TokenUsage(
                        input: row.tokensInput,
                        output: row.tokensOutput,
                        cacheRead: row.tokensCacheRead,
                        cacheWrite: row.tokensCacheWrite,
                        reasoningOutput: row.tokensReasoning
                    ),
                    openCodeProviderID: model?.providerID
                )
            )
            source.usageRecords += 1
        }
```

- [ ] Step 5: Run tests to verify they pass

Run the same xcodebuild command from Step 2. Expected: PASS.

- [ ] Step 6: Run the full scanner test file

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TokenWatchTests/OpenCodeScannerTests test
```

Expected: all PASS (including testMalformedModelJsonFallsBackToUnknownAndCountsMalformed — decodeModel returns nil for non-JSON, so the fallback path still triggers).

- [ ] Step 7: Audit + commit

```sh
./script/audit_privacy.sh
git add TokenWatch/Services/OpenCodeScanner.swift TokenWatchTests/OpenCodeScannerTests.swift
git commit -m "feat: plumb OpenCode model providerID through UsageEvent"
```

---

## Task 5: Aggregator filters cache events and steps back on miss

**Files:**
- Modify: TokenWatch/Stores/UsageStore.swift
- Modify: TokenWatch/Support/Formatting.swift (add cacheShareText(_:) helper)
- Test: TokenWatchTests/UsageSnapshotTests.swift

**Interfaces:**
- Consumes: selectedEvents, events (all events), range, now
- Produces:
  - cacheReadShare: CacheShare? populated by filtering + step-back
  - static func widerRanges(after: UsageRange) -> [UsageRange]
  - static func TokenFormatting.cacheShareText(_ share: CacheShare?) -> String

- [ ] Step 1: Write the failing test for the cache filter

Append to TokenWatchTests/UsageSnapshotTests.swift:

```swift
func testCacheShareExcludesOpenCodeNonReportingEvents() {
    let now = ISO8601DateFormatter().date(from: "2026-07-09T16:00:00Z")!
    let reporting = UsageEvent(
        id: UUID(),
        provider: .claudeCode,
        timestamp: now,
        model: "claude-test",
        sessionToken: UUID(),
        usage: TokenUsage(input: 100, output: 0, cacheRead: 50, cacheWrite: 0)
    )
    let nonReporting = UsageEvent(
        id: UUID(),
        provider: .openCode,
        timestamp: now,
        model: "glm-5.2",
        sessionToken: UUID(),
        usage: TokenUsage(input: 10_000, output: 0, cacheRead: 0, cacheWrite: 0),
        openCodeProviderID: "ollama-cloud"
    )
    let sources = UsageProvider.allCases.map(SourceHealth.unconfigured)

    let snapshot = UsageAggregator.snapshot(
        events: [reporting, nonReporting],
        range: .total,
        sources: sources,
        now: now
    )

    // Only the claude event contributes: 50 / (100 + 50) = 0.333…
    XCTAssertEqual(snapshot.cacheReadShare?.value, 50.0 / 150.0, accuracy: 0.0001)
    XCTAssertFalse(snapshot.cacheReadShare?.inferred ?? true)
    // Overall usage includes BOTH events (the filter only affects cache share).
    XCTAssertEqual(snapshot.usage.input, 10_100)
}
```

- [ ] Step 2: Run test to verify it fails

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TokenWatchTests/UsageSnapshotTests/testCacheShareExcludesOpenCodeNonReportingEvents test
```

Expected: FAIL — without filtering, cacheReadShare.value ≈ 50 / 10_100 ≈ 0.0049.

- [ ] Step 3: Filter cache events in the aggregator

In TokenWatch/Stores/UsageStore.swift, replace the cacheReadShare computation (currently wrapped form from Task 3) with a call to a new helper:

```swift
        let cacheReadShare = computeCacheShare(from: selectedEvents, allEvents: events, range: range, now: now, calendar: calendar)
```

And add the helper (place after peakActivityLabel, before the private struct ModelKey):

```swift
    private static func computeCacheShare(
        from selectedEvents: [UsageEvent],
        allEvents: [UsageEvent],
        range: UsageRange,
        now: Date,
        calendar: Calendar
    ) -> CacheShare? {
        if let share = cacheShare(over: selectedEvents) {
            return share
        }
        for wider in widerRanges(after: range) {
            let start = rangeStart(wider, now: now, calendar: calendar)
            let window = allEvents.filter { $0.timestamp >= start && $0.timestamp <= now }
            if let share = cacheShare(over: window) {
                return .init(value: share.value, inferred: true)
            }
        }
        return nil
    }

    private static func cacheShare(over events: [UsageEvent]) -> CacheShare? {
        let cacheEvents = events.filter(reportsCacheTokens)
        let cacheRead = cacheEvents.map(\.usage.cacheRead).reduce(0, +)
        let input = cacheEvents.map(\.usage.input).reduce(0, +)
        let denom = cacheRead + input
        guard denom > 0 else { return nil }
        return .init(value: Double(cacheRead) / Double(denom), inferred: false)
    }

    private static func reportsCacheTokens(_ event: UsageEvent) -> Bool {
        event.provider != .openCode
        || !CacheReporting.nonReportingOpenCodeProviders.contains(event.openCodeProviderID ?? "")
    }

    private static func widerRanges(after range: UsageRange) -> [UsageRange] {
        let all = UsageRange.allCases
        guard let start = all.firstIndex(of: range) else { return [] }
        return Array(all[(start + 1)...])
    }
```

- [ ] Step 4: Run test to verify it passes

Run the same xcodebuild command from Step 2. Expected: PASS.

- [ ] Step 5: Add the step-back tests

Append to TokenWatchTests/UsageSnapshotTests.swift:

```swift
func testCacheShareStepsBackToWiderRangeWhenSelectedHasNoReportingEvents() {
    let now = ISO8601DateFormatter().date(from: "2026-07-09T16:00:00Z")!
    // 1D only has non-reporting events.
    let recentNonReporting = UsageEvent(
        id: UUID(),
        provider: .openCode,
        timestamp: now,
        model: "glm-5.2",
        sessionToken: UUID(),
        usage: TokenUsage(input: 1_000, output: 0, cacheRead: 0, cacheWrite: 0),
        openCodeProviderID: "ollama-cloud"
    )
    // Older event in the week window from a reporting provider.
    let oldReporting = UsageEvent(
        id: UUID(),
        provider: .claudeCode,
        timestamp: ISO8601DateFormatter().date(from: "2026-06-10T09:00:00Z")!,
        model: "claude-test",
        sessionToken: UUID(),
        usage: TokenUsage(input: 200, output: 0, cacheRead: 100, cacheWrite: 0)
    )
    let sources = UsageProvider.allCases.map(SourceHealth.unconfigured)

    let snapshot = UsageAggregator.snapshot(
        events: [recentNonReporting, oldReporting],
        range: .day,
        sources: sources,
        now: now
    )

    // 100 / (200 + 100) = 0.333…
    XCTAssertEqual(snapshot.cacheReadShare?.value, 100.0 / 300.0, accuracy: 0.0001)
    XCTAssertTrue(snapshot.cacheReadShare?.inferred ?? false)
}

func testCacheShareIsNilWhenNoRangeHasReportingEvents() {
    let now = ISO8601DateFormatter().date(from: "2026-07-09T16:00:00Z")!
    let onlyNonReporting = UsageEvent(
        id: UUID(),
        provider: .openCode,
        timestamp: now,
        model: "glm-5.2",
        sessionToken: UUID(),
        usage: TokenUsage(input: 1_000, output: 500, cacheRead: 0, cacheWrite: 0),
        openCodeProviderID: "ollama-cloud"
    )
    let sources = UsageProvider.allCases.map(SourceHealth.unconfigured)

    let snapshot = UsageAggregator.snapshot(
        events: [onlyNonReporting],
        range: .day,
        sources: sources,
        now: now
    )

    XCTAssertNil(snapshot.cacheReadShare)
    // Usage totals are still computed from all events, regardless of cache reporting.
    XCTAssertEqual(snapshot.usage.input, 1_000)
}

func testCacheShareIsNilWhenTotalRangeHasNoReportingEvents() {
    let now = ISO8601DateFormatter().date(from: "2026-07-09T16:00:00Z")!
    let onlyNonReporting = UsageEvent(
        id: UUID(),
        provider: .openCode,
        timestamp: ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")!,
        model: "glm-5.2",
        sessionToken: UUID(),
        usage: TokenUsage(input: 100, output: 0, cacheRead: 0, cacheWrite: 0),
        openCodeProviderID: "ollama-cloud"
    )
    let sources = UsageProvider.allCases.map(SourceHealth.unconfigured)

    let snapshot = UsageAggregator.snapshot(
        events: [onlyNonReporting],
        range: .total,
        sources: sources,
        now: now
    )

    XCTAssertNil(snapshot.cacheReadShare)
}
```

- [ ] Step 6: Run all snapshot tests

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TokenWatchTests/UsageSnapshotTests test
```

Expected: all PASS.

- [ ] Step 7: Add TokenFormatting.cacheShareText

Append a new helper to TokenWatch/Support/Formatting.swift (right after usd(_:)):

```swift
/// Cache-share display string. `~` prefix when the value was inferred by
/// stepping back to a wider range; `-` when no cache-reporting data exists
/// in any range.
static func cacheShareText(_ share: CacheShare?) -> String {
    guard let share else { return "-" }
    let prefix = share.inferred ? "~" : ""
    return prefix + percentage(share.value)
}
```

- [ ] Step 8: Verify it compiles

The helper has no call sites yet (Task 6 wires them). Build the project to confirm it compiles.

Run:
```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' build
```

Expected: BUILD SUCCEEDED.

- [ ] Step 9: Audit + commit

```sh
./script/audit_privacy.sh
git add TokenWatch/Stores/UsageStore.swift TokenWatch/Support/Formatting.swift TokenWatchTests/UsageSnapshotTests.swift
git commit -m "feat: filter cache-share denominator by provider; add step-back fallback"
```

---

## Task 6: View updates — Dashboard, MenuBar, Models

**Files:**
- Modify: TokenWatch/Views/DashboardView.swift (cache-share metric card)
- Modify: TokenWatch/Views/MenuBarPopover.swift (cache-read stat)
- Modify: TokenWatch/Views/ModelsView.swift (unpriced label)

Three small one-line changes. No new tests — visual changes; existing tests cover the data path.

- [ ] Step 1: Update DashboardView cache-share card

In TokenWatch/Views/DashboardView.swift, update the MetricCard:

```swift
                        MetricCard(
                            title: "Cache read share",
                            value: TokenFormatting.cacheShareText(snapshot.cacheReadShare),
                            detail: "Cached ÷ input for cache-reporting providers",
                            symbol: "arrow.trianglehead.2.clockwise",
                            tint: .mint
                        )
```

- [ ] Step 2: Update MenuBarPopover cache-read stat

In TokenWatch/Views/MenuBarPopover.swift, replace:

```swift
                PopoverStat(title: "Cache read", value: TokenFormatting.percentage(snapshot.cacheReadShare))
```

with:

```swift
                PopoverStat(title: "Cache read", value: TokenFormatting.cacheShareText(snapshot.cacheReadShare))
```

- [ ] Step 3: Update ModelsView unpriced label

In TokenWatch/Views/ModelsView.swift, replace the else branch:

```swift
                                } else {
                                    Text("-")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
```

- [ ] Step 4: Build to verify everything compiles

```sh
./script/audit_privacy.sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' build
```

Expected: BUILD SUCCEEDED, audit passes.

- [ ] Step 5: Run --verify smoke test

Run: ./script/build_and_run.sh --verify
Expected: app launches and exits cleanly.

- [ ] Step 6: Commit

```sh
git add TokenWatch/Views/DashboardView.swift TokenWatch/Views/MenuBarPopover.swift TokenWatch/Views/ModelsView.swift
git commit -m "feat: render cache-share with ~ prefix and - fallback; show - for unpriced models"
```

---

## Task 7: Update docs/pricing.md

**Files:**
- Modify: docs/pricing.md

- [ ] Step 1: Append documentation

Append at the end of docs/pricing.md:

```markdown

## Cache reporting

Not every provider returns cache-read/cache-write tokens in its usage object.
Token Watch excludes these from the cache-read-share denominator so the
percentage reflects only providers that actually report cache. Update
`CacheReporting.nonReportingOpenCodeProviders` in `TokenWatch/Support/Pricing.swift`
and add a row here when this list changes.

| OpenCode `providerID` | Status |
|---|---|
| `ollama-cloud` | does not report cache (e.g. glm-5.2 always returns 0) |

## Internal labels

Some model strings are routing labels, not billable models. These are priced
at $0 in the catalog so Token Watch treats them as priced (no "unpriced" gap
in the cost estimate).

| Model | Rate |
|---|---|
| `codex-auto-review` | $0 in / $0 out / $0 cache |
```

- [ ] Step 2: Commit

```sh
git add docs/pricing.md
git commit -m "docs: document CacheReporting denylist and codex-auto-review zero rate"
```

---

## Task 8: Full verification

- [ ] Step 1: Privacy audit

```sh
./script/audit_privacy.sh
```

Expected: exit 0.

- [ ] Step 2: Full test suite

```sh
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' test
```

Expected: all tests pass. (UsageStoreSyncTests is slow; allow up to ~60s.)

- [ ] Step 3: Launch verify

```sh
./script/build_and_run.sh --verify
```

Expected: app launches and exits cleanly.

- [ ] Step 4: Manual check (optional, recommended)

Launch the app with ./script/build_and_run.sh, open the dashboard, and confirm:
- A range that contains only ollama-cloud glm-5.2 events shows "-" for cache share (no reported data anywhere).
- A range that contains only Claude/Codex events shows a plain percentage.
- A range where ollama-cloud events are excluded from the denominator yields a higher % than before.
- A codex-auto-review event (or any unknown model) shows "-" in the Models tab; a codex-auto-review event shows $0 if encountered.

---

## Self-review

**1. Spec coverage:**

| Spec section | Task |
|---|---|
| A.1 Cache-reporting allowlist constant | Task 1 |
| A.2 Plumbing openCodeProviderID through | Task 3 (type), Task 4 (scanner) |
| A.3 Denominator change | Task 5 |
| A.4 Step-back fallback | Task 5 |
| B. Display of cache % (~, plain, -) | Task 5 (helper), Task 6 (call sites) |
| C.1 codex-auto-review = $0 | Task 2 |
| C.2 Unknown models show - | Task 6 |
| docs/pricing.md notes | Task 7 |
| UsageSnapshotTests updates | Task 3 + Task 5 |
| OpenCodeScannerTests propagation | Task 4 |
| PricingTests cases | Task 1 + Task 2 |

**2. Placeholder scan:** No TBDs/TODOs. All code blocks are complete. No "similar to Task N" shortcuts.

**3. Type consistency:** CacheShare defined once (Task 3), referenced by name everywhere. widerRanges and cacheShare defined in Task 5 and only referenced there. TokenFormatting.cacheShareText defined in Task 5, called from Task 6. No naming drift.

**4. Invariants preserved:** No networking APIs introduced. openCodeProviderID is decoded from the already-read model JSON (read-only). sessionToken unchanged. No persistence. audit_privacy.sh runs after every code-touching task.

**5. Test type initialization risk:** Task 3 changes UsageEvent's init signature by adding a defaulted optional field. Existing call sites that use the implicit memberwise initializer compile unchanged because the field defaults to nil. Verified by inspecting TranscriptScanner.swift line 121 (claude), line 207 (codex), and OpenCodeScanner.swift line 57 (openCode, modified in Task 4).

**6. widerRanges edge case:** UsageRange.allCases order is [.day, .week, .month, .total]. firstIndex(of: .total) = 3, so (3+1)... is empty. For .day, returns [.week, .month, .total]. Correct.