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

        let result = TranscriptScanner().scan(claudeRoot: root, codexRoot: nil)

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

        let result = TranscriptScanner().scan(claudeRoot: nil, codexRoot: root)

        XCTAssertEqual(result.events.map(\.usage.recordedTotal), [10, 8, 2])
        XCTAssertEqual(result.events.map(\.model), ["gpt-test", "gpt-test", "gpt-reset"])
        XCTAssertEqual(result.events.map(\.provider), [.codex, .codex, .codex])
    }

    func testMissingExpectedDirectoryIsVisibleAsSourceHealth() throws {
        let root = try makeTemporaryDirectory(named: ".claude")
        let result = TranscriptScanner().scan(claudeRoot: root, codexRoot: nil)
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

        let result = TranscriptScanner().scan(claudeRoot: root, codexRoot: nil)

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.model, "claude-test")
        XCTAssertEqual(result.events.first?.usage.recordedTotal, 19)
        let claude = try XCTUnwrap(result.sources.first { $0.provider == .claudeCode })
        XCTAssertEqual(claude.malformedLines, 0)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TokenWatchTests-\(UUID().uuidString)/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        return root
    }
}
