import SwiftUI

struct TokenWatchSettingsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Form {
            Section("Refresh") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic refresh")
                        Text("Token Watch auto-discovers ~/.claude, ~/.codex, and ~/.local/share/opencode on launch and updates automatically when local transcript files change. Use Sync Now if anything looks out of date.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sync Now") { store.manualSync() }
                        .disabled(store.isRefreshing)
                }
            }

            Section("Privacy boundary") {
                Label("No network entitlement or network features", systemImage: "network.slash")
                Label("No prompts, responses, source files, paths, or session IDs are shown or persisted", systemImage: "lock")
                Label("No cost, quota, account, credential, or rate-limit tracking", systemImage: "nosign")
            }

            Section("Privacy and status") {
                Text("This app has no network entitlement and makes no provider requests. It keeps only interface preferences; observed token metadata is rebuilt in memory from local files.")
                Text("Token Watch is not affiliated with or endorsed by Anthropic, OpenAI, or OpenCode. Recorded tokens are not an official provider quota, invoice, or account balance.")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 620)
    }
}