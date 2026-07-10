import Foundation
import XCTest
@testable import TokenWatch

@MainActor
final class TranscriptWatcherTests: XCTestCase {
    func testStartAndStopLifecycleDoesNotLeakStreams() throws {
        let dir = try makeTemporaryDirectory()
        let watcher = TranscriptWatcher()
        var fired: Int = 0
        watcher.onChange = { _ in fired &+= 1 }

        XCTAssertFalse(watcher.isWatching(for: .claudeCode))
        watcher.start(for: .claudeCode, directory: dir)
        XCTAssertTrue(watcher.isWatching(for: .claudeCode))

        watcher.stop(for: .claudeCode)
        XCTAssertFalse(watcher.isWatching(for: .claudeCode))

        watcher.stopAll()
        XCTAssertEqual(fired, 0, "No file changes -> no callbacks during lifecycle test")
    }

    func testStartReplacesExistingStreamForSameProvider() throws {
        let dir = try makeTemporaryDirectory()
        let watcher = TranscriptWatcher()

        watcher.start(for: .claudeCode, directory: dir)
        watcher.start(for: .claudeCode, directory: dir)

        XCTAssertTrue(watcher.isWatching(for: .claudeCode))
        watcher.stopAll()
    }

    func testStopAllClearsEveryProvider() throws {
        let dir = try makeTemporaryDirectory()
        let watcher = TranscriptWatcher()
        watcher.start(for: .claudeCode, directory: dir)
        watcher.start(for: .codex, directory: dir)
        watcher.start(for: .openCode, directory: dir)

        watcher.stopAll()
        XCTAssertFalse(watcher.isWatching(for: .claudeCode))
        XCTAssertFalse(watcher.isWatching(for: .codex))
        XCTAssertFalse(watcher.isWatching(for: .openCode))
    }

    func testOnChangeFiresCorrectProviderWhenFileChanges() throws {
        let dir = try makeTemporaryDirectory()
        let projects = dir.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        let watcher = TranscriptWatcher()
        var firedProviders: [UsageProvider] = []
        watcher.onChange = { firedProviders.append($0) }

        watcher.start(for: .claudeCode, directory: dir)

        let file = projects.appendingPathComponent("session.jsonl")
        try Data("{\"type\":\"assistant\"}\n".utf8).write(to: file)

        let expectation = expectation(description: "watcher fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { expectation.fulfill() }
        wait(for: [expectation], timeout: 5.0)

        watcher.stopAll()
        XCTAssertTrue(firedProviders.contains(.claudeCode), "Expected .claudeCode to fire; got \(firedProviders)")
        XCTAssertFalse(firedProviders.contains(.codex), ".codex should never fire for a .claudeCode stream")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenWatchWatcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}