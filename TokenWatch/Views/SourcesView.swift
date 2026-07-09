import SwiftUI

struct SourcesView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        List {
            Section {
                Text("Choose each tool’s local data folder. Access is read-only, revocable, and scoped to the folder you select.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(UsageProvider.allCases) { provider in
                let source = sourceHealth(for: provider)
                SourceRow(
                    provider: provider,
                    source: source,
                    hasSelectedFolder: FolderAccessStore.url(for: provider) != nil,
                    chooseFolder: { store.chooseFolder(for: provider) },
                    revokeFolder: { store.revokeFolder(for: provider) }
                )
            }

            Section("Privacy boundary") {
                Label("No network entitlement or network features", systemImage: "network.slash")
                Label("No prompts, responses, source files, paths, or session IDs are shown or persisted", systemImage: "lock")
                Label("No cost, quota, account, credential, or rate-limit tracking", systemImage: "nosign")
            }

            if let message = store.lastMessage {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Sources")
    }

    private func sourceHealth(for provider: UsageProvider) -> SourceHealth {
        store.sources.first { $0.provider == provider } ?? .unconfigured(provider)
    }
}

private struct SourceRow: View {
    let provider: UsageProvider
    let source: SourceHealth
    let hasSelectedFolder: Bool
    let chooseFolder: () -> Void
    let revokeFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.displayName)
                        .font(.headline)
                    Text(source.state.displayName)
                        .font(.subheadline)
                        .foregroundStyle(source.state == .ready ? .green : .secondary)
                }
                Spacer()
                Button("Choose Folder", action: chooseFolder)
            }

            if hasSelectedFolder {
                HStack(spacing: 14) {
                    Text("\(source.scannedFiles) files")
                    Text("\(source.usageRecords) usage records")
                    if source.malformedLines > 0 || source.unreadableFiles > 0 {
                        Text("\(source.malformedLines + source.unreadableFiles) parsing issues")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Revoke Access", role: .destructive, action: revokeFolder)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}
