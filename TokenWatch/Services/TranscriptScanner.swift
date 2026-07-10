import Foundation

/// Reads JSONL as bytes and decodes only whitelisted usage metadata. Prompt and response text are never decoded.
struct TranscriptScanner: Sendable {
    func scan(claudeRoot: URL?, codexRoot: URL?, openCodeRoot: URL?, now: Date = Date()) -> ScanResult {
        var events: [UsageEvent] = []
        var healthByProvider = Dictionary(
            uniqueKeysWithValues: UsageProvider.allCases.map { ($0, SourceHealth.unconfigured($0)) }
        )

        scanClaude(root: claudeRoot, events: &events, health: &healthByProvider[.claudeCode], now: now)
        scanCodex(root: codexRoot, events: &events, health: &healthByProvider[.codex], now: now)
        scanOpenCode(root: openCodeRoot, events: &events, health: &healthByProvider[.openCode], now: now)

        return ScanResult(
            events: events.sorted { $0.timestamp < $1.timestamp },
            sources: UsageProvider.allCases.compactMap { healthByProvider[$0] }
        )
    }

    /// Scans a single provider. Used by the file-watcher path so a change in one
    /// provider's directory does not re-scan the other two.
    func scanProvider(_ provider: UsageProvider, root: URL?, now: Date = Date()) -> (events: [UsageEvent], source: SourceHealth) {
        var events: [UsageEvent] = []
        var health: SourceHealth?
        switch provider {
        case .claudeCode: scanClaude(root: root, events: &events, health: &health, now: now)
        case .codex: scanCodex(root: root, events: &events, health: &health, now: now)
        case .openCode: scanOpenCode(root: root, events: &events, health: &health, now: now)
        }
        return (events.sorted { $0.timestamp < $1.timestamp }, health ?? .unconfigured(provider))
    }

    private func scanOpenCode(
        root: URL?,
        events: inout [UsageEvent],
        health: inout SourceHealth?,
        now: Date
    ) {
        let result = OpenCodeScanner().scan(root: root, now: now)
        events.append(contentsOf: result.events)
        if let openCodeHealth = result.sources.first {
            health = openCodeHealth
        }
    }

    private func scanClaude(
        root: URL?,
        events: inout [UsageEvent],
        health: inout SourceHealth?,
        now: Date
    ) {
        guard let root else { return }
        var source = SourceHealth.unconfigured(.claudeCode)
        let directory = root.appendingPathComponent(UsageProvider.claudeCode.expectedRelativeDirectory, isDirectory: true)
        guard directoryExists(directory) else {
            source.state = .missingExpectedDirectory
            source.lastRefresh = now
            health = source
            return
        }

        source.state = .ready
        var sessionTokens: [String: UUID] = [:]
        var seenRecordIdentifiers = Set<String>()

        for url in jsonlFiles(in: directory) {
            source.scannedFiles += 1
            do {
                try scanClaudeFile(
                    at: url,
                    events: &events,
                    sessionTokens: &sessionTokens,
                    seenRecordIdentifiers: &seenRecordIdentifiers,
                    source: &source
                )
            } catch {
                source.unreadableFiles += 1
            }
        }

        source.lastRefresh = now
        health = source
    }

    private func scanClaudeFile(
        at url: URL,
        events: inout [UsageEvent],
        sessionTokens: inout [String: UUID],
        seenRecordIdentifiers: inout Set<String>,
        source: inout SourceHealth
    ) throws {
        let decoder = JSONDecoder()
        try streamLines(in: url) { line in
            guard let record = try? decoder.decode(ClaudeRecord.self, from: line) else {
                source.malformedLines += 1
                return
            }
            guard record.type == "assistant", let message = record.message, let usage = message.usage else { return }
            // Claude Code logs synthetic/system-generated assistant events with a "<synthetic>" model
            // and all-zero usage. They carry no real token usage, so skip them to avoid noise.
            if message.model == "<synthetic>" { return }
            guard let timestamp = parseTimestamp(record.timestamp) else {
                source.malformedLines += 1
                return
            }

            let recordIdentifier = record.uuid ?? "\(record.sessionId ?? "missing")|\(record.timestamp ?? "missing")|\(message.id ?? "missing")"
            guard seenRecordIdentifiers.insert(recordIdentifier).inserted else { return }

            let sessionIdentifier = record.sessionId ?? recordIdentifier
            let sessionToken = sessionTokens[sessionIdentifier] ?? UUID()
            sessionTokens[sessionIdentifier] = sessionToken

            let tokenUsage = TokenUsage(
                input: usage.inputTokens ?? 0,
                output: usage.outputTokens ?? 0,
                cacheRead: usage.cacheReadInputTokens ?? 0,
                cacheWrite: usage.cacheCreationInputTokens ?? 0
            )
            events.append(
                UsageEvent(
                    id: UUID(),
                    provider: .claudeCode,
                    timestamp: timestamp,
                    model: message.model?.isEmpty == false ? message.model! : "Unknown model",
                    sessionToken: sessionToken,
                    usage: tokenUsage
                )
            )
            source.usageRecords += 1
        }
    }

    private func scanCodex(
        root: URL?,
        events: inout [UsageEvent],
        health: inout SourceHealth?,
        now: Date
    ) {
        guard let root else { return }
        var source = SourceHealth.unconfigured(.codex)
        let directory = root.appendingPathComponent(UsageProvider.codex.expectedRelativeDirectory, isDirectory: true)
        guard directoryExists(directory) else {
            source.state = .missingExpectedDirectory
            source.lastRefresh = now
            health = source
            return
        }

        source.state = .ready
        for url in jsonlFiles(in: directory) {
            source.scannedFiles += 1
            do {
                try scanCodexFile(at: url, events: &events, source: &source)
            } catch {
                source.unreadableFiles += 1
            }
        }

        source.lastRefresh = now
        health = source
    }

    private func scanCodexFile(at url: URL, events: inout [UsageEvent], source: inout SourceHealth) throws {
        let decoder = JSONDecoder()
        let sessionToken = UUID()
        var model: String?
        var previousTotal: TokenUsage?
        var fallbackFingerprints = Set<String>()

        try streamLines(in: url) { line in
            guard let record = try? decoder.decode(CodexRecord.self, from: line) else {
                source.malformedLines += 1
                return
            }

            if record.type == "turn_context", let turnModel = record.payload?.model, !turnModel.isEmpty {
                model = turnModel
                return
            }

            guard record.type == "event_msg", record.payload?.type == "token_count", let info = record.payload?.info else { return }
            guard let timestamp = parseTimestamp(record.timestamp) else {
                source.malformedLines += 1
                return
            }

            let total = tokenUsage(from: info.totalTokenUsage)
            let last = tokenUsage(from: info.lastTokenUsage)
            let contribution: TokenUsage?

            if let total {
                if let previousTotal, let delta = total.delta(from: previousTotal) {
                    contribution = delta
                } else if previousTotal == nil {
                    contribution = total
                } else {
                    contribution = uniqueFallback(last, timestamp: timestamp, fingerprints: &fallbackFingerprints)
                }
                previousTotal = total
            } else {
                contribution = uniqueFallback(last, timestamp: timestamp, fingerprints: &fallbackFingerprints)
            }

            guard let contribution, contribution.recordedTotal > 0 else { return }
            events.append(
                UsageEvent(
                    id: UUID(),
                    provider: .codex,
                    timestamp: timestamp,
                    model: model ?? "Unknown model",
                    sessionToken: sessionToken,
                    usage: contribution
                )
            )
            source.usageRecords += 1
        }
    }

    private func uniqueFallback(
        _ usage: TokenUsage?,
        timestamp: Date,
        fingerprints: inout Set<String>
    ) -> TokenUsage? {
        guard let usage else { return nil }
        let fingerprint = "\(timestamp.timeIntervalSinceReferenceDate)|\(usage.input)|\(usage.output)|\(usage.cacheRead)|\(usage.reasoningOutput)|\(usage.recordedTotal)"
        return fingerprints.insert(fingerprint).inserted ? usage : nil
    }

    private func tokenUsage(from info: CodexTokenInfo?) -> TokenUsage? {
        guard let info else { return nil }
        return TokenUsage(
            input: info.inputTokens ?? 0,
            output: info.outputTokens ?? 0,
            cacheRead: info.cachedInputTokens ?? 0,
            reasoningOutput: info.reasoningOutputTokens ?? 0,
            recordedTotal: info.totalTokens
        )
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func jsonlFiles(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            guard (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func streamLines(in url: URL, handler: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var buffer = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                if newline > buffer.startIndex {
                    handler(Data(buffer[..<newline]))
                }
                buffer.removeSubrange(...newline)
            }
        }

        if !buffer.isEmpty {
            handler(buffer)
        }
    }

    private func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private struct ClaudeRecord: Decodable {
    let type: String?
    let timestamp: String?
    let sessionId: String?
    let uuid: String?
    let message: ClaudeMessage?
}

private struct ClaudeMessage: Decodable {
    let id: String?
    let model: String?
    let usage: ClaudeUsage?
}

private struct ClaudeUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}

private struct CodexRecord: Decodable {
    let type: String?
    let timestamp: String?
    let payload: CodexPayload?
}

private struct CodexPayload: Decodable {
    let type: String?
    let model: String?
    let info: CodexUsageEnvelope?
}

private struct CodexUsageEnvelope: Decodable {
    let lastTokenUsage: CodexTokenInfo?
    let totalTokenUsage: CodexTokenInfo?

    enum CodingKeys: String, CodingKey {
        case lastTokenUsage = "last_token_usage"
        case totalTokenUsage = "total_token_usage"
    }
}

private struct CodexTokenInfo: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedInputTokens: Int?
    let reasoningOutputTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }
}
