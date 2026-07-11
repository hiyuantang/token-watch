# Model pricing reference

Official per-million-token (MTok) API pricing used by Token Watch to estimate a
**local, illustrative cost** from observed transcript metadata. Token Watch makes
no network requests and never reads account, billing, or quota data — these rates
are a static, hand-maintained catalog. **They are not an invoice.**

All prices are in **USD per 1,000,000 tokens (MTok)** unless noted.

## How to read this file

Each model entry lists the rates that map directly onto the token fields Token
Watch aggregates:

| Field            | Meaning                                             | Token Watch field        |
| ---------------- | --------------------------------------------------- | ------------------------ |
| Input            | Standard (cache-miss) input price                   | `usage.input`            |
| Cached input     | Cache-read / cache-hit input price                  | `usage.cacheRead`        |
| Cache write 5m  | 5m cache-write price (Claude only; = input otherwise)| `usage.cacheWrite5m`    |
| Cache write 1h  | 1h cache-write price (Claude only; = input otherwise)| `usage.cacheWrite1h`     |
| Output           | Standard output price (incl. reasoning where billed)| `usage.output` (+ `reasoningOutput` for Codex-style models that split it out) |

For **display**, Token Watch merges `input` + `cacheWrite` into a single
"Input" figure (`TokenUsage.displayInput`) because cache write is input-side
spend — it's the same tokens, just marked for caching at a write premium. The
pricing logic still charges each bucket at its own rate.

Claude publishes a 5m cache-write rate of 1.25× base input and a 1h rate of 2×
input. Claude Code transcripts report the TTL split as
`cache_creation.ephemeral_1h_input_tokens` and `ephemeral_5m_input_tokens`, so
Token Watch charges each portion at its actual rate. Other providers do not
publish a distinct write rate, so their `cacheWrite` defaults to the base input
rate.

## Update protocol (read before editing)

1. **Add a new model**: append a row to the relevant provider section. Use the
   provider's official pricing page as the source. Record the date in the
   `Last verified` line at the top of that provider section.
2. **Change a price**: update the row, bump the section's `Last verified` date,
   and update the matching entry in `TokenWatch/Support/Pricing.swift` (the
   Swift catalog is the source of truth at runtime; this doc is the human
   reference). Keep the two in sync.
3. **Retire a model**: leave the row (historical estimates should still
   resolve) but mark it `[deprecated]` and move it below the current models.
4. **Exchange-rate-sensitive providers** (DeepSeek, MiniMax, Kimi, GLM): prefer
   the provider's **USD international list price** when one exists. If only CNY
   is published, convert at the rate noted in the section header and mark the
   row `≈` (approximate). Re-check these quarterly.
5. **Ambiguity**: when a provider publishes both "peak" and "regular" tiers
   (DeepSeek) or "standard" and "highspeed/priority" tiers (MiniMax), record the
   **regular / standard** tier only. Peak pricing is workload-dependent and not
   representable from local transcript metadata.

---

## Anthropic — Claude

Source: <https://platform.claude.com/docs/en/about-claude/pricing>
Last verified: 2026-07-11

Claude uses a single global price. Cache read = 0.1× input. Cache write 5m =
1.25× input; cache write 1h = 2× input. Token Watch uses the **cache-read** (hit)
price for `cacheRead` tokens, the **5m cache-write** price for the 5m portion of
`cacheWrite`, and the **1h cache-write** price for the 1h portion. Claude Code
transcripts report the TTL split as `cache_creation.ephemeral_1h_input_tokens` and
`ephemeral_5m_input_tokens`; other providers don't, so their entire `cacheWrite`
is charged at the 5m rate (which defaults to base input for non-Claude models).

| Model                       | Input / MTok | Cached input / MTok | Cache write 5m / MTok | Cache write 1h / MTok | Output / MTok |
| --------------------------- | -----------: | ------------------: | --------------------: | --------------------: | ------------: |
| Claude Opus 4.8             | $5.00        | $0.50               | $6.25                 | $10.00                | $25.00        |
| Claude Opus 4.7             | $5.00        | $0.50               | $6.25                 | $10.00                | $25.00        |
| Claude Opus 4.6             | $5.00        | $0.50               | $6.25                 | $10.00                | $25.00        |
| Claude Opus 4.5             | $5.00        | $0.50               | $6.25                 | $10.00                | $25.00        |
| Claude Opus 4.1 [deprecated]| $15.00       | $1.50               | $18.75                | $30.00                | $75.00        |
| Claude Sonnet 5 (intro, through 2026-08-31) | $2.00 | $0.20       | $2.50                 | $4.00                 | $10.00        |
| Claude Sonnet 5 (from 2026-09-01)           | $3.00 | $0.30       | $3.75                 | $6.00                 | $15.00        |
| Claude Sonnet 4.6           | $3.00        | $0.30               | $3.75                 | $6.00                 | $15.00        |
| Claude Sonnet 4.5           | $3.00        | $0.30               | $3.75                 | $6.00                 | $15.00        |
| Claude Haiku 4.5            | $1.00        | $0.10               | $1.25                 | $2.00                 | $5.00         |

Notes:
- Opus 4.7+ and Sonnet 5 use a newer tokenizer (~30% more tokens for the same
  text). The per-token price is as listed; the effective per-word cost shifts
  accordingly. Token Watch counts raw tokens, so this needs no adjustment here.
- Fast Mode, Batch API (50% off), Data Residency (1.1× US-only), and Managed
  Agents runtime are **not modeled** — none are identifiable from local
  transcript metadata.

---

## OpenAI — GPT-5 series

Source: <https://platform.openai.com/docs/pricing> (and Azure OpenAI mirror)
Last verified: 2026-07-09

OpenAI publishes a cached-input price = 0.1× input for the GPT-5 family.
Reasoning output is billed at the output rate (Token Watch folds
`reasoningOutput` into the output cost for Codex records that split it out).

| Model           | Input / MTok | Cached input / MTok | Output / MTok |
| --------------- | -----------: | ------------------: | ------------: |
| GPT-5.2 Pro     | $21.00       | $2.10               | $168.00       |
| GPT-5.2         | $1.75        | $0.175              | $14.00        |
| GPT-5.1         | $1.75        | $0.175              | $14.00        |
| GPT-5 Codex     | $1.25        | $0.125              | $10.00        |
| GPT-5           | $1.25        | $0.125              | $10.00        |
| GPT-5 Pro       | $15.00       | $1.50               | $120.00       |
| GPT-5 mini      | $0.25        | $0.025              | $2.00         |
| GPT-5 nano      | $0.05        | $0.005              | $0.40         |

Notes:
- "GPT-5 Codex" is the Codex-targeted variant; Codex transcripts may log it as
  `gpt-5-codex` or similar. The base `gpt-5` and `gpt-5-codex` rates are
  identical per OpenAI's page.
- Batch API (50% off) and Priority Processing are **not modeled**.

---

## Z.ai — GLM-5 series (and recent GLM-4.x)

Source: <https://docs.z.ai/guides/overview/pricing>
Last verified: 2026-07-09

Z.ai publishes prices in USD directly. Cached input ≈ 0.18× input. Several Flash
models are free on the API; those rows are included for completeness but resolve
to $0.

| Model             | Input / MTok | Cached input / MTok | Output / MTok |
| ----------------- | -----------: | ------------------: | ------------: |
| GLM-5.2           | $1.40        | $0.26               | $4.40         |
| GLM-5.1           | $1.40        | $0.26               | $4.40         |
| GLM-5             | $1.00        | $0.20               | $3.20         |
| GLM-5-Turbo       | $1.20        | $0.24               | $4.00         |
| GLM-4.7           | $0.60        | $0.11               | $2.20         |
| GLM-4.6           | $0.60        | $0.11               | $2.20         |
| GLM-4.5           | $0.60        | $0.11               | $2.20         |
| GLM-4.5-Air       | $0.20        | $0.03               | $1.10         |
| GLM-4.7-FlashX    | $0.07        | $0.01               | $0.40         |
| GLM-4.7-Flash     | $0.00        | $0.00               | $0.00         |
| GLM-4.5-Flash     | $0.00        | $0.00               | $0.00         |

Notes:
- Vision and audio models (GLM-5V-Turbo, GLM-4.6V, GLM-OCR, CogVideoX, etc.)
  are **not modeled** — Token Watch tracks text transcripts only.
- "GLM-5 series" per the user's request is covered by GLM-5, GLM-5.1, GLM-5.2,
  GLM-5-Turbo. GLM-4.5/4.6/4.7 are included because they remain the active
  fallback models many Coding Plan sessions log against.

---

## Moonshot AI — Kimi

Source: <https://platform.moonshot.ai/docs/pricing> (and OpenRouter/Bedrock mirrors)
Last verified: 2026-07-09

Moonshot prices are in USD on the international endpoint. Cache-read is roughly
0.25–0.30× input. Kimi K2 family is open-weight; hosted API price below.

| Model               | Input / MTok | Cached input / MTok | Output / MTok |
| ------------------- | -----------: | ------------------: | ------------: |
| Kimi K2.7 Code      | $0.95        | $0.19               | $4.00         |
| Kimi K2.6           | $0.95        | $0.19               | $4.00         |
| Kimi K2.5           | $0.60        | $0.15               | $3.00         |
| Kimi K2 Thinking    | $0.60        | $0.15               | $2.50         |
| Kimi K2 Thinking Turbo | $1.15     | $0.29               | $8.00         |
| Kimi K2             | $0.60        | $0.15               | $2.50         |

Notes:
- Older `moonshot-v1-8k/32k/128k` context-tiered pricing is **not modeled**;
  those models are legacy and rarely appear in current coding transcripts.
- Cache pricing for Kimi is published as a flat per-MTok read rate; the table
  uses the documented K2 family read rate.

---

## MiniMax

Source: <https://platform.minimax.io/docs/guides/pricing-paygo>
Last verified: 2026-07-09

MiniMax publishes USD directly. "Standard" tier shown; `highspeed`/`priority`
(1.5–2×) tiers are **not modeled**. M3's listed price is a permanent 50%-off
promotional rate; we record the promotional price the API actually charges.

| Model             | Input / MTok | Cached input / MTok | Output / MTok |
| ----------------- | -----------: | ------------------: | ------------: |
| MiniMax-M3 (≤512k)| $0.30        | $0.06               | $1.20         |
| MiniMax-M2.7      | $0.30        | $0.06               | $1.20         |
| MiniMax-M2.5      | $0.30        | $0.03               | $1.20         |
| MiniMax-M2.1      | $0.30        | $0.03               | $1.20         |
| MiniMax-M2        | $0.30        | $0.03               | $1.20         |

Notes:
- `>512k` long-context tier (2× price) for M3 is **not modeled** — Token Watch
  cannot reliably determine input-size tier from transcript metadata.
- Speech, video, music, and image generation APIs are out of scope.

---

## DeepSeek — V4 series (and V3.2 fallback)

Source: <https://api-docs.deepseek.com/quick_start/pricing>
Last verified: 2026-07-09
Reference exchange rate: 1 USD = 6.80 CNY (re-check quarterly)

DeepSeek publishes **regular (off-peak)** USD list prices below. Peak-tier
(2× regular) is **not modeled**. Cache-hit = 1/50 to 1/100 of input depending on
tier; the documented USD rates are used directly.

| Model                 | Input / MTok | Cached input / MTok | Output / MTok |
| --------------------- | -----------: | ------------------: | ------------: |
| DeepSeek-V4-Pro       | $0.435       | $0.003625           | $0.87         |
| DeepSeek-V4-Flash     | $0.14        | $0.0028             | $0.28         |
| DeepSeek-V3.2-Exp     | $0.28        | $0.028              | $0.42         |
| DeepSeek-V3.2-Speciale| $0.27        | $0.027              | $0.40         |

Notes:
- V4-Pro has a promotional international flat rate of $0.435/$0.87; the
  undiscounted rate ($1.74/$3.48) is **not modeled** — the promotional rate is
  what the API currently charges.
- `deepseek-chat` and `deepseek-reasoner` are deprecated aliases that now route
  to V4-Flash; Token Watch maps them to V4-Flash pricing in `Pricing.swift`.
- R1 and earlier distill models are out of scope for the "V4 series" request.

---

## Estimation formula

For each `UsageEvent` with a known model, Token Watch computes:

```
cost_usd = ( input       * inputPrice        / 1_000_000 )
         + ( cacheRead   * cachedInputPrice  / 1_000_000 )
         + ( cacheWrite5m * cacheWrite5mPrice / 1_000_000 )   // 1.25× input for Claude; = input otherwise
         + ( cacheWrite1h * cacheWrite1hPrice / 1_000_000 )   // 2× input for Claude; = input otherwise
         + ( output      * outputPrice       / 1_000_000 )
         + ( reasoningOutput * outputPrice   / 1_000_000 )   // where separately logged
```

Unknown models (no catalog match) contribute **$0** to the estimate and the
snapshot reports an `unpricedModels` count so the UI can show "N models
unpriced" rather than silently understating cost.

The estimate is computed inside `UsageAggregator.snapshot` alongside the
existing token totals — it reuses the **same single pass** over the selected
events, so there is no second aggregation loop and no extra file I/O. This
matches Token Watch's existing performance model: full scan at launch, then
incremental per-provider refresh on file-watch, with the snapshot derived on
demand from in-memory events.

## Disclaimer

These rates are a convenience estimate from public pricing pages. Actual bills
depend on tier, region, batch usage, discounts, prompt-caching behavior, and
provider-side rounding. Token Watch is not affiliated with any provider.

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

Some model strings are routing labels, not billable models. These have a
catalog entry with a zero rate so their display name resolves and exact-match
is honored, but they are marked `notBillable` — Token Watch shows "-" for them
in the UI (rather than a misleading "$0") and does not count them as unpriced
(they are known labels, not a gap in the catalog).

| Model | Rate | UI |
|---|---|---|
| `codex-auto-review` | $0 in / $0 out / $0 cache | "-" (not billable) |
