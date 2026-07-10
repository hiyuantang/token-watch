import SwiftUI

struct ModelsView: View {
    let snapshot: UsageSnapshot

    private var totalRecorded: Int { snapshot.usage.recordedTotal }

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
                    let share = totalRecorded == 0
                        ? 0
                        : Double(model.usage.recordedTotal) / Double(totalRecorded)
                    HStack(spacing: 12) {
                        Image(systemName: model.provider == .claudeCode ? "sparkles" : (model.provider == .codex ? "terminal" : "curlybraces"))
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
                            HStack(spacing: 6) {
                                Text(TokenFormatting.compact(model.usage.recordedTotal))
                                    .monospacedDigit()
                                Text(TokenFormatting.percentage(share))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            HStack(spacing: 4) {
                                if model.priced {
                                    Text(TokenFormatting.usd(model.costUSD))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                } else {
                                    Text("unpriced")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text("· In \(TokenFormatting.compact(model.usage.input)) · Out \(TokenFormatting.compact(model.usage.output))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
