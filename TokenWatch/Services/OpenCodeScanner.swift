import Foundation

struct OpenCodeScanner: Sendable {
    func scan(root: URL?, now: Date = Date()) -> ScanResult {
        guard root != nil else { return ScanResult(events: [], sources: []) }
        var sessionTokens = InMemorySessionTokens()
        let result = scanDetailed(root: root, sessionTokens: &sessionTokens, now: now)
        return ScanResult(events: result.inputs.flatMap(\.events).sorted { $0.timestamp < $1.timestamp }, sources: [result.source])
    }

    func scanDetailed(
        root: URL?,
        sessionTokens: inout InMemorySessionTokens,
        now: Date
    ) -> ProviderScan {
        guard let root else {
            return ProviderScan(provider: .openCode, source: .unconfigured(.openCode), inputs: [])
        }
        var source = SourceHealth.unconfigured(.openCode)
        guard directoryExists(root) else {
            source.state = .missingExpectedDirectory
            source.lastRefresh = now
            return ProviderScan(provider: .openCode, source: source, inputs: [])
        }

        let dbFiles = openCodeDbFiles(in: root)
        guard !dbFiles.isEmpty else {
            source.state = .missingExpectedDirectory
            source.lastRefresh = now
            return ProviderScan(provider: .openCode, source: source, inputs: [])
        }

        source.state = .ready
        var inputs: [InputScan] = []
        for url in dbFiles {
            let input = scanInput(at: url, sessionTokens: &sessionTokens)
            inputs.append(input)
            merge(input, into: &source)
        }
        if source.unreadableFiles == source.scannedFiles {
            source.state = .inaccessible
        }

        source.lastRefresh = now
        return ProviderScan(provider: .openCode, source: source, inputs: inputs)
    }

    func scanInput(at url: URL, sessionTokens: inout InMemorySessionTokens) -> InputScan {
        var events: [UsageEvent] = []
        var source = SourceHealth.unconfigured(.openCode)
        do {
            try scanDb(at: url, events: &events, sessionTokens: &sessionTokens, source: &source)
            return InputScan(
                provider: .openCode,
                path: url.path,
                events: events,
                malformedLines: source.malformedLines,
                unreadable: false
            )
        } catch {
            return InputScan(provider: .openCode, path: url.path, events: [], malformedLines: 0, unreadable: true)
        }
    }

    private func scanDb(
        at url: URL,
        events: inout [UsageEvent],
        sessionTokens: inout InMemorySessionTokens,
        source: inout SourceHealth
    ) throws {
        let json = try runSqliteJson(at: url)
        guard let data = json.data(using: .utf8) else { throw OpenCodeScannerError.unreadable }
        let rows = try JSONDecoder().decode([OpenCodeSessionRow].self, from: data)
        for row in rows {
            guard let modelJSON = row.model else { continue }
            let model = decodeModel(modelJSON)
            if model == nil { source.malformedLines += 1 }
            let sessionToken = sessionTokens.token(for: .openCode, identifier: row.id)
            events.append(
                UsageEvent(
                    id: UUID(),
                    provider: .openCode,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(row.timeUpdated) / 1000),
                    model: model?.id ?? "Unknown model",
                    sessionToken: sessionToken,
                    usage: TokenUsage(
                        input: row.tokensInput,
                        output: row.tokensOutput,
                        cacheRead: row.tokensCacheRead,
                        cacheWrite: row.tokensCacheWrite,
                        reasoningOutput: row.tokensReasoning
                    ),
                    openCodeProviderID: model?.providerID
                )
            )
            source.usageRecords += 1
        }
    }

    private func merge(_ input: InputScan, into source: inout SourceHealth) {
        source.scannedFiles += 1
        source.usageRecords += input.events.count
        source.malformedLines += input.malformedLines
        if input.unreadable { source.unreadableFiles += 1 }
    }

    private struct DecodedModel: Sendable {
        let id: String
        let providerID: String?
    }

    private func decodeModel(_ json: String) -> DecodedModel? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(OpenCodeModel.self, from: data),
              let id = parsed.id, !id.isEmpty
        else { return nil }
        return DecodedModel(id: id, providerID: parsed.providerID)
    }

    private func runSqliteJson(at url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-json",
            "-readonly",
            "-cmd",
            ".timeout 2000",
            url.path,
            """
            SELECT id, model, tokens_input, tokens_output, tokens_cache_read,
                   tokens_cache_write, tokens_reasoning, time_updated
            FROM session
            ORDER BY time_updated ASC
            """
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OpenCodeScannerError.unreadable
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func openCodeDbFiles(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard isOpenCodeDbFilename(url.lastPathComponent) else { continue }
            guard (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func isOpenCodeDbFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".db") else { return false }
        let stem = name.dropLast(3)
        if stem == "opencode" { return true }
        guard stem.hasPrefix("opencode-") else { return false }
        let channel = stem.dropFirst("opencode-".count)
        return !channel.isEmpty && channel.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
    }
}

private enum OpenCodeScannerError: Error {
    case unreadable
}

private struct OpenCodeSessionRow: Decodable {
    let id: String
    let model: String?
    let tokensInput: Int
    let tokensOutput: Int
    let tokensCacheRead: Int
    let tokensCacheWrite: Int
    let tokensReasoning: Int
    let timeUpdated: Int

    enum CodingKeys: String, CodingKey {
        case id
        case model
        case tokensInput = "tokens_input"
        case tokensOutput = "tokens_output"
        case tokensCacheRead = "tokens_cache_read"
        case tokensCacheWrite = "tokens_cache_write"
        case tokensReasoning = "tokens_reasoning"
        case timeUpdated = "time_updated"
    }
}

private struct OpenCodeModel: Decodable {
    let id: String?
    let providerID: String?
}
