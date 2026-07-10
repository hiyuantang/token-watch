import Foundation

struct OpenCodeScanner: Sendable {
    func scan(root: URL?, now: Date = Date()) -> ScanResult {
        guard let root else { return ScanResult(events: [], sources: []) }
        var source = SourceHealth.unconfigured(.openCode)
        guard directoryExists(root) else {
            source.state = .missingExpectedDirectory
            source.lastRefresh = now
            return ScanResult(events: [], sources: [source])
        }

        var events: [UsageEvent] = []
        var sessionTokens: [String: UUID] = [:]

        let dbFiles = openCodeDbFiles(in: root)
        guard !dbFiles.isEmpty else {
            source.state = .missingExpectedDirectory
            source.lastRefresh = now
            return ScanResult(events: [], sources: [source])
        }

        source.state = .ready
        for url in dbFiles {
            source.scannedFiles += 1
            do {
                try scanDb(at: url, events: &events, sessionTokens: &sessionTokens, source: &source, now: now)
            } catch {
                source.unreadableFiles += 1
            }
        }

        source.lastRefresh = now
        return ScanResult(events: events.sorted { $0.timestamp < $1.timestamp }, sources: [source])
    }

    private func scanDb(
        at url: URL,
        events: inout [UsageEvent],
        sessionTokens: inout [String: UUID],
        source: inout SourceHealth,
        now: Date
    ) throws {
        let json = try runSqliteJson(at: url)
        guard let data = json.data(using: .utf8) else {
            source.unreadableFiles += 1
            return
        }
        let rows = (try? JSONDecoder().decode([OpenCodeSessionRow].self, from: data)) ?? []
        for row in rows {
            let model = decodeModelId(row.model) ?? {
                source.malformedLines += 1
                return "Unknown model"
            }()
            let sessionToken = sessionTokens[row.id] ?? UUID()
            sessionTokens[row.id] = sessionToken
            events.append(
                UsageEvent(
                    id: UUID(),
                    provider: .openCode,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(row.timeUpdated) / 1000),
                    model: model,
                    sessionToken: sessionToken,
                    usage: TokenUsage(
                        input: row.tokensInput,
                        output: row.tokensOutput,
                        cacheRead: row.tokensCacheRead,
                        cacheWrite: row.tokensCacheWrite,
                        reasoningOutput: row.tokensReasoning
                    )
                )
            )
            source.usageRecords += 1
        }
    }

    private func decodeModelId(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(OpenCodeModel.self, from: data),
              let id = parsed.id, !id.isEmpty
        else { return nil }
        return id
    }

    private func runSqliteJson(at url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-json",
            "-readonly",
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
        process.standardError = Pipe()
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
    let model: String
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
}