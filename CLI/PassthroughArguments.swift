import Foundation

enum PassthroughArguments {
    /// Remove only the leading passthrough separator added for wrapper syntax.
    /// Internal command args must keep their own `--` untouched.
    static func normalize(_ args: [String]) -> [String] {
        guard args.first == "--" else { return args }
        return Array(args.dropFirst())
    }
}
