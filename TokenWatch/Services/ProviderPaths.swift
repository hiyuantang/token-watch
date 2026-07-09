import Foundation

enum ProviderPaths {
    static func claudeRoot() -> URL? {
        URL(filePath: NSHomeDirectory()).appendingPathComponent(".claude", isDirectory: true)
    }

    static func codexRoot() -> URL? {
        URL(filePath: NSHomeDirectory()).appendingPathComponent(".codex", isDirectory: true)
    }

    static func openCodeRoot() -> URL? {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            URL(fileURLWithPath: xdg).appendingPathComponent("opencode", isDirectory: true)
        } else {
            URL(filePath: NSHomeDirectory())
                .appendingPathComponent(".local/share/opencode", isDirectory: true)
        }
    }

    static func root(for provider: UsageProvider) -> URL? {
        switch provider {
        case .claudeCode: claudeRoot()
        case .codex: codexRoot()
        case .openCode: openCodeRoot()
        }
    }
}