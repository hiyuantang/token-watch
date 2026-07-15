import Foundation
import XCTest
@testable import TokenWatch

final class PricingTests: XCTestCase {
    func testClaudeOpusFamilyResolvesAcrossNamingStyles() {
        let r1 = Pricing.rate(for: "claude-opus-4-8")
        let r2 = Pricing.rate(for: "anthropic/claude-opus-4.8")
        let r3 = Pricing.rate(for: "claude-opus-4-8-20260101")
        XCTAssertNotNil(r1)
        XCTAssertEqual(r1?.inputPerMTok, 5.0)
        XCTAssertEqual(r1?.outputPerMTok, 25.0)
        XCTAssertEqual(r1?.cachedInputPerMTok, 0.5)
        XCTAssertEqual(r1, r2)
        XCTAssertEqual(r1, r3)
    }

    func testSonnet5IntroPricing() {
        let r = Pricing.rate(for: "claude-sonnet-5")
        XCTAssertEqual(r?.inputPerMTok, 2.0)
        XCTAssertEqual(r?.outputPerMTok, 10.0)
        XCTAssertEqual(r?.cachedInputPerMTok, 0.2)
    }

    func testGpt5SpecificVariantShadowsBareGpt5() {
        // Bare gpt-5 must not shadow gpt-5.2-pro / gpt-5.2-codex / gpt-5-mini
        XCTAssertEqual(Pricing.rate(for: "gpt-5.2-pro")?.inputPerMTok, 21.0)
        XCTAssertEqual(Pricing.rate(for: "gpt-5.2-codex")?.inputPerMTok, 1.75)
        XCTAssertEqual(Pricing.rate(for: "gpt-5-mini")?.inputPerMTok, 0.25)
        XCTAssertEqual(Pricing.rate(for: "gpt-5-nano")?.inputPerMTok, 0.05)
        XCTAssertEqual(Pricing.rate(for: "gpt-5")?.inputPerMTok, 1.25)
    }

    func testGpt56TiersResolve() {
        XCTAssertEqual(Pricing.rate(for: "gpt-5.6-sol")?.inputPerMTok, 5.0)
        XCTAssertEqual(Pricing.rate(for: "gpt-5.6-sol")?.outputPerMTok, 30.0)
        XCTAssertEqual(Pricing.rate(for: "gpt-5.6-terra")?.inputPerMTok, 2.5)
        XCTAssertEqual(Pricing.rate(for: "gpt-5.6-terra")?.outputPerMTok, 15.0)
        XCTAssertEqual(Pricing.rate(for: "gpt-5.6-luna")?.inputPerMTok, 1.0)
    }

    func testGlm5Series() {
        XCTAssertEqual(Pricing.rate(for: "glm-5.2")?.inputPerMTok, 1.40)
        XCTAssertEqual(Pricing.rate(for: "glm-5.1")?.inputPerMTok, 1.40)
        XCTAssertEqual(Pricing.rate(for: "glm-5")?.inputPerMTok, 1.00)
        XCTAssertEqual(Pricing.rate(for: "glm-5-turbo")?.inputPerMTok, 1.20)
    }

    func testGlm47And46ShareRate() {
        XCTAssertEqual(Pricing.rate(for: "glm-4.7")?.inputPerMTok, 0.60)
        XCTAssertEqual(Pricing.rate(for: "glm-4.6")?.inputPerMTok, 0.60)
        XCTAssertEqual(Pricing.rate(for: "glm-4.5")?.inputPerMTok, 0.60)
    }

    func testGlmFlashIsFree() {
        let r = Pricing.rate(for: "glm-4.7-flash")
        XCTAssertEqual(r?.inputPerMTok, 0)
        XCTAssertEqual(r?.outputPerMTok, 0)
    }

    func testKimiFamily() {
        XCTAssertEqual(Pricing.rate(for: "kimi-k2.7-code")?.inputPerMTok, 0.95)
        XCTAssertEqual(Pricing.rate(for: "kimi-k2.6")?.inputPerMTok, 0.95)
        XCTAssertEqual(Pricing.rate(for: "kimi-k2-thinking")?.inputPerMTok, 0.60)
        XCTAssertEqual(Pricing.rate(for: "kimi-k2-thinking-turbo")?.inputPerMTok, 1.15)
        XCTAssertEqual(Pricing.rate(for: "kimi-k2")?.inputPerMTok, 0.60)
    }

    func testMiniMaxFamily() {
        XCTAssertEqual(Pricing.rate(for: "minimax-m3")?.inputPerMTok, 0.30)
        XCTAssertEqual(Pricing.rate(for: "minimax-m2.7")?.inputPerMTok, 0.30)
        XCTAssertEqual(Pricing.rate(for: "minimax-m2")?.inputPerMTok, 0.30)
    }

    func testDeepSeekV4AndLegacyAliases() {
        XCTAssertEqual(Pricing.rate(for: "deepseek-v4-pro")?.inputPerMTok, 0.435)
        XCTAssertEqual(Pricing.rate(for: "deepseek-v4-pro")?.outputPerMTok, 0.87)
        XCTAssertEqual(Pricing.rate(for: "deepseek-v4-flash")?.inputPerMTok, 0.14)
        // Legacy aliases route to V4-Flash.
        XCTAssertEqual(Pricing.rate(for: "deepseek-chat")?.inputPerMTok, 0.14)
        XCTAssertEqual(Pricing.rate(for: "deepseek-reasoner")?.inputPerMTok, 0.14)
        XCTAssertEqual(Pricing.rate(for: "deepseek-v3.2")?.inputPerMTok, 0.28)
    }

    func testMiMoVariant() {
        XCTAssertEqual(Pricing.rate(for: "mimo-v2.5-pro")?.inputPerMTok, 0.435)
        XCTAssertEqual(Pricing.rate(for: "mimo-v2.5-pro")?.outputPerMTok, 0.87)
    }

    func testUnknownModelReturnsNil() {
        XCTAssertNil(Pricing.rate(for: "some-internal-model-v0"))
        XCTAssertNil(Pricing.rate(for: ""))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(Pricing.rate(for: "CLAUDE-OPUS-4-8")?.inputPerMTok, 5.0)
        XCTAssertEqual(Pricing.rate(for: "GPT-5.2-PRO")?.inputPerMTok, 21.0)
        XCTAssertEqual(Pricing.rate(for: "GLM-5.2")?.inputPerMTok, 1.40)
    }

    func testCostCalculationForClaudeOpus() {
        // 1M input + 1M cache read + 100K cache write (5m) + 0.5M output at Opus 4.8.
        // input: 1,000,000 * 5.00 / 1M = 5.00
        // cacheRead: 1,000,000 * 0.50 / 1M = 0.50
        // cacheWrite5m: 100,000 * 6.25 / 1M = 0.625 (1.25× input)
        // output: 500,000 * 25.00 / 1M = 12.50
        // total = 18.625
        let usage = TokenUsage(input: 1_000_000, output: 500_000, cacheRead: 1_000_000, cacheWrite: 100_000)
        let rate = Pricing.rate(for: "claude-opus-4-8")!
        let cost = Pricing.cost(of: usage, at: rate)
        XCTAssertEqual(cost, 18.625, accuracy: 0.0001)
    }

    func testClaudeCacheWriteTtlSplit() {
        // 100K cacheWrite split: 80K 1h (2× input) + 20K 5m (1.25× input).
        // Opus 4.8: input=$5, 1h=$10, 5m=$6.25 per MTok.
        // 1h: 80,000 * 10.00 / 1M = 0.80
        // 5m: 20,000 * 6.25 / 1M = 0.125
        // total cacheWrite cost = 0.925
        let usage = TokenUsage(input: 0, output: 0, cacheRead: 0, cacheWrite: 100_000, cacheWrite1h: 80_000)
        let rate = Pricing.rate(for: "claude-opus-4-8")!
        let cost = Pricing.cost(of: usage, at: rate)
        XCTAssertEqual(cost, 0.925, accuracy: 0.0001)
        // 5m portion is the remainder
        XCTAssertEqual(usage.cacheWrite5m, 20_000)
        XCTAssertEqual(usage.cacheWrite1h, 80_000)
    }

    func testClaudeCacheWriteRates() {
        let rate = Pricing.rate(for: "claude-opus-4-8")!
        XCTAssertEqual(rate.cacheWrite5mPerMTok, rate.inputPerMTok * 1.25, accuracy: 0.0001)
        XCTAssertEqual(rate.cacheWrite1hPerMTok, rate.inputPerMTok * 2.0, accuracy: 0.0001)
        XCTAssertEqual(rate.cacheWrite5mPerMTok, 6.25, accuracy: 0.0001)
        XCTAssertEqual(rate.cacheWrite1hPerMTok, 10.00, accuracy: 0.0001)

        let sonnet = Pricing.rate(for: "claude-sonnet-5")!
        XCTAssertEqual(sonnet.cacheWrite5mPerMTok, 2.50, accuracy: 0.0001)
        XCTAssertEqual(sonnet.cacheWrite1hPerMTok, 4.00, accuracy: 0.0001)

        let haiku = Pricing.rate(for: "claude-haiku-4-5")!
        XCTAssertEqual(haiku.cacheWrite5mPerMTok, 1.25, accuracy: 0.0001)
        XCTAssertEqual(haiku.cacheWrite1hPerMTok, 2.00, accuracy: 0.0001)
    }

    func testNonClaudeCacheWriteDefaultsToInputRate() {
        // Non-Claude providers do not publish a distinct write rate; both 5m
        // and 1h default to the base input rate.
        let gpt = Pricing.rate(for: "gpt-5")!
        XCTAssertEqual(gpt.cacheWrite5mPerMTok, gpt.inputPerMTok, accuracy: 0.0001)
        XCTAssertEqual(gpt.cacheWrite1hPerMTok, gpt.inputPerMTok, accuracy: 0.0001)

        let glm = Pricing.rate(for: "glm-5.2")!
        XCTAssertEqual(glm.cacheWrite5mPerMTok, glm.inputPerMTok, accuracy: 0.0001)

        let deepseek = Pricing.rate(for: "deepseek-v4-flash")!
        XCTAssertEqual(deepseek.cacheWrite5mPerMTok, deepseek.inputPerMTok, accuracy: 0.0001)
    }

    func testCostCalculationForDeepSeekFlash() {
        // 2M cache-read at $0.0028/MTok = $0.0056
        // 100K input at $0.14/MTok = $0.014
        // 50K output at $0.28/MTok = $0.014
        // total = $0.0336
        let usage = TokenUsage(input: 100_000, output: 50_000, cacheRead: 2_000_000, cacheWrite: 0)
        let rate = Pricing.rate(for: "deepseek-v4-flash")!
        let cost = Pricing.cost(of: usage, at: rate)
        XCTAssertEqual(cost, 0.0336, accuracy: 0.0001)
    }

    func testReasoningOutputIsSubsetOfOutputNotBilledSeparately() {
        // Per OpenAI's API spec, `output_tokens_details.reasoning_tokens` is a
        // breakdown OF `output_tokens` (total = input + output, not input +
        // output + reasoning). Reasoning is already charged inside `output`,
        // so it must NOT be billed again. A record with output=100K and
        // reasoning=100K (i.e. all output is reasoning) costs the same as
        // output=100K with no reasoning.
        let rate = Pricing.rate(for: "gpt-5")! // $1.25 in / $10 out
        let withReasoning = TokenUsage(input: 0, output: 100_000, cacheRead: 0, cacheWrite: 0, reasoningOutput: 100_000)
        let withoutReasoning = TokenUsage(input: 0, output: 100_000, cacheRead: 0, cacheWrite: 0, reasoningOutput: 0)
        // Both should be 100K * $10/MTok = $1.00 — reasoning is not additive.
        XCTAssertEqual(Pricing.cost(of: withReasoning, at: rate), 1.00, accuracy: 0.0001)
        XCTAssertEqual(Pricing.cost(of: withoutReasoning, at: rate), 1.00, accuracy: 0.0001)
    }

    func testUnknownRateIsFree() {
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)
        XCTAssertEqual(Pricing.cost(of: usage, at: Pricing.unknown), 0)
    }

    func testCacheReportingDenylistStartsWithOllamaCloud() {
        XCTAssertTrue(CacheReporting.nonReportingOpenCodeProviders.contains("ollama-cloud"))
        // An empty string must never be considered non-reporting — events with a
        // missing providerID default to "reporting" so they aren't silently dropped.
        XCTAssertFalse(CacheReporting.nonReportingOpenCodeProviders.contains(""))
    }

    func testCodexAutoReviewIsZeroRateAndNotBillable() {
        let rate = Pricing.rate(for: "codex-auto-review")
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate?.inputPerMTok, 0)
        XCTAssertEqual(rate?.outputPerMTok, 0)
        XCTAssertEqual(rate?.cachedInputPerMTok, 0)
        // Sanity: must be free at any volume.
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)
        XCTAssertEqual(Pricing.cost(of: usage, at: rate!), 0)
        // The routing label has a catalog entry (so displayName resolves and
        // exact-match is honored) but is not billable — the UI shows "-" for
        // it, not "$0".
        XCTAssertFalse(Pricing.isBillable(for: "codex-auto-review"))
    }

    func testIsBillableForPricedAndUnknownModels() {
        XCTAssertTrue(Pricing.isBillable(for: "claude-opus-4-8"))
        XCTAssertTrue(Pricing.isBillable(for: "gpt-5.2"))
        XCTAssertTrue(Pricing.isBillable(for: "glm-5.2"))
        // Unknown models have no catalog entry → not billable.
        XCTAssertFalse(Pricing.isBillable(for: "internal-experimental-v0"))
    }

    func testCodexAutoReviewMatchingIsExact() {
        // Substrings must NOT match (no fallback to a different model).
        XCTAssertNil(Pricing.rate(for: "codex-auto-review-fork"))
        XCTAssertNil(Pricing.rate(for: "codex"))
    }

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
}
