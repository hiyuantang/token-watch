import Foundation
import XCTest
@testable import TokenWatch

@MainActor
final class UsageStoreSyncTests: XCTestCase {
    func testManualSyncTriggersRefresh() async {
        let store = UsageStore()
        store.manualSync()
        try? await Task.sleep(for: .milliseconds(200))
        var health = store.sources.first { $0.provider == .openCode }
        if health?.lastRefresh == nil {
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                health = store.sources.first { $0.provider == .openCode }
                if health?.lastRefresh != nil { break }
            }
        }
        XCTAssertNotNil(health?.lastRefresh, "manualSync should drive a refresh; lastRefresh should be set")
    }

    func testUnreadableProviderScanPreservesLastKnownGoodEvents() {
        let previous = UsageEvent(
            id: UUID(),
            provider: .openCode,
            timestamp: Date(),
            model: "test-model",
            sessionToken: UUID(),
            usage: TokenUsage(input: 100, output: 20)
        )
        let source = SourceHealth(
            provider: .openCode,
            state: .inaccessible,
            scannedFiles: 1,
            usageRecords: 0,
            malformedLines: 0,
            unreadableFiles: 1,
            lastRefresh: Date()
        )

        let merged = UsageStore.mergedProviderEvents(
            existing: [previous],
            provider: .openCode,
            scanned: [],
            source: source
        )

        XCTAssertEqual(merged, [previous])
    }

    func testSuccessfulEmptyProviderScanClearsPreviousEvents() {
        let previous = UsageEvent(
            id: UUID(),
            provider: .openCode,
            timestamp: Date(),
            model: "test-model",
            sessionToken: UUID(),
            usage: TokenUsage(input: 100, output: 20)
        )
        let source = SourceHealth(
            provider: .openCode,
            state: .ready,
            scannedFiles: 1,
            usageRecords: 0,
            malformedLines: 0,
            unreadableFiles: 0,
            lastRefresh: Date()
        )

        let merged = UsageStore.mergedProviderEvents(
            existing: [previous],
            provider: .openCode,
            scanned: [],
            source: source
        )

        XCTAssertTrue(merged.isEmpty)
    }
}
