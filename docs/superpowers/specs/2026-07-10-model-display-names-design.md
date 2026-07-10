# Model display names

**Date:** 2026-07-10
**Status:** Approved (pending spec review)
**Scope:** `TokenWatch/Support/Pricing.swift`, `TokenWatch/Views/ModelsView.swift`, `TokenWatch/Views/MenuBarPopover.swift`, `TokenWatchTests/PricingTests.swift`

## Problem

The Models list and the menu-bar popover display the raw model identifier from the provider transcript (`model.model` on `ModelSummary`). These strings are machine identifiers — `claude-opus-4-8`, `gpt-5.6-sol`, `deepseek-v4-pro`, `glm-5.2` — not names a user reads quickly. There is no mapping to a human-friendly display name today.

## Non-goals

- **No second catalog.** Display names live in the existing `Pricing.Entry` list, not a parallel `ModelNaming` catalog. The pricing matchers already uniquely identify every model; coupling the display name there keeps naming and pricing in sync by construction.
- **No data-model change to `ModelSummary` / `UsageEvent`.** The raw `model: String` stays as the grouping/dedup key; only the *display* layer changes.
- **No network.** Names are static, hand-maintained, like the pricing catalog.

## Design

### A. `displayName` on `Pricing.Entry`

The existing `Entry` struct (`TokenWatch/Support/Pricing.swift:35`) gains one field:

```swift
private struct Entry: Sendable {
    let matchers: [String]
    let rate: Rate
    let displayName: String      // NEW
    let exact: Bool

    init(matchers: [String], rate: Rate, displayName: String, exact: Bool = false) {
        self.matchers = matchers
        self.rate = rate
        self.displayName = displayName
        self.exact = exact
    }
}
```

Every existing `list.append(.init(...))` in the `entries` builder gets a `displayName:` argument. The name is the human-friendly form, using spaces (not hyphens) as separators:

| Match for | displayName |
|---|---|
| `claude-opus-4-8` / `claude-opus-4.8` / `opus-4-8` | `Claude Opus 4.8` |
| `claude-opus-4-7` / `claude-opus-4.7` / `opus-4-7` | `Claude Opus 4.7` |
| `claude-opus-4-6` / `claude-opus-4.6` / `opus-4-6` | `Claude Opus 4.6` |
| `claude-opus-4-5` / `claude-opus-4.5` / `opus-4-5` | `Claude Opus 4.5` |
| `claude-opus-4-1` / `claude-opus-4.1` / `opus-4-1` | `Claude Opus 4.1` |
| `claude-opus-4` / `opus-4` | `Claude Opus 4` |
| `claude-sonnet-5` / `sonnet-5` | `Claude Sonnet 5` |
| `claude-sonnet-4-6` / `claude-sonnet-4.6` / `sonnet-4-6` | `Claude Sonnet 4.6` |
| `claude-sonnet-4-5` / `claude-sonnet-4.5` / `sonnet-4-5` | `Claude Sonnet 4.5` |
| `claude-sonnet-4` | `Claude Sonnet 4` |
| `claude-haiku-4-5` / `claude-haiku-4.5` / `haiku-4-5` | `Claude Haiku 4.5` |
| `claude-haiku-3-5` / `claude-haiku-3.5` / `haiku-3-5` | `Claude Haiku 3.5` |
| `claude-fable-5` / `fable-5` | `Claude Fable 5` |
| `claude-mythos-5` / `mythos-5` | `Claude Mythos 5` |
| `gpt-5.6-sol` / `gpt-5-6-sol` | `GPT 5.6 Sol` |
| `gpt-5.6-terra` / `gpt-5-6-terra` | `GPT 5.6 Terra` |
| `gpt-5.6-luna` / `gpt-5-6-luna` | `GPT 5.6 Luna` |
| `gpt-5.5-pro` / `gpt-5-5-pro` | `GPT 5.5 Pro` |
| `gpt-5.5` | `GPT 5.5` |
| `gpt-5.4-pro` / `gpt-5-4-pro` | `GPT 5.4 Pro` |
| `gpt-5.4` | `GPT 5.4` |
| `gpt-5.2-pro` / `gpt-5-2-pro` | `GPT 5.2 Pro` |
| `gpt-5.2-codex` / `gpt-5-2-codex` | `GPT 5.2 Codex` |
| `gpt-5.2` | `GPT 5.2` |
| `gpt-5.1-codex` / `gpt-5-1-codex` | `GPT 5.1 Codex` |
| `gpt-5.1` | `GPT 5.1` |
| `gpt-5-pro` | `GPT 5 Pro` |
| `gpt-5-codex` | `GPT 5 Codex` |
| `gpt-5-mini` | `GPT 5 Mini` |
| `gpt-5-nano` | `GPT 5 Nano` |
| `gpt-5` | `GPT 5` |
| `glm-5.2` / `glm-5-2` | `GLM 5.2` |
| `glm-5.1` / `glm-5-1` | `GLM 5.1` |
| `glm-5-turbo` | `GLM 5 Turbo` |
| `glm-5` | `GLM 5` |
| `glm-4.7-flashx` / `glm-4-7-flashx` | `GLM 4.7 FlashX` |
| `glm-4.7-flash` / `glm-4-7-flash` / `glm-4.5-flash` / `glm-4-5-flash` | `GLM 4.7 Flash` |
| `glm-4.7` / `glm-4-7` | `GLM 4.7` |
| `glm-4.6` / `glm-4-6` | `GLM 4.6` |
| `glm-4.5-air` / `glm-4-5-air` | `GLM 4.5 Air` |
| `glm-4.5` / `glm-4-5` | `GLM 4.5` |
| `kimi-k2.7-code` / `kimi-k2-7-code` / `kimi-k2.7` | `Kimi K2.7 Code` |
| `kimi-k2.6` / `kimi-k2-6` | `Kimi K2.6` |
| `kimi-k2.5` / `kimi-k2-5` | `Kimi K2.5` |
| `kimi-k2-thinking-turbo` | `Kimi K2 Thinking Turbo` |
| `kimi-k2-thinking` / `kimi-thinking` | `Kimi K2 Thinking` |
| `kimi-k2` | `Kimi K2` |
| `minimax-m3` / `minimax-m-3` | `MiniMax M3` |
| `minimax-m2.7` / `minimax-m-2-7` | `MiniMax M2.7` |
| `minimax-m2.5` / `minimax-m-2-5` | `MiniMax M2.5` |
| `minimax-m2.1` / `minimax-m-2-1` | `MiniMax M2.1` |
| `minimax-m2` / `minimax-m-2` | `MiniMax M2` |
| `deepseek-v4-pro` | `DeepSeek V4 Pro` |
| `deepseek-v4-flash` / `deepseek-chat` / `deepseek-reasoner` | `DeepSeek V4 Flash` |
| `deepseek-v3.2-speciale` / `deepseek-v3-2-speciale` | `DeepSeek V3.2 Speciale` |
| `deepseek-v3.2` / `deepseek-v3-2` | `DeepSeek V3.2` |
| `mimo-v2.5-pro` / `mimo-v2-5-pro` | `MiMo V2.5 Pro` |
| `mimo-v2-pro` | `MiMo V2 Pro` |
| `codex-auto-review` (exact) | `Codex Auto Review` |

The `codex-auto-review` entry is an internal routing label priced at $0; its display name is `Codex Auto Review` so it reads cleanly in the list rather than as a hyphenated slug.

### B. `Pricing.displayName(for:)` lookup

A new static function, alongside the existing `Pricing.rate(for:)`:

```swift
static func displayName(for model: String) -> String {
    let needle = model.lowercased()
    for entry in entries where matches(entry, needle: needle) {
        return entry.displayName
    }
    return ModelNamePrettifier.prettify(model)
}
```

It reuses the same ordered `entries` walk and the existing `matches(_:needle:)` helper, so display-name matching is identical to pricing matching: case-insensitive substring by default, exact-only for `exact: true` entries, first matcher wins. Unknown models fall through to the prettifier.

### C. `ModelNamePrettifier` fallback

For models with no catalog match (unknown models, future models not yet listed):

```swift
enum ModelNamePrettifier {
    static func prettify(_ raw: String) -> String {
        raw.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}
```

Behavior:
- `some-new-model-xyz` → `Some New Model Xyz`
- `acme_llm_2.0` → `Acme Llm 2.0`
- `FutureModel` → `Futuremodel` (single token, first letter capitalized, rest lowercased)

Known models never hit this path — they have explicit `displayName`s in the catalog. The prettifier is a best-effort fallback so unknown models read as words rather than slugs. It lives in `Pricing.swift` alongside the catalog, since naming and pricing are maintained together.

### D. UI wiring

Two call sites change from the raw `model.model` to `Pricing.displayName(for: model.model)`:

- `TokenWatch/Views/ModelsView.swift:26` — the Models list in the dashboard
- `TokenWatch/Views/MenuBarPopover.swift:159` — top-5 models in the menu-bar popover

The raw `model.model` string remains on `ModelSummary` as the grouping/dedup key and the `id` component. No change to `ModelSummary`, `UsageEvent`, or the scanner/store layer — this is a display-only transformation.

### E. Testing

New tests in `TokenWatchTests/PricingTests.swift`:

1. **Known models return their catalog display name** — spot-check one per provider:
   - `claude-opus-4-8` → `Claude Opus 4.8`
   - `gpt-5.6-sol` → `GPT 5.6 Sol`
   - `glm-5.2` → `GLM 5.2`
   - `kimi-k2.7-code` → `Kimi K2.7 Code`
   - `deepseek-v4-pro` → `DeepSeek V4 Pro`
   - `minimax-m3` → `MiniMax M3`
2. **Unknown model returns prettified name** — `some-new-model-xyz` → `Some New Model Xyz`.
3. **Exact-match label resolves correctly** — `codex-auto-review` → `Codex Auto Review` (not matched as a substring of a longer model string).
4. **Matcher ordering** — `gpt-5.2` resolves to `GPT 5.2`, not `GPT 5` (the bare `gpt-5` entry is registered last, matching the existing pricing ordering).
5. **Underscore separator** — `acme_llm_2.0` → `Acme Llm 2.0`.

## Files touched

| File | Change |
|---|---|
| `TokenWatch/Support/Pricing.swift` | Add `displayName` to `Entry`; add `displayName(for:)` + `ModelNamePrettifier` |
| `TokenWatch/Views/ModelsView.swift` | `model.model` → `Pricing.displayName(for: model.model)` at line 26 |
| `TokenWatch/Views/MenuBarPopover.swift` | `model.model` → `Pricing.displayName(for: model.model)` at line 159 |
| `TokenWatchTests/PricingTests.swift` | New `displayName(for:)` + prettifier tests |

`docs/pricing.md` is not touched by this design — the display names are a UI concern, not a pricing-reference concern. The names live in `Pricing.swift` and are covered by the existing "keep Swift catalog and docs in sync" convention only for *rates*; display names have no docs twin.