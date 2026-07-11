import SwiftUI

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String?
    let symbol: String
    let tint: Color

    init(
        title: String,
        value: String,
        detail: String? = nil,
        symbol: String,
        tint: Color
    ) {
        self.title = title
        self.value = value
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title2.weight(.semibold))
                .contentTransition(.numericText())

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .tint(tint)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}
