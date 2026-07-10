# Cache-read share accuracy & unpriced-model display

**Date:** 2026-07-09
**Status:** Approved (pending spec review)
**Scope:** `TokenWatch/Services/OpenCodeScanner.swift`, `TokenWatch/Stores/UsageStore.swift`, `TokenWatch/Models/UsageModels.swift`, `TokenWatch/Views/DashboardView.swift`, `TokenWatch/Views/MenuBarPopover.swift`, `TokenWatch/Views/ModelsView.swift`, `TokenWatch/Support/Pricing.swift`, `TokenWatchTests/UsageSnapshotTests.swift`, `TokenWatchTests/OpenCodeScannerTests.swift`

## Problem

Two accuracy gaps in Token Watch's UI, both surfaced by using OpenCode through ollama-cloud:

1. **Cache-read share is meaningless when a non-reporting provider dominates.** ollama-cloud's `glm-5.2` returns no cache fields in its usage object, so OpenCode stores `tokens_cache_read = 0` for every session. The current `cacheReadShare` (`UsageStore.swift:161`) computes `cacheRead / (input + cacheRead)` across **all** events, so a large-input, zero-cache model drives the share toward 0% — making the metric uninformative for users whose selected range is dominated by ollama-cloud, while silently diluting it for everyone else.

2. **Unpriced models show "unpriced" with no way to distinguish "we know it's $0" from "we have no idea".** `ModelsView.swift:48` renders the literal string `unpriced` for every model that has no catalog match. `codex-auto-review` is a known-free internal model and should show `$0`; genuinely unknown models should show `-` (unknown) rather than a word that implies "tracked but unpriced."

## Non-goals

- **No network.** Nothing in this design fetches rates, model metadata, or provider behavior from the network. The cache denylist is a hand-maintained static constant, like the pricing catalog.
- **No price inference.** Token Watch does not synthesize an estimated USD price for models absent from the catalog. The `~` prefix introduced by this design marks an *inferred cache %*, not an inferred price. Unpriced models show `-`.
- **No change to cost math.** `Pricing.cost(of:at:)` and the per-event cost pass in `UsageAggregator.snapshot` are unchanged. A model that reports `cacheRead = 0` still contributes `0 * rate` to the cache-read cost term; it's only the *percentage share* that changes.

## Design

### A. Cache-read share — provider allowlist + step-back

#### A.1 Cache-reporting allowlist

A new static constant identifies OpenCode model-providers known **not** to report cache tokens. It lives alongside the pricing catalog as a hand-maintained list; `docs/pricing.md` gains a short "Cache reporting" section noting its existence and that it must be kept in sync.

```swift
// TokenWatch/Support/Pricing.swift (or a sibling file if preferred)
enum CacheReporting {
    /// OpenCode model-provider IDs (the `providerID` field of the model JSON
    /// stored in the `session` table) that do NOT return cache-read/cache-write
    /// token counts in their usage object. Events from these providers are
    /// excluded from the cache-read-share denominator so the percentage reflects
    /// only providers that actually report cache.
    ///
    /// Claude Code and Codex always report cache; OpenCode events are included
    /// unless their `providerID` appears here.
    static let nonReportingOpenCodeProviders: Set<String> = ["ollama-cloud"]
}
```

Why an OpenCode-model-provider denylist rather than a whole-`UsageProvider` rule: the same OpenCode install can route through multiple model providers (the user's DB shows both `ollama-cloud` and `minimax`). A provider-level rule would discard MiniMax's real cache data; a model-provider rule keeps it. `providerID` is the field OpenCode already stores in the `model` JSON column (`{"id":"glm-5.2","providerID":"ollama-cloud","variant":"max"}`).

#### A.2 Plumbing the providerID through to the aggregator

`UsageEvent` (`TokenWatch/Models/UsageModels.swift:98`) gains one optional field:

```swift
struct UsageEvent: Hashable, Sendable, Identifiable {
    let id: UUID
    let provider: UsageProvider
    let timestamp: Date
    let model: String
    let sessionToken: UUID
    let usage: TokenUsage
    let openCodeProviderID: String?  // nil for Claude/Codex; the model's
                                     // `providerID` for OpenCode events
}
```

`OpenCodeScanner` (`TokenWatch/Services/OpenCodeScanner.swift`) decodes the model JSON into `OpenCodeModel { id, providerID }` (today it only reads `id`) and passes `providerID` into the `UsageEvent`. Claude and Codex scan paths pass `nil`.

This field is **not** persisted, **not** displayed, and **not** a provider session ID — it's a model-routing tag used only for the cache filter. It doesn't touch the read-only/privacy invariants (it's a short string like `"ollama-cloud"`, not user content).

#### A.3 Denominator change in `UsageAggregator.snapshot`

Replace `UsageStore.swift:161`:

```swift
// Current:
let cacheDenominator = usage.input + usage.cacheRead
let cacheReadShare = cacheDenominator == 0 ? 0 : Double(usage.cacheRead) / Double(cacheDenominator)
```

with a filter over the selected events:

```swift
let cacheEvents = selectedEvents.filter { event in
    event.provider != .openCode
    || !CacheReporting.nonReportingOpenCodeProviders.contains(event.openCodeProviderID ?? "")
}
let cacheRead = cacheEvents.map(\.usage.cacheRead).reduce(0, +)
let cacheInput = cacheEvents.map(\.usage.input).reduce(0, +)
let cacheDenominator = cacheRead + cacheInput
let cacheReadShare: Double? =
    cacheDenominator == 0 ? nil : Double(cacheRead) / Double(cacheDenominator)
```

`usage` (the overall `TokenUsage`) and the per-provider/model breakdowns still include the ollama-cloud events — only the cache-share denominator filters them out.

#### A.4 Step-back fallback

When `cacheReadShare` is `nil` for the selected range, recompute it for progressively wider ranges until one yields a non-nil value. Order: the selected range's natural widenings — `.day → .week → .month → .total`. (If the selected range is already `.total`, there's nothing to step back to; `nil` stays `nil`.)

The recomputation reuses the same `cacheEvents` filter, just with a different `start` date. It does **not** require re-running the scanner — `UsageAggregator.snapshot` already has all `events` in memory; the step-back just re-filters with a wider window.

Track whether the returned value was inferred:

```swift
struct CacheShare: Sendable {
    let value: Double         // 0...1
    let inferred: Bool        // true if value came from a wider range than selected
}
```

`UsageSnapshot.cacheReadShare` changes type from `Double` to `CacheShare?`:
- non-nil, `inferred == false` → value is from the selected range
- non-nil, `inferred == true` → value is from a wider range
- nil → no cache-reporting data in any range (display `-`)

`UsageSnapshot.empty(...)` keeps `cacheReadShare = nil`.

### B. Display of cache %

Two call sites read `snapshot.cacheReadShare`:

- `DashboardView.swift:118` — the "Cache read share" `MetricCard` (overview grid)
- `MenuBarPopover.swift:141` — the "Cache read" `PopoverStat` (menu-bar popover)

Both render via a new helper:

```swift
func cacheShareText(_ share: CacheShare?) -> String {
    guard let share else { return "-" }
    let prefix = share.inferred ? "~" : ""
    return prefix + TokenFormatting.percentage(share.value)
}
```

So:
- selected-range value → `12%`
- stepped-back value → `~12%`
- no data anywhere → `-`

The `MetricCard.detail` text for the dashboard card changes from `"Cached input ÷ observed input"` to something like `"Cached ÷ input for cache-reporting providers"` to reflect the new denominator.

### C. Unpriced models

#### C.1 `codex-auto-review` priced at $0

Add a zero-rate catalog entry in `Pricing.swift` (before any wildcard matchers, though `codex-auto-review` is exact enough that ordering doesn't matter):

```swift
// Codex internal — no per-token cost. Exact match only, case-insensitive.
list.append(.init(matchers: ["codex-auto-review"], rate: .init(inputPerMTok: 0, cachedInputPerMTok: 0, outputPerMTok: 0)))
```

This makes `Pricing.rate(for: "codex-auto-review")` return a non-nil zero rate, so `modelPriced[key] = true` and `modelCost[key] = 0`. The model shows `$0` via the existing `model.priced == true` branch in `ModelsView`. `docs/pricing.md` gains a line noting `codex-auto-review = $0`.

#### C.2 Unknown models show `-`

`ModelsView.swift:42-52` — the `else` branch (currently `Text("unpriced")`) changes to `Text("-")`:

```swift
HStack(spacing: 4) {
    if model.priced {
        Text(TokenFormatting.usd(model.costUSD))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    } else {
        Text("-")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    Text("· In \(TokenFormatting.compact(model.usage.input)) · Out \(TokenFormatting.compact(model.usage.output))")
        ...
}
```

`CostEstimate.unpricedModelCount` and the overview banner (`DashboardView.swift:103`) keep their current behavior — they still report `N model(s) unpriced` when any unpriced model is present. The banner is the user-facing signal that the total cost is understated; the per-row `-` is the per-model signal that its price is unknown.

## Testing

- `TokenWatchTests/UsageSnapshotTests.swift` —
  - Update existing `testCacheReadShare` (line 33, `XCTAssertEqual(snapshot.cacheReadShare, 0.5, …)`) for the new `CacheShare?` type.
  - Add: cache share excludes ollama-cloud events from the denominator (only reporting providers count)
  - Add: cache share is `nil` when all selected events are from non-reporting providers
  - Add: step-back — a `.day` snapshot with only non-reporting events but `.week` data with reporting events returns a non-nil `inferred == true` value
  - Add: step-back — `.total` with no reporting events anywhere returns `nil`
- `TokenWatchTests/OpenCodeScannerTests.swift` — add a case that the scanner populates `openCodeProviderID` from the model JSON, and that it's `nil` when the JSON omits `providerID` (existing `#"{\"id\":\"glm-5.2\"}"#` seeds at lines 60/63/78 cover the missing-`providerID` path — extend them or add a `providerID`-present variant).
- `TokenWatchTests/PricingTests.swift` — add a case that `codex-auto-review` resolves to a zero rate (`rate != nil`, `cost == 0`), and that an unknown model still returns `nil`.

## Invariants preserved

- **No networking.** The cache denylist is a static `Set<String>`; no fetch.
- **Read-only transcript access.** `openCodeProviderID` is decoded from the already-read `model` JSON column; no new field is read from the DB.
- **`sessionToken` is still an in-memory UUID.** Unchanged.
- **Privacy audit.** `openCodeProviderID` is a short routing tag, not user content; no new networking API is introduced. `audit_privacy.sh` stays green.

## Files touched

| File | Change |
|---|---|
| `TokenWatch/Support/Pricing.swift` | `CacheReporting` enum + zero-rate `codex-auto-review` entry |
| `TokenWatch/Models/UsageModels.swift` | `UsageEvent.openCodeProviderID`; `CacheShare` struct; `UsageSnapshot.cacheReadShare` → `CacheShare?` |
| `TokenWatch/Services/OpenCodeScanner.swift` | Decode `providerID` from model JSON; pass into `UsageEvent` |
| `TokenWatch/Services/TranscriptScanner.swift` | Pass `openCodeProviderID: nil` for Claude/Codex events |
| `TokenWatch/Stores/UsageStore.swift` | Filter denominator; step-back fallback; return `CacheShare?` |
| `TokenWatch/Views/DashboardView.swift` | Render `CacheShare?` with `~` / `-`; update `MetricCard.detail` |
| `TokenWatch/Views/MenuBarPopover.swift` | Render `CacheShare?` |
| `TokenWatch/Views/ModelsView.swift` | `unpriced` → `-` |
| `docs/pricing.md` | Note `codex-auto-review = $0`; add "Cache reporting" section listing `ollama-cloud` as non-reporting |
| `TokenWatchTests/UsageSnapshotTests.swift` | Cache-share denominator + step-back tests |
| `TokenWatchTests/OpenCodeScannerTests.swift` | `openCodeProviderID` propagation test |
| `TokenWatchTests/PricingTests.swift` | `codex-auto-review` zero-rate test |