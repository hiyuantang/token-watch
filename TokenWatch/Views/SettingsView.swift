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
                Label("No account, credential, quota, or rate-limit tracking", systemImage: "nosign")
            }

            Section("Cost estimate") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Estimated cost is a local illustration only.")
                        .font(.callout)
                    Text("Token Watch multiplies observed token totals by a static, hand-maintained catalog of published API rates (see docs/pricing.md). It does not read account, billing, or quota data, and makes no network requests. Batch, peak/off-peak, fast-mode, data-residency, and write-premium pricing are not modeled. The estimate is not an invoice and may differ materially from your actual provider bill.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Privacy and status") {
                Text("This app has no network entitlement and makes no provider requests. It keeps only interface preferences; observed token metadata and the derived cost estimate are rebuilt in memory from local files.")
                Text("Token Watch is not affiliated with or endorsed by Anthropic, OpenAI, Z.ai, Moonshot, MiniMax, DeepSeek, or OpenCode. Recorded tokens and estimated costs are not an official provider quota, invoice, or account balance.")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 620)
    }
}