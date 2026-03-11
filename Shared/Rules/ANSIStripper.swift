import Foundation

/// Strips ANSI escape sequences from terminal output.
public struct ANSIStripper: Sendable {

    // Pre-compiled regex patterns for ANSI escape sequences
    private static let patterns: [(label: String, regex: NSRegularExpression)] = {
        let defs: [(String, String)] = [
            // CSI sequences: ESC [ ... final_byte
            ("CSI", "\u{1b}\\[[0-?]*[ -/]*[@-~]"),
            // OSC sequences: ESC ] ... BEL or ESC ] ... ST
            ("OSC_BEL", "\u{1b}\\][^\u{07}]*\u{07}"),
            ("OSC_ST", "\u{1b}\\][^\u{1b}]*\u{1b}\\\\"),
            // Charset designations: ESC ( B, ESC ) 0, etc.
            ("Charset", "\u{1b}[()][AB012]"),
            // Simple two-byte escapes: ESC followed by a single char
            ("TwoByte", "\u{1b}[^\\[\\]()0-9]"),
            // Standalone control characters (BEL, BS, etc.) except newline/tab
            ("Control", "[\u{00}-\u{08}\u{0b}\u{0c}\u{0e}-\u{1f}\u{7f}"),
        ]
        return defs.compactMap { label, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (label, regex)
        }
    }()

    public init() {}

    /// Strip all ANSI escape sequences from the given string.
    public func strip(_ input: String) -> String {
        var result = input as NSString

        for (_, regex) in Self.patterns {
            let range = NSRange(location: 0, length: result.length)
            result = regex.stringByReplacingMatches(
                in: result as String,
                range: range,
                withTemplate: ""
            ) as NSString
        }

        return result as String
    }

    /// Strip and split into lines.
    public func stripToLines(_ input: String) -> [String] {
        strip(input)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .init(charactersIn: "\r")) }
    }
}
