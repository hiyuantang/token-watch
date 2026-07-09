import AppKit
import Foundation

@MainActor
enum FolderAccessStore {
    private static let defaults = UserDefaults.standard

    static func url(for provider: UsageProvider) -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey(for: provider)) else { return nil }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                try save(url, for: provider)
            }
            return url
        } catch {
            return nil
        }
    }

    static func save(_ url: URL, for provider: UsageProvider) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: bookmarkKey(for: provider))
    }

    static func remove(_ provider: UsageProvider) {
        defaults.removeObject(forKey: bookmarkKey(for: provider))
    }

    static func chooseFolder(for provider: UsageProvider) -> Result<URL, FolderAccessError> {
        let panel = NSOpenPanel()
        panel.title = "Choose your \(provider.selectedFolderName) folder"
        panel.message = "Token Watch will read only token metadata from \(provider.expectedRelativeDirectory)."
        panel.prompt = "Use Folder"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return .failure(.message("No folder was selected."))
        }

        let expectedDirectory = selectedURL.appendingPathComponent(provider.expectedRelativeDirectory, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expectedDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.message("Select a \(provider.selectedFolderName) folder containing \(provider.expectedRelativeDirectory)."))
        }

        do {
            try save(selectedURL, for: provider)
            return .success(selectedURL)
        } catch {
            return .failure(.message("Token Watch could not save access to that folder."))
        }
    }

    private static func bookmarkKey(for provider: UsageProvider) -> String {
        "TokenWatch.folderBookmark.\(provider.rawValue)"
    }
}

enum FolderAccessError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
