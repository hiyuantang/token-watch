import Foundation

struct OpenCodeScanner: Sendable {
    func scan(root: URL?, now: Date = Date()) -> ScanResult {
        ScanResult(events: [], sources: [])
    }
}