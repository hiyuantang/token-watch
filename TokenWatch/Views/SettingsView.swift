import SwiftUI

struct TokenWatchSettingsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Form {
            Section("Local data access") {
                ForEach(UsageProvider.allCases) { provider in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(provider.displayName)
                            Text("Select \(provider.selectedFolderName) containing \(provider.expectedRelativeDirectory)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Choose Folder") { store.chooseFolder(for: provider) }
                    }
                }
            }

            Section("Refresh") {
                Text("Token Watch reads selected local folders on launch, when opened, on manual refresh, and every 60 seconds while running.")
                    .foregroundStyle(.secondary)
            }

            Section("Privacy and status") {
                Text("This app has no network entitlement and makes no provider requests. It keeps only folder bookmarks and interface preferences; observed token metadata is rebuilt in memory from local files.")
                Text("Token Watch is not affiliated with or endorsed by Anthropic or OpenAI. Recorded tokens are not an official provider quota, invoice, or account balance.")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 620)
    }
}
