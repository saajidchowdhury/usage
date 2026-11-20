import Foundation

public enum SpaceFormatter {
    private static let bytesPerGiB = 1_073_741_824.0

    public static func menuTitle(usedBytes: Int64, allocatedBytes: Int64) -> String {
        "\(gibibytes(usedBytes)) / \(gibibytes(allocatedBytes))"
    }

    public static func gibibytes(_ bytes: Int64) -> String {
        let value = Double(bytes)/bytesPerGiB
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }
}
