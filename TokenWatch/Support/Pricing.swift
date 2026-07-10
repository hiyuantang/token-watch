import Foundation

/// Static, hand-maintained catalog of official per-million-token API prices.
///
/// `Pricing` maps a model identifier (as it appears in local Claude Code, Codex,
/// or OpenCode transcripts) to its input, cached-input, and output rates in USD
/// per 1,000,000 tokens. Token Watch uses this catalog to produce an
/// **illustrative local cost estimate** from observed transcript metadata. It
/// makes no network requests and never reads account, billing, or quota data —
/// these rates are a convenience estimate, not an invoice.
///
/// See `docs/pricing.md` for the human-readable reference, sources, and the
/// update protocol. Keep this file and that document in sync.
struct Pricing {
    /// Per-million-token rates for one model variant.
    struct Rate: Sendable, Hashable {
        let inputPerMTok: Double
        let cachedInputPerMTok: Double
        let outputPerMTok: Double

        init(inputPerMTok: Double, cachedInputPerMTok: Double, outputPerMTok: Double) {
            self.inputPerMTok = max(inputPerMTok, 0)
            self.cachedInputPerMTok = max(cachedInputPerMTok, 0)
            self.outputPerMTok = max(outputPerMTok, 0)
        }
    }

    /// A catalog entry: one or more model identifiers that share a rate.
    /// Identifiers are matched case-insensitively and as substrings against the
    /// model string recorded in a transcript, so `claude-opus-4-8`,
    /// `claude-opus-4-8-20260101`, and `anthropic/claude-opus-4-8` all resolve.
    private struct Entry: Sendable {
        let matchers: [String]
        let rate: Rate
    }

    /// Cost attributed to one event whose model has no catalog match.
    static let unknown = Rate(inputPerMTok: 0, cachedInputPerMTok: 0, outputPerMTok: 0)

    private static let entries: [Entry] = {
        var list: [Entry] = []

        // Anthropic — Claude
        // Source: https://docs.anthropic.com/en/docs/about-claude/pricing (2026-07-09)
        // Cache read = 0.1× input. Token Watch charges cache writes at the base
        // input rate (no write premium modeled).
        list.append(.init(matchers: ["claude-opus-4-8", "claude-opus-4.8", "opus-4-8"], rate: .init(inputPerMTok: 5.00, cachedInputPerMTok: 0.50, outputPerMTok: 25.00)))
        list.append(.init(matchers: ["claude-opus-4-7", "claude-opus-4.7", "opus-4-7"], rate: .init(inputPerMTok: 5.00, cachedInputPerMTok: 0.50, outputPerMTok: 25.00)))
        list.append(.init(matchers: ["claude-opus-4-6", "claude-opus-4.6", "opus-4-6"], rate: .init(inputPerMTok: 5.00, cachedInputPerMTok: 0.50, outputPerMTok: 25.00)))
        list.append(.init(matchers: ["claude-opus-4-5", "claude-opus-4.5", "opus-4-5"], rate: .init(inputPerMTok: 5.00, cachedInputPerMTok: 0.50, outputPerMTok: 25.00)))
        list.append(.init(matchers: ["claude-opus-4-1", "claude-opus-4.1", "opus-4-1"], rate: .init(inputPerMTok: 15.00, cachedInputPerMTok: 1.50, outputPerMTok: 75.00)))
        list.append(.init(matchers: ["claude-opus-4", "opus-4"], rate: .init(inputPerMTok: 15.00, cachedInputPerMTok: 1.50, outputPerMTok: 75.00)))
        list.append(.init(matchers: ["claude-fable-5", "fable-5"], rate: .init(inputPerMTok: 10.00, cachedInputPerMTok: 1.00, outputPerMTok: 50.00)))
        list.append(.init(matchers: ["claude-mythos-5", "mythos-5"], rate: .init(inputPerMTok: 10.00, cachedInputPerMTok: 1.00, outputPerMTok: 50.00)))
        // Sonnet 5 introductory ($2/$10) is in effect through 2026-08-31; from
        // 2026-09-01 it becomes $3/$15. Token Watch uses the introductory rate
        // while it is active; update on the cutover date.
        list.append(.init(matchers: ["claude-sonnet-5", "sonnet-5"], rate: .init(inputPerMTok: 2.00, cachedInputPerMTok: 0.20, outputPerMTok: 10.00)))
        list.append(.init(matchers: ["claude-sonnet-4-6", "claude-sonnet-4.6", "sonnet-4-6"], rate: .init(inputPerMTok: 3.00, cachedInputPerMTok: 0.30, outputPerMTok: 15.00)))
        list.append(.init(matchers: ["claude-sonnet-4-5", "claude-sonnet-4.5", "sonnet-4-5"], rate: .init(inputPerMTok: 3.00, cachedInputPerMTok: 0.30, outputPerMTok: 15.00)))
        list.append(.init(matchers: ["claude-sonnet-4"], rate: .init(inputPerMTok: 3.00, cachedInputPerMTok: 0.30, outputPerMTok: 15.00)))
        list.append(.init(matchers: ["claude-haiku-4-5", "claude-haiku-4.5", "haiku-4-5"], rate: .init(inputPerMTok: 1.00, cachedInputPerMTok: 0.10, outputPerMTok: 5.00)))
        list.append(.init(matchers: ["claude-haiku-3-5", "claude-haiku-3.5", "haiku-3-5"], rate: .init(inputPerMTok: 0.80, cachedInputPerMTok: 0.08, outputPerMTok: 4.00)))

        // OpenAI — GPT-5 series
        // Source: https://platform.openai.com/docs/pricing (2026-07-09)
        // Cached input = 0.1× input. Reasoning output billed at output rate.
        list.append(.init(matchers: ["gpt-5.6-sol", "gpt-5-6-sol"], rate: .init(inputPerMTok: 5.00, cachedInputPerMTok: 0.50, outputPerMTok: 30.00)))
        list.append(.init(matchers: ["gpt-5.6-terra", "gpt-5-6-terra"], rate: .init(inputPerMTok: 2.50, cachedInputPerMTok: 0.25, outputPerMTok: 15.00)))
        list.append(.init(matchers: ["gpt-5.6-luna", "gpt-5-6-luna"], rate: .init(inputPerMTok: 1.00, cachedInputPerMTok: 0.10, outputPerMTok: 6.00)))
        list.append(.init(matchers: ["gpt-5.5-pro", "gpt-5-5-pro"], rate: .init(inputPerMTok: 30.00, cachedInputPerMTok: 3.00, outputPerMTok: 180.00)))
        list.append(.init(matchers: ["gpt-5.5"], rate: .init(inputPerMTok: 5.00, cachedInputPerMTok: 0.50, outputPerMTok: 30.00)))
        list.append(.init(matchers: ["gpt-5.4-pro", "gpt-5-4-pro"], rate: .init(inputPerMTok: 30.00, cachedInputPerMTok: 3.00, outputPerMTok: 180.00)))
        list.append(.init(matchers: ["gpt-5.4"], rate: .init(inputPerMTok: 2.50, cachedInputPerMTok: 0.25, outputPerMTok: 15.00)))
        list.append(.init(matchers: ["gpt-5.2-pro", "gpt-5-2-pro"], rate: .init(inputPerMTok: 21.00, cachedInputPerMTok: 2.10, outputPerMTok: 168.00)))
        list.append(.init(matchers: ["gpt-5.2-codex", "gpt-5-2-codex"], rate: .init(inputPerMTok: 1.75, cachedInputPerMTok: 0.175, outputPerMTok: 14.00)))
        list.append(.init(matchers: ["gpt-5.2"], rate: .init(inputPerMTok: 1.75, cachedInputPerMTok: 0.175, outputPerMTok: 14.00)))
        list.append(.init(matchers: ["gpt-5.1-codex", "gpt-5-1-codex"], rate: .init(inputPerMTok: 1.25, cachedInputPerMTok: 0.125, outputPerMTok: 10.00)))
        list.append(.init(matchers: ["gpt-5.1"], rate: .init(inputPerMTok: 1.75, cachedInputPerMTok: 0.175, outputPerMTok: 14.00)))
        list.append(.init(matchers: ["gpt-5-pro"], rate: .init(inputPerMTok: 15.00, cachedInputPerMTok: 1.50, outputPerMTok: 120.00)))
        list.append(.init(matchers: ["gpt-5-codex"], rate: .init(inputPerMTok: 1.25, cachedInputPerMTok: 0.125, outputPerMTok: 10.00)))
        list.append(.init(matchers: ["gpt-5-mini", "gpt-5-mini"], rate: .init(inputPerMTok: 0.25, cachedInputPerMTok: 0.025, outputPerMTok: 2.00)))
        list.append(.init(matchers: ["gpt-5-nano"], rate: .init(inputPerMTok: 0.05, cachedInputPerMTok: 0.005, outputPerMTok: 0.40)))
        // Bare "gpt-5" must be matched last among the GPT-5 family so it does not
        // shadow the more specific variants above. It is placed here on purpose.
        list.append(.init(matchers: ["gpt-5"], rate: .init(inputPerMTok: 1.25, cachedInputPerMTok: 0.125, outputPerMTok: 10.00)))

        // Z.ai — GLM-5 series (and active GLM-4.x fallbacks)
        // Source: https://docs.z.ai/guides/overview/pricing (2026-07-09)
        list.append(.init(matchers: ["glm-5.2", "glm-5-2"], rate: .init(inputPerMTok: 1.40, cachedInputPerMTok: 0.26, outputPerMTok: 4.40)))
        list.append(.init(matchers: ["glm-5.1", "glm-5-1"], rate: .init(inputPerMTok: 1.40, cachedInputPerMTok: 0.26, outputPerMTok: 4.40)))
        list.append(.init(matchers: ["glm-5-turbo", "glm-5-turbo"], rate: .init(inputPerMTok: 1.20, cachedInputPerMTok: 0.24, outputPerMTok: 4.00)))
        list.append(.init(matchers: ["glm-5"], rate: .init(inputPerMTok: 1.00, cachedInputPerMTok: 0.20, outputPerMTok: 3.20)))
        list.append(.init(matchers: ["glm-4.7-flashx", "glm-4-7-flashx"], rate: .init(inputPerMTok: 0.07, cachedInputPerMTok: 0.01, outputPerMTok: 0.40)))
        list.append(.init(matchers: ["glm-4.7-flash", "glm-4-7-flash", "glm-4.5-flash", "glm-4-5-flash"], rate: .init(inputPerMTok: 0, cachedInputPerMTok: 0, outputPerMTok: 0)))
        list.append(.init(matchers: ["glm-4.7", "glm-4-7"], rate: .init(inputPerMTok: 0.60, cachedInputPerMTok: 0.11, outputPerMTok: 2.20)))
        list.append(.init(matchers: ["glm-4.6", "glm-4-6"], rate: .init(inputPerMTok: 0.60, cachedInputPerMTok: 0.11, outputPerMTok: 2.20)))
        list.append(.init(matchers: ["glm-4.5-air", "glm-4-5-air"], rate: .init(inputPerMTok: 0.20, cachedInputPerMTok: 0.03, outputPerMTok: 1.10)))
        list.append(.init(matchers: ["glm-4.5", "glm-4-5"], rate: .init(inputPerMTok: 0.60, cachedInputPerMTok: 0.11, outputPerMTok: 2.20)))

        // Moonshot AI — Kimi
        // Source: https://platform.moonshot.ai/docs/pricing (2026-07-09)
        list.append(.init(matchers: ["kimi-k2.7-code", "kimi-k2-7-code", "kimi-k2.7"], rate: .init(inputPerMTok: 0.95, cachedInputPerMTok: 0.19, outputPerMTok: 4.00)))
        list.append(.init(matchers: ["kimi-k2.6", "kimi-k2-6"], rate: .init(inputPerMTok: 0.95, cachedInputPerMTok: 0.19, outputPerMTok: 4.00)))
        list.append(.init(matchers: ["kimi-k2.5", "kimi-k2-5"], rate: .init(inputPerMTok: 0.60, cachedInputPerMTok: 0.15, outputPerMTok: 3.00)))
        list.append(.init(matchers: ["kimi-k2-thinking-turbo", "kimi-k2-thinking-turbo"], rate: .init(inputPerMTok: 1.15, cachedInputPerMTok: 0.29, outputPerMTok: 8.00)))
        list.append(.init(matchers: ["kimi-k2-thinking", "kimi-thinking"], rate: .init(inputPerMTok: 0.60, cachedInputPerMTok: 0.15, outputPerMTok: 2.50)))
        list.append(.init(matchers: ["kimi-k2"], rate: .init(inputPerMTok: 0.60, cachedInputPerMTok: 0.15, outputPerMTok: 2.50)))

        // MiniMax
        // Source: https://platform.minimax.io/docs/guides/pricing-paygo (2026-07-09)
        // Standard tier only; highspeed/priority (1.5–2×) not modeled.
        list.append(.init(matchers: ["minimax-m3", "minimax-m-3"], rate: .init(inputPerMTok: 0.30, cachedInputPerMTok: 0.06, outputPerMTok: 1.20)))
        list.append(.init(matchers: ["minimax-m2.7", "minimax-m-2-7"], rate: .init(inputPerMTok: 0.30, cachedInputPerMTok: 0.06, outputPerMTok: 1.20)))
        list.append(.init(matchers: ["minimax-m2.5", "minimax-m-2-5"], rate: .init(inputPerMTok: 0.30, cachedInputPerMTok: 0.03, outputPerMTok: 1.20)))
        list.append(.init(matchers: ["minimax-m2.1", "minimax-m-2-1"], rate: .init(inputPerMTok: 0.30, cachedInputPerMTok: 0.03, outputPerMTok: 1.20)))
        list.append(.init(matchers: ["minimax-m2", "minimax-m-2"], rate: .init(inputPerMTok: 0.30, cachedInputPerMTok: 0.03, outputPerMTok: 1.20)))

        // DeepSeek — V4 series (and V3.2 fallback)
        // Source: https://api-docs.deepseek.com/quick_start/pricing (2026-07-09)
        // Regular (off-peak) USD prices; peak tier (2×) not modeled.
        // deepseek-chat / deepseek-reasoner are deprecated aliases routing to
        // V4-Flash; map them here so legacy transcripts still resolve.
        list.append(.init(matchers: ["deepseek-v4-pro", "deepseek-v4-pro"], rate: .init(inputPerMTok: 0.435, cachedInputPerMTok: 0.003625, outputPerMTok: 0.87)))
        list.append(.init(matchers: ["deepseek-v4-flash", "deepseek-chat", "deepseek-reasoner"], rate: .init(inputPerMTok: 0.14, cachedInputPerMTok: 0.0028, outputPerMTok: 0.28)))
        list.append(.init(matchers: ["deepseek-v3.2-speciale", "deepseek-v3-2-speciale"], rate: .init(inputPerMTok: 0.27, cachedInputPerMTok: 0.027, outputPerMTok: 0.40)))
        list.append(.init(matchers: ["deepseek-v3.2", "deepseek-v3-2"], rate: .init(inputPerMTok: 0.28, cachedInputPerMTok: 0.028, outputPerMTok: 0.42)))

        // Xiaomi — MiMo (appears in Codex transcripts as mimo-v2.5-pro etc.)
        // Source: Xiaomi / AtlasCloud hosted pricing (2026-07-09)
        list.append(.init(matchers: ["mimo-v2.5-pro", "mimo-v2-5-pro"], rate: .init(inputPerMTok: 0.435, cachedInputPerMTok: 0.0036, outputPerMTok: 0.87)))
        list.append(.init(matchers: ["mimo-v2-pro", "mimo-v2-pro"], rate: .init(inputPerMTok: 0.435, cachedInputPerMTok: 0.0036, outputPerMTok: 0.87)))

        return list
    }()

    /// Returns the rate for a model identifier, or `nil` if no catalog entry
    /// matches. Matching is case-insensitive substring: the first entry whose
    /// any matcher is contained in the lowercased model string wins, so more
    /// specific matchers must be registered before looser ones (e.g. `gpt-5.2`
    /// before `gpt-5`).
    static func rate(for model: String) -> Rate? {
        let needle = model.lowercased()
        for entry in entries {
            if entry.matchers.contains(where: { needle.contains($0) }) {
                return entry.rate
            }
        }
        return nil
    }

    /// USD cost for a single token-usage record at the given rate. Charges
    /// cache writes at the base input rate (no write premium modeled) and folds
    /// reasoning output into the output cost where a provider splits it out.
    static func cost(of usage: TokenUsage, at rate: Rate) -> Double {
        let mtok = 1_000_000.0
        let inputCost = Double(usage.input) * rate.inputPerMTok / mtok
        let cacheReadCost = Double(usage.cacheRead) * rate.cachedInputPerMTok / mtok
        let cacheWriteCost = Double(usage.cacheWrite) * rate.inputPerMTok / mtok
        let outputCost = Double(usage.output) * rate.outputPerMTok / mtok
        let reasoningCost = Double(usage.reasoningOutput) * rate.outputPerMTok / mtok
        return inputCost + cacheReadCost + cacheWriteCost + outputCost + reasoningCost
    }
}

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