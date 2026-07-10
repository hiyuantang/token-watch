import Foundation

enum TokenFormatting {
    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0 ... 1)))
    }

    static func full(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    static func percentage(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Compact USD currency. Values under $0.01 show fractional cents so small
    /// per-event costs do not round to $0.00 in the UI.
    static func usd(_ value: Double) -> String {
        if value < 0.01 {
            return value.formatted(.currency(code: "USD").precision(.fractionLength(0 ... 4)))
        }
        return value.formatted(.currency(code: "USD").notation(.compactName).precision(.fractionLength(0 ... 2)))
    }
}
