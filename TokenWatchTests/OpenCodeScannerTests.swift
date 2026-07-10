import Foundation
import XCTest
@testable import TokenWatch

final class OpenCodeScannerTests: XCTestCase {
    func testMissingDirectoryReportsMissingExpectedDirectory() throws {
        let root = try makeTemporaryDirectory()
        let result = OpenCodeScanner().scan(root: root, now: Date())

        let health = try XCTUnwrap(result.sources.first { $0.provider == .openCode })
        XCTAssertEqual(health.state, .missingExpectedDirectory)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testHappyPathEmitsOneEventPerSessionRow() throws {
        let root = try makeTemporaryDirectory()
        try createOpencodeDb(in: root, sessions: [
            (id: "ses_a", model: #"{"id":"glm-5.2","providerID":"ollama-cloud","variant":"max"}"#,
             input: 100, output: 20, cacheRead: 0, cacheWrite: 0, reasoning: 0, updatedMs: 1_783_636_290_026),
            (id: "ses_b", model: #"{"id":"claude-sonnet-4","providerID":"anthropic"}"#,
             input: 50, output: 10, cacheRead: 5, cacheWrite: 2, reasoning: 0, updatedMs: 1_783_636_300_000)
        ])

        let result = OpenCodeScanner().scan(root: root, now: Date())

        XCTAssertEqual(result.events.count, 2)
        let first = try XCTUnwrap(result.events.first { $0.model == "glm-5.2" })
        XCTAssertEqual(first.provider, .openCode)
        XCTAssertEqual(first.usage.input, 100)
        XCTAssertEqual(first.usage.output, 20)
        XCTAssertEqual(first.usage.recordedTotal, 120)
        let second = try XCTUnwrap(result.events.first { $0.model == "claude-sonnet-4" })
        XCTAssertEqual(second.usage.cacheRead, 5)
        XCTAssertEqual(second.usage.cacheWrite, 2)
        XCTAssertEqual(second.usage.recordedTotal, 67)
        let health = try XCTUnwrap(result.sources.first { $0.provider == .openCode })
        XCTAssertEqual(health.state, .ready)
        XCTAssertEqual(health.usageRecords, 2)
    }

    func testMalformedModelJsonFallsBackToUnknownAndCountsMalformed() throws {
        let root = try makeTemporaryDirectory()
        try createOpencodeDb(in: root, sessions: [
            (id: "ses_bad", model: "not-json",
             input: 10, output: 5, cacheRead: 0, cacheWrite: 0, reasoning: 0, updatedMs: 1_783_636_290_026)
        ])

        let result = OpenCodeScanner().scan(root: root, now: Date())

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.model, "Unknown model")
        let health = try XCTUnwrap(result.sources.first { $0.provider == .openCode })
        XCTAssertEqual(health.malformedLines, 1)
        XCTAssertEqual(health.usageRecords, 1)
    }

    func testMultipleDbFilesAreAggregated() throws {
        let root = try makeTemporaryDirectory()
        try createOpencodeDb(filename: "opencode.db", in: root, sessions: [
            (id: "ses_a", model: #"{"id":"glm-5.2"}"#, input: 10, output: 5, cacheRead: 0, cacheWrite: 0, reasoning: 0, updatedMs: 1_783_636_290_026)
        ])
        try createOpencodeDb(filename: "opencode-staging.db", in: root, sessions: [
            (id: "ses_b", model: #"{"id":"glm-5.2"}"#, input: 30, output: 15, cacheRead: 0, cacheWrite: 0, reasoning: 0, updatedMs: 1_783_636_300_000)
        ])

        let result = OpenCodeScanner().scan(root: root, now: Date())

        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.events.map(\.usage.input).sorted(), [10, 30])
        let health = try XCTUnwrap(result.sources.first { $0.provider == .openCode })
        XCTAssertEqual(health.scannedFiles, 2)
    }

    func testUnreadableDbFileIsReportedButOthersStillScan() throws {
        let root = try makeTemporaryDirectory()
        try Data("not a sqlite database".utf8).write(to: root.appendingPathComponent("opencode.db"))
        try createOpencodeDb(filename: "opencode-good.db", in: root, sessions: [
            (id: "ses_a", model: #"{"id":"glm-5.2"}"#, input: 10, output: 5, cacheRead: 0, cacheWrite: 0, reasoning: 0, updatedMs: 1_783_636_290_026)
        ])

        let result = OpenCodeScanner().scan(root: root, now: Date())

        XCTAssertEqual(result.events.count, 1)
        let health = try XCTUnwrap(result.sources.first { $0.provider == .openCode })
        XCTAssertEqual(health.unreadableFiles, 1)
        XCTAssertEqual(health.usageRecords, 1)
    }

    func testNullModelStillEmitsEventsWithUnknownModel() throws {
        let root = try makeTemporaryDirectory()
        let dbPath = root.appendingPathComponent("opencode.db")
        try runSqlite(dbPath, sql: """
            CREATE TABLE session (
                id TEXT PRIMARY KEY,
                model TEXT,
                tokens_input INTEGER NOT NULL,
                tokens_output INTEGER NOT NULL,
                tokens_cache_read INTEGER NOT NULL,
                tokens_cache_write INTEGER NOT NULL,
                tokens_reasoning INTEGER NOT NULL,
                cost REAL NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL
            );
            INSERT INTO session (id, model, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write, tokens_reasoning, cost, time_created, time_updated)
            VALUES ('ses_null', NULL, 100, 20, 0, 0, 0, 0.0, 1_783_636_290_026, 1_783_636_290_026);
            INSERT INTO session (id, model, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write, tokens_reasoning, cost, time_created, time_updated)
            VALUES ('ses_with_model', '{"id":"glm-5.2"}', 50, 10, 0, 0, 0, 0.0, 1_783_636_300_000, 1_783_636_300_000);
            """)

        let result = OpenCodeScanner().scan(root: root, now: Date())

        XCTAssertEqual(result.events.count, 2)
        let nullModelEvent = try XCTUnwrap(result.events.first { $0.usage.input == 100 })
        XCTAssertEqual(nullModelEvent.model, "Unknown model")
        XCTAssertEqual(nullModelEvent.usage.output, 20)
        let withModelEvent = try XCTUnwrap(result.events.first { $0.model == "glm-5.2" })
        XCTAssertEqual(withModelEvent.usage.input, 50)
        let health = try XCTUnwrap(result.sources.first { $0.provider == .openCode })
        XCTAssertEqual(health.usageRecords, 2)
        XCTAssertEqual(health.malformedLines, 1)
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func createOpencodeDb(
        filename: String = "opencode.db",
        in directory: URL,
        sessions: [(id: String, model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int, updatedMs: Int)]
    ) throws {
        let dbPath = directory.appendingPathComponent(filename)
        try runSqlite(dbPath, sql: """
            CREATE TABLE session (
                id TEXT PRIMARY KEY,
                model TEXT NOT NULL,
                tokens_input INTEGER NOT NULL,
                tokens_output INTEGER NOT NULL,
                tokens_cache_read INTEGER NOT NULL,
                tokens_cache_write INTEGER NOT NULL,
                tokens_reasoning INTEGER NOT NULL,
                cost REAL NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL
            );
            """)
        for s in sessions {
            let escapedModel = s.model.replacingOccurrences(of: "'", with: "''")
            try runSqlite(dbPath, sql: """
                INSERT INTO session (id, model, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write, tokens_reasoning, cost, time_created, time_updated)
                VALUES ('\(s.id)', '\(escapedModel)', \(s.input), \(s.output), \(s.cacheRead), \(s.cacheWrite), \(s.reasoning), 0.0, \(s.updatedMs), \(s.updatedMs));
                """)
        }
    }

    private func runSqlite(_ dbPath: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath.path, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("sqlite3 exited \(process.terminationStatus): \(output)")
            return
        }
    }
}