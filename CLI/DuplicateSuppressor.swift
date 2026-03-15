import Foundation

/// Time-windowed line deduplication.
///
/// Tracks recently-seen lines by their first 120 characters (lowercased) and
/// suppresses identical lines arriving within a configurable window (default 1.2s).
/// The internal cache is bounded: entries are evicted when count exceeds 512
/// or during burst-mode cleanup.
struct DuplicateSuppressor {
    private var seenAt: [String: Date] = [:]
    private let windowSeconds: TimeInterval

    init(windowSeconds: TimeInterval = 1.2) {
        self.windowSeconds = windowSeconds
    }

    /// Returns true if the line should be suppressed (duplicate within window).
    /// Otherwise records the line and returns false.
    mutating func shouldSuppress(_ line: String, key: String) -> Bool {
        let now = Date()
        if let seen = seenAt[key], now.timeIntervalSince(seen) < windowSeconds {
            return true
        }
        seenAt[key] = now
        if seenAt.count > 512 {
            let threshold = now.addingTimeInterval(-5)
            seenAt = seenAt.filter { $0.value > threshold }
        }
        return false
    }

    /// Aggressively trim the cache during output bursts to control memory.
    mutating func trimForBurst() {
        guard seenAt.count > 256 else { return }
        let threshold = Date().addingTimeInterval(-2)
        seenAt = seenAt.filter { $0.value > threshold }
    }
}
