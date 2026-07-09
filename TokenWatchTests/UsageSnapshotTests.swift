import Foundation
import XCTest
@testable import TokenWatch

final class UsageSnapshotTests: XCTestCase {
    func testDayRangeExcludesPriorCalendarDayAndCalculatesCacheShare() {
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
        XCTAssertEqual(snapshot.cacheReadShare, 0.5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.currentStreak, 1)
        XCTAssertEqual(calendar.startOfDay(for: snapshot.timeline[0].date), calendar.startOfDay(for: today.timestamp))
    }

    func testEmptySnapshotProvidesBothProviders() {
        let snapshot = UsageAggregator.snapshot(
            events: [],
            range: .month,
            sources: UsageProvider.allCases.map(SourceHealth.unconfigured),
            now: Date()
        )

        XCTAssertEqual(snapshot.providers.count, 2)
        XCTAssertEqual(snapshot.usage.recordedTotal, 0)
        XCTAssertTrue(snapshot.models.isEmpty)
    }
}
