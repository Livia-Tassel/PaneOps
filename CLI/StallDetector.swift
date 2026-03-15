import Foundation
import SentinelShared

/// Detects agent inactivity by monitoring elapsed time since last output or input.
///
/// When no `reset()` call arrives within `timeout` seconds, fires `onStall` once.
/// Subsequent timeouts are suppressed until `reset()` is called again
/// (i.e., new output or user input must arrive to re-arm the detector).
///
/// Thread safety: `fired` is protected by `lock` since it is read/written from both
/// the caller context (reset/cancel) and the detached timer task.
final class StallDetector {
    private let timeout: TimeInterval
    private let onStall: @Sendable () -> Void
    private var timer: Task<Void, Never>?
    private let lock = NSLock()
    private var _fired = false

    private var fired: Bool {
        get { lock.withLock { _fired } }
        set { lock.withLock { _fired = newValue } }
    }

    init(timeout: TimeInterval, onStall: @escaping @Sendable () -> Void) {
        self.timeout = timeout
        self.onStall = onStall
        startTimer()
    }

    /// Reset the detector: cancel current timer, clear the fired flag, start a fresh timer.
    /// Call on every processData() and noteUserInput().
    func reset() {
        fired = false
        startTimer()
    }

    /// Cancel the timer permanently. Call from flush() when the PTY closes.
    func cancel() {
        timer?.cancel()
    }

    // MARK: - Private

    private func startTimer() {
        timer?.cancel()
        timer = Task.detached { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
            guard !Task.isCancelled, !self.fired else { return }
            self.fired = true
            self.onStall()
        }
    }
}
