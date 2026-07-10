import CoreServices
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

    func testDispatchChangeDebouncesBurst() async throws {
        let watcher = TranscriptWatcher(debounceDuration: .milliseconds(50))
        var firedProviders: [UsageProvider] = []
        watcher.onChange = { firedProviders.append($0) }

        watcher.dispatchChange(.openCode)
        watcher.dispatchChange(.openCode)
        watcher.dispatchChange(.openCode)

        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(firedProviders.isEmpty)
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(firedProviders, [.openCode])
    }

    func testRelevanceFiltersUnrelatedFilesAndRecognizesScannerInputs() throws {
        let root = try makeTemporaryDirectory()
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let changedFile = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)

        XCTAssertFalse(
            TranscriptWatcher.isRelevant(path: root.appendingPathComponent("history.jsonl").path, flags: changedFile, for: .claudeCode, providerRoot: root)
        )
        XCTAssertTrue(
            TranscriptWatcher.isRelevant(path: projects.appendingPathComponent("session.jsonl").path, flags: changedFile, for: .claudeCode, providerRoot: root)
        )
        XCTAssertFalse(
            TranscriptWatcher.isRelevant(path: root.appendingPathComponent("config.json").path, flags: changedFile, for: .codex, providerRoot: root)
        )
        XCTAssertTrue(
            TranscriptWatcher.isRelevant(path: sessions.appendingPathComponent("session.jsonl").path, flags: changedFile, for: .codex, providerRoot: root)
        )
        XCTAssertFalse(
            TranscriptWatcher.isRelevant(path: root.appendingPathComponent("activity.log").path, flags: changedFile, for: .openCode, providerRoot: root)
        )
        XCTAssertTrue(
            TranscriptWatcher.isRelevant(path: root.appendingPathComponent("opencode.db-wal").path, flags: changedFile, for: .openCode, providerRoot: root)
        )
    }

    func testRelevanceRecoversFromDroppedOrRootChangedEvents() throws {
        let root = try makeTemporaryDirectory()

        XCTAssertTrue(
            TranscriptWatcher.isRelevant(
                path: root.appendingPathComponent("unrelated.log").path,
                flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs),
                for: .claudeCode,
                providerRoot: root
            )
        )
        XCTAssertTrue(
            TranscriptWatcher.isRelevant(
                path: root.appendingPathComponent("unrelated.log").path,
                flags: UInt32(kFSEventStreamEventFlagRootChanged),
                for: .openCode,
                providerRoot: root
            )
        )
    }

    func testOpenCodeWatcherIgnoresNonDatabaseWrites() throws {
        let root = try makeTemporaryDirectory()
        let watcher = TranscriptWatcher(debounceDuration: .milliseconds(50))
        var firedProviders: [UsageProvider] = []
        watcher.onChange = { firedProviders.append($0) }
        watcher.start(for: .openCode, directory: root)

        try Data("noise".utf8).write(to: root.appendingPathComponent("activity.log"))
        let quietExpectation = expectation(description: "unrelated write is ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { quietExpectation.fulfill() }
        wait(for: [quietExpectation], timeout: 2.0)
        XCTAssertTrue(firedProviders.isEmpty)

        try Data().write(to: root.appendingPathComponent("opencode.db-wal"))
        let changeExpectation = expectation(description: "database write is observed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { changeExpectation.fulfill() }
        wait(for: [changeExpectation], timeout: 2.0)

        watcher.stopAll()
        XCTAssertEqual(firedProviders, [.openCode])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenWatchWatcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}
