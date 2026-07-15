import Foundation

/// Reads JSONL as bytes and decodes only whitelisted usage metadata. Prompt and response text are never decoded.
struct TranscriptScanner: Sendable {
    func scan(claudeRoot: URL?, codexRoot: URL?, openCodeRoot: URL?, now: Date = Date()) -> ScanResult {
        let result = scanDetailed(
            claudeRoot: claudeRoot,
            codexRoot: codexRoot,
            openCodeRoot: openCodeRoot,
            now: now
        )
        return ScanResult(events: result.events, sources: result.sources)
    }

    func scanDetailed(
        claudeRoot: URL?,
        codexRoot: URL?,
        openCodeRoot: URL?,
        sessionTokens: InMemorySessionTokens = .init(),
        now: Date = Date()
    ) -> DetailedScanResult {
        var sessionTokens = sessionTokens
        let providers = [
            scanProvider(.claudeCode, root: claudeRoot, sessionTokens: &sessionTokens, now: now),
            scanProvider(.codex, root: codexRoot, sessionTokens: &sessionTokens, now: now),
            scanProvider(.openCode, root: openCodeRoot, sessionTokens: &sessionTokens, now: now)
        ]
        return DetailedScanResult(providers: providers, sessionTokens: sessionTokens)
    }

    func scanProviderDetailed(
        _ provider: UsageProvider,
        root: URL?,
        sessionTokens: InMemorySessionTokens,
        now: Date
    ) -> DetailedScanResult {
        var sessionTokens = sessionTokens
        let provider = scanProvider(provider, root: root, sessionTokens: &sessionTokens, now: now)
        return DetailedScanResult(providers: [provider], sessionTokens: sessionTokens)
    }

    func scanInputs(
        _ provider: UsageProvider,
        paths: Set<String>,
        sessionTokens: InMemorySessionTokens
    ) -> InputScanBatch {
        var sessionTokens = sessionTokens
        var inputs: [InputScan] = []
        var removedPaths: [String] = []
        for path in paths.sorted() {
            let url = URL(fileURLWithPath: path)
            guard isRegularFile(url) else {
                removedPaths.append(path)
                continue
            }
            switch provider {
            case .claudeCode:
                var seenRecordIdentifiers = Set<String>()
                inputs.append(scanClaudeInput(at: url, sessionTokens: &sessionTokens, seenRecordIdentifiers: &seenRecordIdentifiers))
            case .codex:
                inputs.append(scanCodexInput(at: url, sessionTokens: &sessionTokens))
            case .openCode:
                inputs.append(OpenCodeScanner().scanInput(at: url, sessionTokens: &sessionTokens))
            }
        }
        return InputScanBatch(provider: provider, inputs: inputs, removedPaths: removedPaths, sessionTokens: sessionTokens)
    }

    private func scanProvider(
        _ provider: UsageProvider,
        root: URL?,
        sessionTokens: inout InMemorySessionTokens,
        now: Date
    ) -> ProviderScan {
        switch provider {
        case .claudeCode:
            scanClaude(root: root, sessionTokens: &sessionTokens, now: now)
        case .codex:
            scanCodex(root: root, sessionTokens: &sessionTokens, now: now)
        case .openCode:
            OpenCodeScanner().scanDetailed(root: root, sessionTokens: &sessionTokens, now: now)
        }
    }

    private func scanClaude(
        root: URL?,
        sessionTokens: inout InMemorySessionTokens,
        now: Date
    ) -> ProviderScan {
        guard let root else {
            return ProviderScan(provider: .claudeCode, source: .unconfigured(.claudeCode), inputs: [])
        }
        var source = SourceHealth.unconfigured(.claudeCode)
        let directory = root.appendingPathComponent(UsageProvider.claudeCode.expectedRelativeDirectory, isDirectory: true)
        guard directoryExists(directory) else {
            source.state = .missingExpectedDirectory
            source.lastRefresh = now
            return ProviderScan(provider: .claudeCode, source: source, inputs: [])
        }

        source.state = .ready
        var seenRecordIdentifiers = Set<String>()
        var inputs: [InputScan] = []

        for url in jsonlFiles(in: directory) {
            let input = scanClaudeInput(at: url, sessionTokens: &sessionTokens, seenRecordIdentifiers: &seenRecordIdentifiers)
            inputs.append(input)
            merge(input, into: &source)
        }

        source.lastRefresh = now
        return ProviderScan(provider: .claudeCode, source: source, inputs: inputs)
    }

    private func scanClaudeInput(
        at url: URL,
        sessionTokens: inout InMemorySessionTokens,
        seenRecordIdentifiers: inout Set<String>
    ) -> InputScan {
        var events: [UsageEvent] = []
        var source = SourceHealth.unconfigured(.claudeCode)
        do {
            try scanClaudeFile(
                at: url,
                events: &events,
                sessionTokens: &sessionTokens,
                seenRecordIdentifiers: &seenRecordIdentifiers,
                source: &source
            )
            return InputScan(
                provider: .claudeCode,
                path: url.path,
                events: events,
                malformedLines: source.malformedLines,
                unreadable: false
            )
        } catch {
            return InputScan(provider: .claudeCode, path: url.path, events: [], malformedLines: 0, unreadable: true)
        }
    }

    private func scanClaudeFile(
        at url: URL,
        events: inout [UsageEvent],
        sessionTokens: inout InMemorySessionTokens,
        seenRecordIdentifiers: inout Set<String>,
        source: inout SourceHealth
    ) throws {
        let decoder = JSONDecoder()
        let timestampParser = TimestampParser()
        try streamLines(in: url) { line in
            guard let record = try? decoder.decode(ClaudeRecord.self, from: line) else {
                source.malformedLines += 1
                return
            }
            guard record.type == "assistant", let message = record.message, let usage = message.usage else { return }
            // Claude Code logs synthetic/system-generated assistant events with a "<synthetic>" model
            // and all-zero usage. They carry no real token usage, so skip them to avoid noise.
            if message.model == "<synthetic>" { return }
            guard let timestamp = timestampParser.parse(record.timestamp) else {
                source.malformedLines += 1
                return
            }

            let recordIdentifier = record.uuid ?? "\(record.sessionId ?? "missing")|\(record.timestamp ?? "missing")|\(message.id ?? "missing")"
            guard seenRecordIdentifiers.insert(recordIdentifier).inserted else { return }

            let sessionIdentifier = record.sessionId ?? recordIdentifier
            let sessionToken = sessionTokens.token(for: .claudeCode, identifier: sessionIdentifier)

            let tokenUsage = TokenUsage(
                input: usage.inputTokens ?? 0,
                output: usage.outputTokens ?? 0,
                cacheRead: usage.cacheReadInputTokens ?? 0,
                cacheWrite: usage.cacheCreationInputTokens ?? 0,
                cacheWrite1h: usage.cacheCreation?.ephemeral1hInputTokens ?? 0
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
        sessionTokens: inout InMemorySessionTokens,
        now: Date
    ) -> ProviderScan {
        guard let root else {
            return ProviderScan(provider: .codex, source: .unconfigured(.codex), inputs: [])
        }
        var source = SourceHealth.unconfigured(.codex)
        let directory = root.appendingPathComponent(UsageProvider.codex.expectedRelativeDirectory, isDirectory: true)
        guard directoryExists(directory) else {
            source.state = .missingExpectedDirectory
            source.lastRefresh = now
            return ProviderScan(provider: .codex, source: source, inputs: [])
        }

        source.state = .ready
        var inputs: [InputScan] = []
        for url in jsonlFiles(in: directory) {
            let input = scanCodexInput(at: url, sessionTokens: &sessionTokens)
            inputs.append(input)
            merge(input, into: &source)
        }

        source.lastRefresh = now
        return ProviderScan(provider: .codex, source: source, inputs: inputs)
    }

    private func scanCodexInput(at url: URL, sessionTokens: inout InMemorySessionTokens) -> InputScan {
        var events: [UsageEvent] = []
        var source = SourceHealth.unconfigured(.codex)
        let sessionToken = sessionTokens.token(for: .codex, identifier: url.path)
        do {
            try scanCodexFile(at: url, sessionToken: sessionToken, events: &events, source: &source)
            return InputScan(
                provider: .codex,
                path: url.path,
                events: events,
                malformedLines: source.malformedLines,
                unreadable: false
            )
        } catch {
            return InputScan(provider: .codex, path: url.path, events: [], malformedLines: 0, unreadable: true)
        }
    }

    private func scanCodexFile(
        at url: URL,
        sessionToken: UUID,
        events: inout [UsageEvent],
        source: inout SourceHealth
    ) throws {
        let decoder = JSONDecoder()
        let timestampParser = TimestampParser()
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
            guard let timestamp = timestampParser.parse(record.timestamp) else {
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

            guard let contribution, contribution.recordedTotal > 0, !isIgnoredCodexModel(model) else { return }
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

    private func isIgnoredCodexModel(_ model: String?) -> Bool {
        guard let model, !model.isEmpty else { return false }
        if model == "codex-auto-review" { return false }
        return !model.lowercased().contains("gpt")
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
        // Codex's `input_tokens` is the total input and already includes
        // `cached_input_tokens` (total_tokens == input_tokens + output_tokens).
        // TokenUsage keeps `input` and `cacheRead` as non-overlapping buckets
        // (the Claude convention), so move the cached portion out of `input`.
        // Without this, cached tokens are double-counted in both cost and the
        // cache-read-share denominator.
        let cached = info.cachedInputTokens ?? 0
        return TokenUsage(
            input: max((info.inputTokens ?? 0) - cached, 0),
            output: info.outputTokens ?? 0,
            cacheRead: cached,
            reasoningOutput: info.reasoningOutputTokens ?? 0,
            recordedTotal: info.totalTokens
        )
    }

    private func merge(_ input: InputScan, into source: inout SourceHealth) {
        source.scannedFiles += 1
        source.usageRecords += input.events.count
        source.malformedLines += input.malformedLines
        if input.unreadable { source.unreadableFiles += 1 }
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
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
}

private struct TimestampParser {
    private let fractional: ISO8601DateFormatter
    private let standard: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
    }

    func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractional.date(from: value) ?? standard.date(from: value)
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
    let cacheCreation: ClaudeCacheCreation?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheCreation = "cache_creation"
    }
}

private struct ClaudeCacheCreation: Decodable {
    let ephemeral1hInputTokens: Int?
    let ephemeral5mInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
        case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
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
