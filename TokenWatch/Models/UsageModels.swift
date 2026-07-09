import Foundation

enum UsageProvider: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case claudeCode
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    var selectedFolderName: String {
        switch self {
        case .claudeCode: ".claude"
        case .codex: ".codex"
        }
    }

    var expectedRelativeDirectory: String {
        switch self {
        case .claudeCode: "projects"
        case .codex: "sessions"
        }
    }
}

enum UsageRange: Int, CaseIterable, Identifiable, Sendable {
    case day = 1
    case week = 7
    case month = 30

    var id: Int { rawValue }
    var shortTitle: String { "\(rawValue)D" }
    var accessibilityTitle: String { "Last \(rawValue) calendar day\(rawValue == 1 ? "" : "s")" }
}

struct TokenUsage: Hashable, Sendable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var reasoningOutput: Int = 0
    var recordedTotal: Int = 0

    init(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoningOutput: Int = 0,
        recordedTotal: Int? = nil
    ) {
        self.input = max(input, 0)
        self.output = max(output, 0)
        self.cacheRead = max(cacheRead, 0)
        self.cacheWrite = max(cacheWrite, 0)
        self.reasoningOutput = max(reasoningOutput, 0)
        self.recordedTotal = max(recordedTotal ?? self.input + self.output + self.cacheRead + self.cacheWrite, 0)
    }

    static let zero = TokenUsage()

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            reasoningOutput: lhs.reasoningOutput + rhs.reasoningOutput,
            recordedTotal: lhs.recordedTotal + rhs.recordedTotal
        )
    }

    func delta(from previous: TokenUsage) -> TokenUsage? {
        let valuesAreMonotonic =
            input >= previous.input && output >= previous.output &&
            cacheRead >= previous.cacheRead && cacheWrite >= previous.cacheWrite &&
            reasoningOutput >= previous.reasoningOutput && recordedTotal >= previous.recordedTotal

        guard valuesAreMonotonic else { return nil }

        return TokenUsage(
            input: input - previous.input,
            output: output - previous.output,
            cacheRead: cacheRead - previous.cacheRead,
            cacheWrite: cacheWrite - previous.cacheWrite,
            reasoningOutput: reasoningOutput - previous.reasoningOutput,
            recordedTotal: recordedTotal - previous.recordedTotal
        )
    }
}

/// Contains only typed usage metadata. The opaque session token is generated in memory and is not a provider session ID.
struct UsageEvent: Hashable, Sendable, Identifiable {
    let id: UUID
    let provider: UsageProvider
    let timestamp: Date
    let model: String
    let sessionToken: UUID
    let usage: TokenUsage
}

enum SourceState: String, Sendable {
    case notConfigured
    case ready
    case missingExpectedDirectory
    case inaccessible

    var displayName: String {
        switch self {
        case .notConfigured: "Not configured"
        case .ready: "Ready"
        case .missingExpectedDirectory: "Folder layout not found"
        case .inaccessible: "Access needs attention"
        }
    }
}

struct SourceHealth: Identifiable, Sendable {
    let provider: UsageProvider
    var state: SourceState
    var scannedFiles: Int
    var usageRecords: Int
    var malformedLines: Int
    var unreadableFiles: Int
    var lastRefresh: Date?

    var id: UsageProvider { provider }

    static func unconfigured(_ provider: UsageProvider) -> SourceHealth {
        SourceHealth(
            provider: provider,
            state: .notConfigured,
            scannedFiles: 0,
            usageRecords: 0,
            malformedLines: 0,
            unreadableFiles: 0,
            lastRefresh: nil
        )
    }
}

struct ProviderSummary: Identifiable, Sendable {
    let provider: UsageProvider
    let usage: TokenUsage

    var id: UsageProvider { provider }
}

struct ModelSummary: Identifiable, Sendable {
    let provider: UsageProvider
    let model: String
    let usage: TokenUsage

    var id: String { "\(provider.rawValue)-\(model)" }
}

struct TimelineBucket: Identifiable, Sendable {
    let date: Date
    let provider: UsageProvider
    let recordedTotal: Int

    var id: String { "\(date.timeIntervalSinceReferenceDate)-\(provider.rawValue)" }
}

struct UsageSnapshot: Sendable {
    let range: UsageRange
    let usage: TokenUsage
    let providers: [ProviderSummary]
    let models: [ModelSummary]
    let timeline: [TimelineBucket]
    let sessionCount: Int
    let cacheReadShare: Double
    let currentStreak: Int
    let peakActivityLabel: String
    let sources: [SourceHealth]

    static func empty(range: UsageRange, sources: [SourceHealth]) -> UsageSnapshot {
        UsageSnapshot(
            range: range,
            usage: .zero,
            providers: UsageProvider.allCases.map { ProviderSummary(provider: $0, usage: .zero) },
            models: [],
            timeline: [],
            sessionCount: 0,
            cacheReadShare: 0,
            currentStreak: 0,
            peakActivityLabel: "No activity yet",
            sources: sources
        )
    }
}

struct ScanResult: Sendable {
    let events: [UsageEvent]
    let sources: [SourceHealth]
}
