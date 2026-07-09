import SwiftUI

struct ModelsView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        Group {
            if snapshot.models.isEmpty {
                ContentUnavailableView(
                    "No model metadata yet",
                    systemImage: "cpu",
                    description: Text("Model rankings appear after local usage records are read.")
                )
            } else {
                List(snapshot.models) { model in
                    HStack(spacing: 12) {
                        Image(systemName: model.provider == .claudeCode ? "sparkles" : "terminal")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.model)
                                .font(.body.weight(.medium))
                            Text(model.provider.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(TokenFormatting.compact(model.usage.recordedTotal))
                                .monospacedDigit()
                            Text("In \(TokenFormatting.compact(model.usage.input)) · Out \(TokenFormatting.compact(model.usage.output))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("Models")
    }
}
