import Foundation

enum UsageProvider: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case claudeCode
    case codex
    case openCode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .openCode: "OpenCode"
        }
    }

    var expectedRelativeDirectory: String {
        switch self {
        case .claudeCode: "projects"
        case .codex: "sessions"
        case .openCode: "."
        }
    }
}

enum UsageRange: Int, CaseIterable, Identifiable, Sendable {
    case day = 1
    case week = 7
    case month = 30
    case total = 0

    var id: Int { rawValue }
    var dayCount: Int? { self == .total ? nil : rawValue }
    var shortTitle: String { self == .total ? "Total" : "\(rawValue)D" }
    var accessibilityTitle: String {
        self == .total ? "All recorded activity" : "Last \(rawValue) calendar day\(rawValue == 1 ? "" : "s")"
    }
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

/// A cache-read share value with a flag indicating whether it was computed from
/// the selected range or stepped back from a wider range (because the selected
/// range had no cache-reporting events). UI surfaces `inferred` via a `~` prefix.
struct CacheShare: Sendable, Hashable {
    let value: Double
    let inferred: Bool
}

/// Contains only typed usage metadata. The opaque session token is generated in memory and is not a provider session ID.
struct UsageEvent: Hashable, Sendable, Identifiable {
    let id: UUID
    let provider: UsageProvider
    let timestamp: Date
    let model: String
    let sessionToken: UUID
    let usage: TokenUsage
    /// OpenCode model-provider routing tag (e.g. "ollama-cloud", "anthropic",
    /// "minimax"). `nil` for Claude Code and Codex events. Used only to gate
    /// which events count toward the cache-read-share denominator.
    var openCodeProviderID: String? = nil
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
    let costUSD: Double

    var id: UsageProvider { provider }
}

struct ModelSummary: Identifiable, Sendable {
    let provider: UsageProvider
    let model: String
    let usage: TokenUsage
    let costUSD: Double
    let priced: Bool

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
    let cacheReadShare: CacheShare?
    let currentStreak: Int
    let peakActivityLabel: String
    let sources: [SourceHealth]
    let cost: CostEstimate

    static func empty(range: UsageRange, sources: [SourceHealth]) -> UsageSnapshot {
        UsageSnapshot(
            range: range,
            usage: .zero,
            providers: UsageProvider.allCases.map { ProviderSummary(provider: $0, usage: .zero, costUSD: 0) },
            models: [],
            timeline: [],
            sessionCount: 0,
            cacheReadShare: nil,
            currentStreak: 0,
            peakActivityLabel: "No activity yet",
            sources: sources,
            cost: CostEstimate.zero
        )
    }
}

/// Illustrative USD cost derived from observed token totals and the static
/// `Pricing` catalog. This is a local estimate, not an invoice: it ignores
/// batch discounts, peak/off-peak tiers, fast mode, data-residency multipliers,
/// and provider-specific write premiums. Models with no catalog match
/// contribute $0 and are reported via `unpricedModelCount` so the UI can surface
/// the gap instead of silently understating cost.
struct CostEstimate: Sendable {
    let totalUSD: Double
    let inputUSD: Double
    let outputUSD: Double
    let cacheReadUSD: Double
    let cacheWriteUSD: Double
    let unpricedModelCount: Int

    static let zero = CostEstimate(totalUSD: 0, inputUSD: 0, outputUSD: 0, cacheReadUSD: 0, cacheWriteUSD: 0, unpricedModelCount: 0)

    static func + (lhs: CostEstimate, rhs: CostEstimate) -> CostEstimate {
        CostEstimate(
            totalUSD: lhs.totalUSD + rhs.totalUSD,
            inputUSD: lhs.inputUSD + rhs.inputUSD,
            outputUSD: lhs.outputUSD + rhs.outputUSD,
            cacheReadUSD: lhs.cacheReadUSD + rhs.cacheReadUSD,
            cacheWriteUSD: lhs.cacheWriteUSD + rhs.cacheWriteUSD,
            unpricedModelCount: lhs.unpricedModelCount + rhs.unpricedModelCount
        )
    }
}

struct ScanResult: Sendable {
    let events: [UsageEvent]
    let sources: [SourceHealth]
}

struct InputScan: Sendable {
    let provider: UsageProvider
    let path: String
    let events: [UsageEvent]
    let malformedLines: Int
    let unreadable: Bool
}

struct ProviderScan: Sendable {
    let provider: UsageProvider
    let source: SourceHealth
    let inputs: [InputScan]
}

struct DetailedScanResult: Sendable {
    let providers: [ProviderScan]
    let sessionTokens: InMemorySessionTokens

    var events: [UsageEvent] {
        providers.flatMap(\.inputs).flatMap(\.events).sorted { $0.timestamp < $1.timestamp }
    }

    var sources: [SourceHealth] {
        providers.map(\.source)
    }
}

struct InputScanBatch: Sendable {
    let provider: UsageProvider
    let inputs: [InputScan]
    let removedPaths: [String]
    let sessionTokens: InMemorySessionTokens
}

struct InMemorySessionTokens: Sendable {
    private var tokens: [String: UUID] = [:]

    mutating func token(for provider: UsageProvider, identifier: String) -> UUID {
        let key = opaqueKey(provider: provider, identifier: identifier)
        if let token = tokens[key] { return token }
        let token = UUID()
        tokens[key] = token
        return token
    }

    private func opaqueKey(provider: UsageProvider, identifier: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in provider.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        hash ^= 0
        hash &*= 1_099_511_628_211
        for byte in identifier.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
