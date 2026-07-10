import Foundation
import XCTest
@testable import TokenWatch

final class UsageSnapshotTests: XCTestCase {
    func testDayRangeExcludesPriorCalendarDayAndCalculatesCacheShare() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = ISO8601DateFormatter().date(from: "2026-07-09T16:00:00Z")!
        let session = UUID()
        let today = UsageEvent(
            id: UUID(),
            provider: .claudeCode,
            timestamp: ISO8601DateFormatter().date(from: "2026-07-09T09:00:00Z")!,
            model: "claude-test",
            sessionToken: session,
            usage: TokenUsage(input: 10, output: 5, cacheRead: 10, cacheWrite: 0)
        )
        let yesterday = UsageEvent(
            id: UUID(),
            provider: .codex,
            timestamp: ISO8601DateFormatter().date(from: "2026-07-08T23:00:00Z")!,
            model: "gpt-test",
            sessionToken: UUID(),
            usage: TokenUsage(input: 30, output: 10, recordedTotal: 40)
        )
        let sources = UsageProvider.allCases.map(SourceHealth.unconfigured)

        let snapshot = UsageAggregator.snapshot(events: [today, yesterday], range: .day, sources: sources, now: now)

        XCTAssertEqual(snapshot.usage.recordedTotal, 25)
        XCTAssertEqual(snapshot.sessionCount, 1)
        XCTAssertEqual(snapshot.models.map(\.model), ["claude-test"])
        let cacheShare = try XCTUnwrap(snapshot.cacheReadShare)
        XCTAssertEqual(cacheShare.value, 0.5, accuracy: 0.0001)
        XCTAssertFalse(cacheShare.inferred)
        XCTAssertEqual(snapshot.currentStreak, 1)
        XCTAssertEqual(calendar.startOfDay(for: snapshot.timeline[0].date), calendar.startOfDay(for: today.timestamp))
    }

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

    func testTotalRangeIncludesAllEventsAndUsesMonthlyBuckets() {
        let calendar = Calendar(identifier: .gregorian)
        let now = ISO8601DateFormatter().date(from: "2026-07-09T16:00:00Z")!
        let recent = UsageEvent(
            id: UUID(),
            provider: .claudeCode,
            timestamp: ISO8601DateFormatter().date(from: "2026-07-09T09:00:00Z")!,
            model: "claude-test",
            sessionToken: UUID(),
            usage: TokenUsage(input: 10, output: 5, cacheRead: 10, cacheWrite: 0)
        )
        let old = UsageEvent(
            id: UUID(),
            provider: .codex,
            timestamp: ISO8601DateFormatter().date(from: "2025-11-08T23:00:00Z")!,
            model: "gpt-test",
            sessionToken: UUID(),
            usage: TokenUsage(input: 30, output: 10, recordedTotal: 40)
        )
        let sources = UsageProvider.allCases.map(SourceHealth.unconfigured)

        let snapshot = UsageAggregator.snapshot(events: [recent, old], range: .total, sources: sources, now: now)

        XCTAssertEqual(snapshot.usage.recordedTotal, 65)
        XCTAssertEqual(snapshot.models.count, 2)
        XCTAssertEqual(snapshot.sessionCount, 2)
        XCTAssertFalse(snapshot.timeline.isEmpty)
        for bucket in snapshot.timeline {
            let day = calendar.dateInterval(of: .day, for: bucket.date)?.start
            XCTAssertEqual(bucket.date, calendar.dateInterval(of: .month, for: bucket.date)?.start)
            XCTAssertNotNil(day)
        }
    }

    func testCostEstimateSumsPerEventAndReportsUnpricedModels() {
        let now = ISO8601DateFormatter().date(from: "2026-07-09T16:00:00Z")!
        // Known-priced: claude-opus-4-8 at $5 in / $25 out / $0.50 cache read.
        let priced = UsageEvent(
            id: UUID(),
            provider: .claudeCode,
            timestamp: ISO8601DateFormatter().date(from: "2026-07-09T09:00:00Z")!,
            model: "claude-opus-4-8",
            sessionToken: UUID(),
            usage: TokenUsage(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)
        )
        // Unknown model: contributes $0 and is counted as unpriced.
        let unpriced = UsageEvent(
            id: UUID(),
            provider: .codex,
            timestamp: ISO8601DateFormatter().date(from: "2026-07-09T10:00:00Z")!,
            model: "internal-experimental-v0",
            sessionToken: UUID(),
            usage: TokenUsage(input: 500_000, output: 500_000)
        )
        let sources = UsageProvider.allCases.map(SourceHealth.unconfigured)

        let snapshot = UsageAggregator.snapshot(events: [priced, unpriced], range: .day, sources: sources, now: now)

        XCTAssertEqual(snapshot.cost.totalUSD, 5.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.cost.inputUSD, 5.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.cost.unpricedModelCount, 1)
        // Per-provider cost: Claude $5, Codex $0 (unpriced model).
        let claude = snapshot.providers.first { $0.provider == .claudeCode }!
        let codex = snapshot.providers.first { $0.provider == .codex }!
        XCTAssertEqual(claude.costUSD, 5.0, accuracy: 0.0001)
        XCTAssertEqual(codex.costUSD, 0.0, accuracy: 0.0001)
        // Per-model: priced model marked priced, unpriced model marked not.
        let pricedModel = snapshot.models.first { $0.model == "claude-opus-4-8" }!
        let unpricedModel = snapshot.models.first { $0.model == "internal-experimental-v0" }!
        XCTAssertTrue(pricedModel.priced)
        XCTAssertFalse(unpricedModel.priced)
        XCTAssertEqual(pricedModel.costUSD, 5.0, accuracy: 0.0001)
    }

    func testEmptySnapshotCostIsZero() {
        let snapshot = UsageAggregator.snapshot(
            events: [],
            range: .month,
            sources: UsageProvider.allCases.map(SourceHealth.unconfigured),
            now: Date()
        )
        XCTAssertEqual(snapshot.cost.totalUSD, 0)
        XCTAssertEqual(snapshot.cost.unpricedModelCount, 0)
        for provider in snapshot.providers {
            XCTAssertEqual(provider.costUSD, 0)
        }
    }

    func testCacheShareExcludesOpenCodeNonReportingEvents() throws {
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
        let cacheShare = try XCTUnwrap(snapshot.cacheReadShare)
        XCTAssertEqual(cacheShare.value, 50.0 / 150.0, accuracy: 0.0001)
        XCTAssertFalse(cacheShare.inferred)
        // Overall usage includes BOTH events (the filter only affects cache share).
        XCTAssertEqual(snapshot.usage.input, 10_100)
    }

    func testCacheShareStepsBackToWiderRangeWhenSelectedHasNoReportingEvents() throws {
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
        // Older event in the week window from a reporting provider (3 days back,
        // within the .week rangeStart of `startOfDay(now) − 6 days`).
        let oldReporting = UsageEvent(
            id: UUID(),
            provider: .claudeCode,
            timestamp: ISO8601DateFormatter().date(from: "2026-07-06T09:00:00Z")!,
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
        let cacheShare = try XCTUnwrap(snapshot.cacheReadShare)
        XCTAssertEqual(cacheShare.value, 100.0 / 300.0, accuracy: 0.0001)
        XCTAssertTrue(cacheShare.inferred)
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
}

