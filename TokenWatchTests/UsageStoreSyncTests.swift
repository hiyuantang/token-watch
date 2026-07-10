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
}