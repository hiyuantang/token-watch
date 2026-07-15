import Foundation
import XCTest
@testable import TokenWatch

final class UsageScannerTests: XCTestCase {
    func testClaudeAssistantUsageIsDeduplicatedAndMalformedLinesAreReported() throws {
        let root = try makeTemporaryDirectory(named: ".claude")
        let projects = root.appendingPathComponent("projects/session", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        let transcript = """
        {"type":"assistant","timestamp":"2026-07-09T10:00:00Z","sessionId":"session-1","uuid":"message-1","message":{"id":"message-1","model":"claude-test","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4},"content":"ignored"}}
        {"type":"assistant","timestamp":"2026-07-09T10:00:00Z","sessionId":"session-1","uuid":"message-1","message":{"id":"message-1","model":"claude-test","usage":{"input_tokens":10,"output_tokens":2}}}
        not-json
        """
        try transcript.data(using: .utf8)!.write(to: projects.appendingPathComponent("session.jsonl"))

        let result = TranscriptScanner().scan(claudeRoot: root, codexRoot: nil, openCodeRoot: nil)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.provider, .claudeCode)
        XCTAssertEqual(result.events.first?.model, "claude-test")
        XCTAssertEqual(result.events.first?.usage.recordedTotal, 19)
        XCTAssertEqual(result.sources.first?.malformedLines, 1)
    }

    func testCodexUsesCumulativeDeltasAndAssociatesTurnModel() throws {
        let root = try makeTemporaryDirectory(named: ".codex")
        let sessions = root.appendingPathComponent("sessions/2026/07/09", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let transcript = """
        {"type":"turn_context","timestamp":"2026-07-09T10:00:00Z","payload":{"model":"gpt-test"}}
        {"type":"event_msg","timestamp":"2026-07-09T10:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5,"output_tokens":5,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":10},"last_token_usage":{"input_tokens":5,"output_tokens":5,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":10}},"rate_limits":{"primary":"ignored"}}}
        {"type":"event_msg","timestamp":"2026-07-09T10:02:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9,"output_tokens":9,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":18},"last_token_usage":{"input_tokens":4,"output_tokens":4,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":8}}}}
        {"type":"turn_context","timestamp":"2026-07-09T10:03:00Z","payload":{"model":"gpt-reset"}}
        {"type":"event_msg","timestamp":"2026-07-09T10:04:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3,"output_tokens":2,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":5},"last_token_usage":{"input_tokens":1,"output_tokens":1,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":2}}}}
        """
        try transcript.data(using: .utf8)!.write(to: sessions.appendingPathComponent("rollout-test.jsonl"))

        let result = TranscriptScanner().scan(claudeRoot: nil, codexRoot: root, openCodeRoot: nil)

        XCTAssertEqual(result.events.map(\.usage.recordedTotal), [10, 8, 2])
        XCTAssertEqual(result.events.map(\.model), ["gpt-test", "gpt-test", "gpt-reset"])
        XCTAssertEqual(result.events.map(\.provider), [.codex, .codex, .codex])
    }

    func testClaudeParsesFractionalAndStandardTimestamps() throws {
        let root = try makeTemporaryDirectory(named: ".claude")
        let projects = root.appendingPathComponent("projects/session", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        let transcript = """
        {"type":"assistant","timestamp":"2026-07-09T10:00:00.123Z","sessionId":"session-1","uuid":"message-1","message":{"id":"message-1","model":"claude-test","usage":{"input_tokens":10,"output_tokens":2}}}
        {"type":"assistant","timestamp":"2026-07-09T10:01:00Z","sessionId":"session-1","uuid":"message-2","message":{"id":"message-2","model":"claude-test","usage":{"input_tokens":20,"output_tokens":3}}}
        """
        try transcript.data(using: .utf8)!.write(to: projects.appendingPathComponent("session.jsonl"))

        let result = TranscriptScanner().scan(claudeRoot: root, codexRoot: nil, openCodeRoot: nil)

        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.sources.first?.malformedLines, 0)
    }

    func testTargetedInputScanReadsOnlyTheChangedTranscript() throws {
        let root = try makeTemporaryDirectory(named: ".claude")
        let projects = root.appendingPathComponent("projects/session", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let unchanged = projects.appendingPathComponent("unchanged.jsonl")
        let changed = projects.appendingPathComponent("changed.jsonl")
        try Data(#"{"type":"assistant","timestamp":"2026-07-09T10:00:00Z","sessionId":"unchanged","uuid":"u1","message":{"id":"u1","model":"claude-test","usage":{"input_tokens":10,"output_tokens":2}}}"# .utf8).write(to: unchanged)
        try Data(#"{"type":"assistant","timestamp":"2026-07-09T10:01:00Z","sessionId":"changed","uuid":"c1","message":{"id":"c1","model":"claude-test","usage":{"input_tokens":20,"output_tokens":3}}}"# .utf8).write(to: changed)

        let scanner = TranscriptScanner()
        let initial = scanner.scanDetailed(claudeRoot: root, codexRoot: nil, openCodeRoot: nil)
        let originalToken = try XCTUnwrap(
            initial.providers
                .first { $0.provider == .claudeCode }?
                .inputs
                .first { URL(fileURLWithPath: $0.path).lastPathComponent == changed.lastPathComponent }?
                .events
                .first?
                .sessionToken
        )

        try Data(#"{"type":"assistant","timestamp":"2026-07-09T10:02:00Z","sessionId":"changed","uuid":"c2","message":{"id":"c2","model":"claude-test","usage":{"input_tokens":30,"output_tokens":4}}}"# .utf8).write(to: changed, options: .atomic)
        let incremental = scanner.scanInputs(.claudeCode, paths: [changed.path], sessionTokens: initial.sessionTokens)

        XCTAssertEqual(incremental.inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, [changed.lastPathComponent])
        XCTAssertEqual(incremental.inputs.first?.events.count, 1)
        XCTAssertEqual(incremental.inputs.first?.events.first?.sessionToken, originalToken)
        XCTAssertTrue(incremental.removedPaths.isEmpty)
    }

    func testMissingExpectedDirectoryIsVisibleAsSourceHealth() throws {
        let root = try makeTemporaryDirectory(named: ".claude")
        let result = TranscriptScanner().scan(claudeRoot: root, codexRoot: nil, openCodeRoot: nil)
        let claude = try XCTUnwrap(result.sources.first { $0.provider == .claudeCode })

        XCTAssertEqual(claude.state, .missingExpectedDirectory)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testClaudeSyntheticModelRecordsAreSkipped() throws {
        let root = try makeTemporaryDirectory(named: ".claude")
        let projects = root.appendingPathComponent("projects/session", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        let transcript = """
        {"type":"assistant","timestamp":"2026-07-09T10:00:00Z","sessionId":"session-1","uuid":"message-synthetic","message":{"id":"message-synthetic","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        {"type":"assistant","timestamp":"2026-07-09T10:01:00Z","sessionId":"session-1","uuid":"message-real","message":{"id":"message-real","model":"claude-test","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}}
        """
        try transcript.data(using: .utf8)!.write(to: projects.appendingPathComponent("session.jsonl"))

        let result = TranscriptScanner().scan(claudeRoot: root, codexRoot: nil, openCodeRoot: nil)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.model, "claude-test")
        XCTAssertEqual(result.events.first?.usage.recordedTotal, 19)
        let claude = try XCTUnwrap(result.sources.first { $0.provider == .claudeCode })
        XCTAssertEqual(claude.malformedLines, 0)
    }

    func testThreeProvidersMergeThroughTranscriptScanner() throws {
        let claudeRoot = try makeTemporaryDirectory(named: ".claude")
        let projects = claudeRoot.appendingPathComponent("projects/session", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        var claudeLine = Data(#"{"type":"assistant","timestamp":"2026-07-09T10:00:00Z","sessionId":"s1","uuid":"m1","message":{"id":"m1","model":"claude-test","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}}"#.utf8)
        claudeLine.append(0x0A)
        try claudeLine.write(to: projects.appendingPathComponent("session.jsonl"))

        let codexRoot = try makeTemporaryDirectory(named: ".codex")
        let sessions = codexRoot.appendingPathComponent("sessions/2026/07/09", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var codexLine = Data(#"{"type":"event_msg","timestamp":"2026-07-09T10:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5,"output_tokens":5,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":10},"last_token_usage":{"input_tokens":5,"output_tokens":5,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":10}}}}"#.utf8)
        codexLine.append(0x0A)
        try codexLine.write(to: sessions.appendingPathComponent("rollout.jsonl"))

        let openCodeRoot = try makeTemporaryDirectory(named: "opencode")
        let dbPath = openCodeRoot.appendingPathComponent("opencode.db")
        try runSqliteCli(dbPath, sql: "CREATE TABLE session (id TEXT PRIMARY KEY, model TEXT NOT NULL, tokens_input INTEGER NOT NULL, tokens_output INTEGER NOT NULL, tokens_cache_read INTEGER NOT NULL, tokens_cache_write INTEGER NOT NULL, tokens_reasoning INTEGER NOT NULL, cost REAL NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL);")
        try runSqliteCli(dbPath, sql: "INSERT INTO session (id, model, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write, tokens_reasoning, cost, time_created, time_updated) VALUES ('ses_a', '{\"id\":\"glm-5.2\"}', 100, 20, 0, 0, 0, 0.0, 1783636290026, 1783636290026);")

        let result = TranscriptScanner().scan(claudeRoot: claudeRoot, codexRoot: codexRoot, openCodeRoot: openCodeRoot)

        let providerCounts = Dictionary(grouping: result.events.map(\.provider), by: { $0 }).mapValues(\.count)
        XCTAssertEqual(providerCounts[.claudeCode], 1)
        XCTAssertEqual(providerCounts[.codex], 1)
        XCTAssertEqual(providerCounts[.openCode], 1)
        XCTAssertEqual(result.sources.count, 3)
        let readyProviders = result.sources.filter { $0.state == .ready }
        XCTAssertEqual(readyProviders.count, 3)
    }

    func testCodexIgnoresNonGptModelsButKeepsAutoReview() throws {
        let root = try makeTemporaryDirectory(named: ".codex")
        let sessions = root.appendingPathComponent("sessions/2026/07/09", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let transcript = """
        {"type":"turn_context","timestamp":"2026-07-09T10:00:00Z","payload":{"model":"mimo-v2.5-pro"}}
        {"type":"event_msg","timestamp":"2026-07-09T10:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5,"output_tokens":5,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":10},"last_token_usage":{"input_tokens":5,"output_tokens":5,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":10}}}}
        {"type":"turn_context","timestamp":"2026-07-09T10:02:00Z","payload":{"model":"gpt-5.2"}}
        {"type":"event_msg","timestamp":"2026-07-09T10:03:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9,"output_tokens":9,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":18},"last_token_usage":{"input_tokens":4,"output_tokens":4,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":8}}}}
        {"type":"turn_context","timestamp":"2026-07-09T10:04:00Z","payload":{"model":"codex-auto-review"}}
        {"type":"event_msg","timestamp":"2026-07-09T10:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3,"output_tokens":2,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":5},"last_token_usage":{"input_tokens":1,"output_tokens":1,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":2}}}}
        """
        try transcript.data(using: .utf8)!.write(to: sessions.appendingPathComponent("rollout-mixed.jsonl"))

        let result = TranscriptScanner().scan(claudeRoot: nil, codexRoot: root, openCodeRoot: nil)

        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.events.map(\.model), ["gpt-5.2", "codex-auto-review"])
        XCTAssertEqual(result.events.map(\.usage.recordedTotal), [8, 2])
    }

    func testCodexInputExcludesCachedTokensAcrossCumulativeDelta() throws {
        // Codex's `input_tokens` is the total input and already includes
        // `cached_input_tokens` (total_tokens == input_tokens + output_tokens).
        // The scanner must move the cached portion out of `input` so the two
        // buckets are non-overlapping, matching the Claude convention used by
        // TokenUsage. This guards against a regression where cached tokens were
        // double-counted in both cost and the cache-read-share denominator.
        let root = try makeTemporaryDirectory(named: ".codex")
        let sessions = root.appendingPathComponent("sessions/2026/07/09", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let transcript = """
        {"type":"turn_context","timestamp":"2026-07-09T10:00:00Z","payload":{"model":"gpt-5.2"}}
        {"type":"event_msg","timestamp":"2026-07-09T10:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":100,"cached_input_tokens":800,"reasoning_output_tokens":0,"total_tokens":1100},"last_token_usage":{"input_tokens":1000,"output_tokens":100,"cached_input_tokens":800,"reasoning_output_tokens":0,"total_tokens":1100}}}}
        {"type":"event_msg","timestamp":"2026-07-09T10:02:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"output_tokens":150,"cached_input_tokens":1700,"reasoning_output_tokens":0,"total_tokens":2150},"last_token_usage":{"input_tokens":1000,"output_tokens":50,"cached_input_tokens":900,"reasoning_output_tokens":0,"total_tokens":1050}}}}
        """
        try transcript.data(using: .utf8)!.write(to: sessions.appendingPathComponent("rollout-cached.jsonl"))

        let result = TranscriptScanner().scan(claudeRoot: nil, codexRoot: root, openCodeRoot: nil)

        // First event: full total. input 1000 - cached 800 = 200 non-cached.
        XCTAssertEqual(result.events[0].usage.input, 200)
        XCTAssertEqual(result.events[0].usage.cacheRead, 800)
        XCTAssertEqual(result.events[0].usage.output, 100)
        XCTAssertEqual(result.events[0].usage.recordedTotal, 1100)

        // Second event: cumulative delta. non-cached input delta = (2000-1000) - (1700-800) = 100.
        XCTAssertEqual(result.events[1].usage.input, 100)
        XCTAssertEqual(result.events[1].usage.cacheRead, 900)
        XCTAssertEqual(result.events[1].usage.output, 50)
        XCTAssertEqual(result.events[1].usage.recordedTotal, 1050)

        // Buckets must not overlap: input + cacheRead + output == recordedTotal.
        for event in result.events {
            let sum = event.usage.input + event.usage.cacheRead + event.usage.output
            XCTAssertEqual(sum, event.usage.recordedTotal)
        }
    }

    private func runSqliteCli(_ dbPath: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "sqlite3 failed for SQL: \(sql)")
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenWatchTests-\(UUID().uuidString)/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        return root
    }
}
