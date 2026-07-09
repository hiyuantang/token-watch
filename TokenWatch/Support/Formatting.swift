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
}
