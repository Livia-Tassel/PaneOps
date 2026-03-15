import Foundation

/// Stateful UTF-8 chunk decoder that handles incomplete multi-byte sequences
/// arriving across chunk boundaries.
///
/// PTY output arrives as arbitrary byte chunks that may split UTF-8 sequences
/// mid-character (e.g., the 3-byte `❯` split into a 1-byte chunk + 2-byte chunk).
/// This decoder buffers trailing incomplete bytes and prepends them to the next chunk.
struct UTF8ChunkDecoder {
    /// Bytes from the previous chunk that form an incomplete UTF-8 sequence.
    private var pendingBytes = Data()

    /// Decode a chunk of raw bytes into a string, buffering any trailing incomplete sequence.
    /// Returns the decoded text and normalizes line endings (\r\n and \r → \n).
    mutating func decode(_ data: Data) -> String {
        let (text, pending) = decodeRaw(data)
        pendingBytes = pending
        return normalizeLineEndings(text)
    }

    /// Flush any remaining pending bytes as a lossy UTF-8 string.
    /// Call when the PTY closes to avoid losing trailing content.
    mutating func flush() -> String {
        guard !pendingBytes.isEmpty else { return "" }
        let text = String(decoding: pendingBytes, as: UTF8.self)
        pendingBytes.removeAll(keepingCapacity: false)
        return text
    }

    /// Whether there are buffered bytes awaiting completion.
    var hasPendingBytes: Bool {
        !pendingBytes.isEmpty
    }

    // MARK: - Private

    private func decodeRaw(_ data: Data) -> (String, Data) {
        var combined = pendingBytes
        combined.append(data)

        if let text = String(data: combined, encoding: .utf8) {
            return (text, Data())
        }

        let maxTailBytes = min(3, combined.count)
        for tailCount in 1...maxTailBytes {
            let prefix = combined.dropLast(tailCount)
            if let text = String(data: prefix, encoding: .utf8) {
                return (text, Data(combined.suffix(tailCount)))
            }
        }

        if combined.count <= 4 {
            return ("", combined)
        }

        return (String(decoding: combined, as: UTF8.self), Data())
    }

    private func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
