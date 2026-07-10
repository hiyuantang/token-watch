# Model Display Names Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace raw model identifiers (e.g. `claude-opus-4-8`) in the UI with human-friendly display names (e.g. `Claude Opus 4.8`).

**Architecture:** Add a `displayName` field to the existing `Pricing.Entry` struct so naming lives alongside pricing — the ordered matchers already uniquely identify every model. A new `Pricing.displayName(for:)` walks the same `entries` list and falls back to a `ModelNamePrettifier` for unknown models. Two UI call sites swap `model.model` for `Pricing.displayName(for: model.model)`. No data-model change.

**Tech Stack:** Swift 6.0, SwiftUI, Xcode (`TokenWatch.xcodeproj`), XCTest.

## Global Constraints

- macOS 26.0+ deployment target; Swift 6.0 with `SWIFT_STRICT_CONCURRENCY = complete` — all new types must be `Sendable`.
- No networking. The privacy audit (`script/audit_privacy.sh`) runs as part of `build_and_run.sh`; no new Swift file under `TokenWatch/` may touch `URLSession`/`URLRequest`/`NWConnection`/`NWPathMonitor`/`WebSocket`/`HTTPClient`.
- Tests use `@testable import TokenWatch` and run hosted in the app (`TEST_HOST = $(BUILT_PRODUCTS_DIR)/TokenWatch.app/...`).
- Comments: keep minimal and tied to non-obvious decisions. Don't add section-banner comments.
- Display names use spaces (not hyphens) as separators: `Claude Opus 4.8`, `GPT 5.6 Sol`, `GLM 5.2`, `DeepSeek V4 Pro`.

---

### Task 1: Add `displayName` field to `Pricing.Entry` and populate the catalog

**Files:**
- Modify: `TokenWatch/Support/Pricing.swift:35-45` (Entry struct), `TokenWatch/Support/Pricing.swift:57-145` (every `list.append` call)

**Interfaces:**
- Produces: `Entry.displayName: String` — a human-friendly model name on every catalog entry, accessible to `Pricing.displayName(for:)` (Task 2).

- [ ] **Step 1: Add the `displayName` field to `Entry` and its initializer**

Edit `TokenWatch/Support/Pricing.swift` — replace the `Entry` struct (lines 35-45) with:

```swift
    private struct Entry: Sendable {
        let matchers: [String]
        let rate: Rate
        let displayName: String
        let exact: Bool

        init(matchers: [String], rate: Rate, displayName: String, exact: Bool = false) {
            self.matchers = matchers
            self.rate = rate
            self.displayName = displayName
            self.exact = exact
        }
    }
```

- [ ] **Step 2: Add `displayName:` to every `list.append` in the `entries` builder**

Replace the entire block of `list.append` calls (lines 57-145) with the following, which adds a `displayName:` argument to each existing call. The `rate:` values are unchanged — only `displayName:` is new:

```swift
        list.append(.init(matchers: ["claude-opus-4-8", "claude-opus-4.8", "opus-4-8"], rate: .init(inputPerMTok: 5.00, cachedInputPerMTok: 0.50, outputPerMTok: 25.00), displayName: "Claude Opus 4.8"))
        list.append(.init(matchers: ["claude-opus-4-7", "claude-opus-4.7", "opus-4-7"], rate: .init(inputPerMTok: 5.00, cachedInputPerMTok: 0.50, outputPerMTok: 25.00), displayName: "Claude Opus 4.7"))
        list.append(.init(matchers: ["claude-opus-4-6", "claude-opus-4.6", "opus-4-6"], rate: .init(inputPerMTok: 5.00, cachedInputPerMTok: 0.50, outputPerMTok: 25.00), displayName: "Claude Opus 4.6"))
        list.append(.init(matchers: ["claude-opus-4-5", "claude-opus-4.5", "opus-4-5"], rate: .init(inputPerMTok: 5.00, cachedInputPerMTok: 0.50, outputPerMTok: 25.00), displayName: "Claude Opus 4.5"))
        list.append(.init(matchers: ["claude-opus-4-1", "claude-opus-4.1", "opus-4-1"], rate: .init(inputPerMTok: 15.00, cachedInputPerMTok: 1.50, outputPerMTok: 75.00), displayName: "Claude Opus 4.1"))
        list.append(.init(matchers: ["claude-opus-4", "opus-4"], rate: .init(inputPerMTok: 15.00, cachedInputPerMTok: 1.50, outputPerMTok: 75.00), displayName: "Claude Opus 4"))
        list.append(.init(matchers: ["claude-fable-5", "fable-5"], rate: .init(inputPerMTok: 10.00, cachedInputPerMTok: 1.00, outputPerMTok: 50.00), displayName: "Claude Fable 5"))
        list.append(.init(matchers: ["claude-mythos-5", "mythos-5"], rate: .init(inputPerMTok: 10.00, cachedInputPerMTok: 1.00, outputPerMTok: 50.00), displayName: "Claude Mythos 5"))
        // Sonnet 5 introductory ($2/$10) is in effect through 2026-08-31; from
        // 2026-09-01 it becomes $3/$15. Token Watch uses the introductory rate
        // while it is active; update on the cutover date.
        list.append(.init(matchers: ["claude-sonnet-5", "sonnet-5"], rate: .init(inputPerMTok: 2.00, cachedInputPerMTok: 0.20, outputPerMTok: 10.00), displayName: "Claude Sonnet 5"))
        list.append(.init(matchers: ["claude-sonnet-4-6", "claude-sonnet-4.6", "sonnet-4-6"], rate: .init(inputPerMTok: 3.00, cachedInputPerMTok: 0.30, outputPerMTok: 15.00), displayName: "Claude Sonnet 4.6"))
        list.append(.init(matchers: ["claude-sonnet-4-5", "claude-sonnet-4.5", "sonnet-4-5"], rate: .init(inputPerMTok: 3.00, cachedInputPerMTok: 0.30, outputPerMTok: 15.00), displayName: "Claude Sonnet 4.5"))
        list.append(.init(matchers: ["claude-sonnet-4"], rate: .init(inputPerMTok: 3.00, cachedInputPerMTok: 0.30, outputPerMTok: 15.00), displayName: "Claude Sonnet 4"))
        list.append(.init(matchers: ["claude-haiku-4-5", "claude-haiku-4.5", "haiku-4-5"], rate: .init(inputPerMTok: 1.00, cachedInputPerMTok: 0.10, outputPerMTok: 5.00), displayName: "Claude Haiku 4.5"))
        list.append(.init(matchers: ["claude-haiku-3-5", "claude-haiku-3.5", "haiku-3-5"], rate: .init(inputPerMTok: 0.80, cachedInputPerMTok: 0.08, outputPerMTok: 4.00), displayName: "Claude Haiku 3.5"))

        // OpenAI — GPT-5 series
        // Source: https://platform.openai.com/docs/pricing (2026-07-09)
        // Cached input = 0.1× input. Reasoning output billed at output rate.
        list.append(.init(matchers: ["gpt-5.6-sol", "gpt-5-6-sol"], rate: .init(inputPerMTok: 5.00, cachedInputPerMTok: 0.50, outputPerMTok: 30.00), displayName: "GPT 5.6 Sol"))
        list.append(.init(matchers: ["gpt-5.6-terra", "gpt-5-6-terra"], rate: .init(inputPerMTok: 2.50, cachedInputPerMTok: 0.25, outputPerMTok: 15.00), displayName: "GPT 5.6 Terra"))
        list.append(.init(matchers: ["gpt-5.6-luna", "gpt-5-6-luna"], rate: .init(inputPerMTok: 1.00, cachedInputPerMTok: 0.10, outputPerMTok: 6.00), displayName: "GPT 5.6 Luna"))
        list.append(.init(matchers: ["gpt-5.5-pro", "gpt-5-5-pro"], rate: .init(inputPerMTok: 30.00, cachedInputPerMTok: 3.00, outputPerMTok: 180.00), displayName: "GPT 5.5 Pro"))
        list.append(.init(matchers: ["gpt-5.5"], rate: .init(inputPerMTok: 5.00, cachedInputPerMTok: 0.50, outputPerMTok: 30.00), displayName: "GPT 5.5"))
        list.append(.init(matchers: ["gpt-5.4-pro", "gpt-5-4-pro"], rate: .init(inputPerMTok: 30.00, cachedInputPerMTok: 3.00, outputPerMTok: 180.00), displayName: "GPT 5.4 Pro"))
        list.append(.init(matchers: ["gpt-5.4"], rate: .init(inputPerMTok: 2.50, cachedInputPerMTok: 0.25, outputPerMTok: 15.00), displayName: "GPT 5.4"))
        list.append(.init(matchers: ["gpt-5.2-pro", "gpt-5-2-pro"], rate: .init(inputPerMTok: 21.00, cachedInputPerMTok: 2.10, outputPerMTok: 168.00), displayName: "GPT 5.2 Pro"))
        list.append(.init(matchers: ["gpt-5.2-codex", "gpt-5-2-codex"], rate: .init(inputPerMTok: 1.75, cachedInputPerMTok: 0.175, outputPerMTok: 14.00), displayName: "GPT 5.2 Codex"))
        list.append(.init(matchers: ["gpt-5.2"], rate: .init(inputPerMTok: 1.75, cachedInputPerMTok: 0.175, outputPerMTok: 14.00), displayName: "GPT 5.2"))
        list.append(.init(matchers: ["gpt-5.1-codex", "gpt-5-1-codex"], rate: .init(inputPerMTok: 1.25, cachedInputPerMTok: 0.125, outputPerMTok: 10.00), displayName: "GPT 5.1 Codex"))
        list.append(.init(matchers: ["gpt-5.1"], rate: .init(inputPerMTok: 1.75, cachedInputPerMTok: 0.175, outputPerMTok: 14.00), displayName: "GPT 5.1"))
        list.append(.init(matchers: ["gpt-5-pro"], rate: .init(inputPerMTok: 15.00, cachedInputPerMTok: 1.50, outputPerMTok: 120.00), displayName: "GPT 5 Pro"))
        list.append(.init(matchers: ["gpt-5-codex"], rate: .init(inputPerMTok: 1.25, cachedInputPerMTok: 0.125, outputPerMTok: 10.00), displayName: "GPT 5 Codex"))
        list.append(.init(matchers: ["gpt-5-mini", "gpt-5-mini"], rate: .init(inputPerMTok: 0.25, cachedInputPerMTok: 0.025, outputPerMTok: 2.00), displayName: "GPT 5 Mini"))
        list.append(.init(matchers: ["gpt-5-nano"], rate: .init(inputPerMTok: 0.05, cachedInputPerMTok: 0.005, outputPerMTok: 0.40), displayName: "GPT 5 Nano"))
        // Bare "gpt-5" must be matched last among the GPT-5 family so it does not
        // shadow the more specific variants above. It is placed here on purpose.
        list.append(.init(matchers: ["gpt-5"], rate: .init(inputPerMTok: 1.25, cachedInputPerMTok: 0.125, outputPerMTok: 10.00), displayName: "GPT 5"))

        // Z.ai — GLM-5 series (and active GLM-4.x fallbacks)
        // Source: https://docs.z.ai/guides/overview/pricing (2026-07-09)
        list.append(.init(matchers: ["glm-5.2", "glm-5-2"], rate: .init(inputPerMTok: 1.40, cachedInputPerMTok: 0.26, outputPerMTok: 4.40), displayName: "GLM 5.2"))
        list.append(.init(matchers: ["glm-5.1", "glm-5-1"], rate: .init(inputPerMTok: 1.40, cachedInputPerMTok: 0.26, outputPerMTok: 4.40), displayName: "GLM 5.1"))
        list.append(.init(matchers: ["glm-5-turbo", "glm-5-turbo"], rate: .init(inputPerMTok: 1.20, cachedInputPerMTok: 0.24, outputPerMTok: 4.00), displayName: "GLM 5 Turbo"))
        list.append(.init(matchers: ["glm-5"], rate: .init(inputPerMTok: 1.00, cachedInputPerMTok: 0.20, outputPerMTok: 3.20), displayName: "GLM 5"))
        list.append(.init(matchers: ["glm-4.7-flashx", "glm-4-7-flashx"], rate: .init(inputPerMTok: 0.07, cachedInputPerMTok: 0.01, outputPerMTok: 0.40), displayName: "GLM 4.7 FlashX"))
        list.append(.init(matchers: ["glm-4.7-flash", "glm-4-7-flash", "glm-4.5-flash", "glm-4-5-flash"], rate: .init(inputPerMTok: 0, cachedInputPerMTok: 0, outputPerMTok: 0), displayName: "GLM 4.7 Flash"))
        list.append(.init(matchers: ["glm-4.7", "glm-4-7"], rate: .init(inputPerMTok: 0.60, cachedInputPerMTok: 0.11, outputPerMTok: 2.20), displayName: "GLM 4.7"))
        list.append(.init(matchers: ["glm-4.6", "glm-4-6"], rate: .init(inputPerMTok: 0.60, cachedInputPerMTok: 0.11, outputPerMTok: 2.20), displayName: "GLM 4.6"))
        list.append(.init(matchers: ["glm-4.5-air", "glm-4-5-air"], rate: .init(inputPerMTok: 0.20, cachedInputPerMTok: 0.03, outputPerMTok: 1.10), displayName: "GLM 4.5 Air"))
        list.append(.init(matchers: ["glm-4.5", "glm-4-5"], rate: .init(inputPerMTok: 0.60, cachedInputPerMTok: 0.11, outputPerMTok: 2.20), displayName: "GLM 4.5"))

        // Moonshot AI — Kimi
        // Source: https://platform.moonshot.ai/docs/pricing (2026-07-09)
        list.append(.init(matchers: ["kimi-k2.7-code", "kimi-k2-7-code", "kimi-k2.7"], rate: .init(inputPerMTok: 0.95, cachedInputPerMTok: 0.19, outputPerMTok: 4.00), displayName: "Kimi K2.7 Code"))
        list.append(.init(matchers: ["kimi-k2.6", "kimi-k2-6"], rate: .init(inputPerMTok: 0.95, cachedInputPerMTok: 0.19, outputPerMTok: 4.00), displayName: "Kimi K2.6"))
        list.append(.init(matchers: ["kimi-k2.5", "kimi-k2-5"], rate: .init(inputPerMTok: 0.60, cachedInputPerMTok: 0.15, outputPerMTok: 3.00), displayName: "Kimi K2.5"))
        list.append(.init(matchers: ["kimi-k2-thinking-turbo", "kimi-k2-thinking-turbo"], rate: .init(inputPerMTok: 1.15, cachedInputPerMTok: 0.29, outputPerMTok: 8.00), displayName: "Kimi K2 Thinking Turbo"))
        list.append(.init(matchers: ["kimi-k2-thinking", "kimi-thinking"], rate: .init(inputPerMTok: 0.60, cachedInputPerMTok: 0.15, outputPerMTok: 2.50), displayName: "Kimi K2 Thinking"))
        list.append(.init(matchers: ["kimi-k2"], rate: .init(inputPerMTok: 0.60, cachedInputPerMTok: 0.15, outputPerMTok: 2.50), displayName: "Kimi K2"))

        // MiniMax
        // Source: https://platform.minimax.io/docs/guides/pricing-paygo (2026-07-09)
        // Standard tier only; highspeed/priority (1.5–2×) not modeled.
        list.append(.init(matchers: ["minimax-m3", "minimax-m-3"], rate: .init(inputPerMTok: 0.30, cachedInputPerMTok: 0.06, outputPerMTok: 1.20), displayName: "MiniMax M3"))
        list.append(.init(matchers: ["minimax-m2.7", "minimax-m-2-7"], rate: .init(inputPerMTok: 0.30, cachedInputPerMTok: 0.06, outputPerMTok: 1.20), displayName: "MiniMax M2.7"))
        list.append(.init(matchers: ["minimax-m2.5", "minimax-m-2-5"], rate: .init(inputPerMTok: 0.30, cachedInputPerMTok: 0.03, outputPerMTok: 1.20), displayName: "MiniMax M2.5"))
        list.append(.init(matchers: ["minimax-m2.1", "minimax-m-2-1"], rate: .init(inputPerMTok: 0.30, cachedInputPerMTok: 0.03, outputPerMTok: 1.20), displayName: "MiniMax M2.1"))
        list.append(.init(matchers: ["minimax-m2", "minimax-m-2"], rate: .init(inputPerMTok: 0.30, cachedInputPerMTok: 0.03, outputPerMTok: 1.20), displayName: "MiniMax M2"))

        // DeepSeek — V4 series (and V3.2 fallback)
        // Source: https://api-docs.deepseek.com/quick_start/pricing (2026-07-09)
        // Regular (off-peak) USD prices; peak tier (2×) not modeled.
        // deepseek-chat / deepseek-reasoner are deprecated aliases routing to
        // V4-Flash; map them here so legacy transcripts still resolve.
        list.append(.init(matchers: ["deepseek-v4-pro", "deepseek-v4-pro"], rate: .init(inputPerMTok: 0.435, cachedInputPerMTok: 0.003625, outputPerMTok: 0.87), displayName: "DeepSeek V4 Pro"))
        list.append(.init(matchers: ["deepseek-v4-flash", "deepseek-chat", "deepseek-reasoner"], rate: .init(inputPerMTok: 0.14, cachedInputPerMTok: 0.0028, outputPerMTok: 0.28), displayName: "DeepSeek V4 Flash"))
        list.append(.init(matchers: ["deepseek-v3.2-speciale", "deepseek-v3-2-speciale"], rate: .init(inputPerMTok: 0.27, cachedInputPerMTok: 0.027, outputPerMTok: 0.40), displayName: "DeepSeek V3.2 Speciale"))
        list.append(.init(matchers: ["deepseek-v3.2", "deepseek-v3-2"], rate: .init(inputPerMTok: 0.28, cachedInputPerMTok: 0.028, outputPerMTok: 0.42), displayName: "DeepSeek V3.2"))

        // Xiaomi — MiMo (appears in Codex transcripts as mimo-v2.5-pro etc.)
        // Source: Xiaomi / AtlasCloud hosted pricing (2026-07-09)
        list.append(.init(matchers: ["mimo-v2.5-pro", "mimo-v2-5-pro"], rate: .init(inputPerMTok: 0.435, cachedInputPerMTok: 0.0036, outputPerMTok: 0.87), displayName: "MiMo V2.5 Pro"))
        list.append(.init(matchers: ["mimo-v2-pro", "mimo-v2-pro"], rate: .init(inputPerMTok: 0.435, cachedInputPerMTok: 0.0036, outputPerMTok: 0.87), displayName: "MiMo V2 Pro"))

        // Codex internal routing label — not a billable model. Exact match only.
        list.append(.init(matchers: ["codex-auto-review"], rate: .init(inputPerMTok: 0, cachedInputPerMTok: 0, outputPerMTok: 0), displayName: "Codex Auto Review", exact: true))
```

- [ ] **Step 3: Build to verify the catalog still compiles**

Run: `./script/build_and_run.sh --verify`
Expected: builds and launches successfully (the `displayName:` argument is new but all existing tests still reference `rate(for:)` which is unchanged at this point — the build confirms the struct change is consistent).

- [ ] **Step 4: Commit**

```bash
git add TokenWatch/Support/Pricing.swift
git commit -m "Add displayName field to Pricing.Entry and populate catalog"
```

---

### Task 2: Add `Pricing.displayName(for:)` and `ModelNamePrettifier`

**Files:**
- Modify: `TokenWatch/Support/Pricing.swift` — insert new code after the existing `rate(for:)` function (after line 161 in the pre-Task-1 file, i.e. after `rate(for:)`'s closing brace)
- Test: `TokenWatchTests/PricingTests.swift`

**Interfaces:**
- Consumes: `Pricing.entries`, `Pricing.matches(_:needle:)` (from Task 1)
- Produces: `Pricing.displayName(for model: String) -> String` — returns the catalog display name for a known model, or a prettified version of the raw string for unknown models. Used by Task 3.
- Produces: `ModelNamePrettifier.prettify(_ raw: String) -> String` — the fallback formatter.

- [ ] **Step 1: Write the failing tests**

Append to `TokenWatchTests/PricingTests.swift` (before the final closing `}` of the class):

```swift

    func testDisplayNameForKnownModels() {
        XCTAssertEqual(Pricing.displayName(for: "claude-opus-4-8"), "Claude Opus 4.8")
        XCTAssertEqual(Pricing.displayName(for: "gpt-5.6-sol"), "GPT 5.6 Sol")
        XCTAssertEqual(Pricing.displayName(for: "glm-5.2"), "GLM 5.2")
        XCTAssertEqual(Pricing.displayName(for: "kimi-k2.7-code"), "Kimi K2.7 Code")
        XCTAssertEqual(Pricing.displayName(for: "deepseek-v4-pro"), "DeepSeek V4 Pro")
        XCTAssertEqual(Pricing.displayName(for: "minimax-m3"), "MiniMax M3")
    }

    func testDisplayNameForUnknownModelIsPrettified() {
        XCTAssertEqual(Pricing.displayName(for: "some-new-model-xyz"), "Some New Model Xyz")
    }

    func testDisplayNameForCodexAutoReviewIsExact() {
        XCTAssertEqual(Pricing.displayName(for: "codex-auto-review"), "Codex Auto Review")
    }

    func testDisplayNameOrderingGpt52NotGpt5() {
        // gpt-5.2 must resolve to "GPT 5.2", not "GPT 5" (bare gpt-5 is last).
        XCTAssertEqual(Pricing.displayName(for: "gpt-5.2"), "GPT 5.2")
    }

    func testDisplayNamePrettifierHandlesUnderscoreSeparator() {
        XCTAssertEqual(Pricing.displayName(for: "acme_llm_2.0"), "Acme Llm 2.0")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' test \
  -only-testing:TokenWatchTests/PricingTests/testDisplayNameForKnownModels
```
Expected: FAIL — `displayName(for:)` does not exist (compile error: "Pricing has no member 'displayName'").

- [ ] **Step 3: Add `Pricing.displayName(for:)` and `ModelNamePrettifier`**

In `TokenWatch/Support/Pricing.swift`, insert the following immediately after the `rate(for:)` function's closing brace (and before `private static func matches`):

```swift

    /// Human-friendly name for a model identifier. Matches the same ordered
    /// `entries` walk as `rate(for:)`, so the name is consistent with the
    /// pricing match. Unknown models fall back to `ModelNamePrettifier`.
    static func displayName(for model: String) -> String {
        let needle = model.lowercased()
        for entry in entries where matches(entry, needle: needle) {
            return entry.displayName
        }
        return ModelNamePrettifier.prettify(model)
    }
```

Then insert the following after the closing `}` of `struct Pricing` (before `/// Identifies OpenCode model-provider IDs...`):

```swift

/// Best-effort prettifier for model identifiers with no catalog match. Splits
/// on `-`/`_`, title-cases each token, and joins with spaces. Known models
/// never hit this path — they have explicit `displayName`s in `Pricing`.
enum ModelNamePrettifier {
    static func prettify(_ raw: String) -> String {
        raw.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' test \
  -only-testing:TokenWatchTests/PricingTests/testDisplayNameForKnownModels \
  -only-testing:TokenWatchTests/PricingTests/testDisplayNameForUnknownModelIsPrettified \
  -only-testing:TokenWatchTests/PricingTests/testDisplayNameForCodexAutoReviewIsExact \
  -only-testing:TokenWatchTests/PricingTests/testDisplayNameOrderingGpt52NotGpt5 \
  -only-testing:TokenWatchTests/PricingTests/testDisplayNamePrettifierHandlesUnderscoreSeparator
```
Expected: all 5 new tests PASS.

- [ ] **Step 5: Run the full test suite to confirm no regressions**

Run:
```bash
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' test
```
Expected: all tests PASS (existing pricing tests are unaffected — `rate(for:)` behavior is unchanged).

- [ ] **Step 6: Commit**

```bash
git add TokenWatch/Support/Pricing.swift TokenWatchTests/PricingTests.swift
git commit -m "Add Pricing.displayName(for:) and ModelNamePrettifier fallback"
```

---

### Task 3: Wire `displayName` into the UI

**Files:**
- Modify: `TokenWatch/Views/ModelsView.swift:26`
- Modify: `TokenWatch/Views/MenuBarPopover.swift:159`

**Interfaces:**
- Consumes: `Pricing.displayName(for:)` (from Task 2)
- Produces: UI text shows human-friendly model names instead of raw identifiers.

- [ ] **Step 1: Update `ModelsView.swift`**

In `TokenWatch/Views/ModelsView.swift`, change line 26 from:

```swift
                            Text(model.model)
```
to:

```swift
                            Text(Pricing.displayName(for: model.model))
```

- [ ] **Step 2: Update `MenuBarPopover.swift`**

In `TokenWatch/Views/MenuBarPopover.swift`, change line 159 from:

```swift
                            Text(model.model)
```
to:

```swift
                            Text(Pricing.displayName(for: model.model))
```

- [ ] **Step 3: Build and verify the app launches**

Run: `./script/build_and_run.sh --verify`
Expected: privacy audit passes, build succeeds, app launches and is killed after 1s.

- [ ] **Step 4: Run the full test suite**

Run:
```bash
xcodebuild -project TokenWatch.xcodeproj -scheme TokenWatch -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO \
  -destination 'platform=macOS,arch=arm64' test
```
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add TokenWatch/Views/ModelsView.swift TokenWatch/Views/MenuBarPopover.swift
git commit -m "Display human-friendly model names in Models list and menu-bar popover"
```