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
        // 1M input + 1M cache read + 0.5M output at Opus 4.8 rates.
        // input: 1,000,000 * 5.00 / 1M = 5.00
        // cacheRead: 1,000,000 * 0.50 / 1M = 0.50
        // cacheWrite: 100,000 * 5.00 / 1M = 0.50 (charged at base input)
        // output: 500,000 * 25.00 / 1M = 12.50
        // total = 18.50
        let usage = TokenUsage(input: 1_000_000, output: 500_000, cacheRead: 1_000_000, cacheWrite: 100_000)
        let rate = Pricing.rate(for: "claude-opus-4-8")!
        let cost = Pricing.cost(of: usage, at: rate)
        XCTAssertEqual(cost, 18.50, accuracy: 0.0001)
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

    func testReasoningOutputBilledAtOutputRate() {
        // Codex-style records split reasoning output separately. It should be
        // billed at the output rate, not the input rate.
        let usage = TokenUsage(input: 0, output: 100_000, cacheRead: 0, cacheWrite: 0, reasoningOutput: 100_000)
        let rate = Pricing.rate(for: "gpt-5")! // $1.25 in / $10 out
        let cost = Pricing.cost(of: usage, at: rate)
        // 100K output + 100K reasoning at $10/MTok = $2.00
        XCTAssertEqual(cost, 2.00, accuracy: 0.0001)
    }

    func testUnknownRateIsFree() {
        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)
        XCTAssertEqual(Pricing.cost(of: usage, at: Pricing.unknown), 0)
    }
}