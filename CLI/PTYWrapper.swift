import Foundation

/// PTY wrapper using forkpty to create a pseudo-terminal and exec a command.
/// Provides an AsyncStream of output data from the child process.
public final class PTYWrapper: @unchecked Sendable {
    public let masterFD: Int32
    public let childPID: pid_t
    private var isRunning = true
    private var originalTermios: termios?

    /// Create a PTY wrapper that forks and execs the given command.
    /// Copies the current terminal's size and settings to the child PTY.
    public init(command: String, arguments: [String], environment: [String: String]? = nil) throws {
        // Pre-allocate ALL C strings BEFORE fork.
        let cCommand = strdup(command)!
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: arguments.count + 1)
        for (i, arg) in arguments.enumerated() {
            argv[i] = strdup(arg)
        }
        argv[arguments.count] = nil

        var envPairs: [(key: UnsafeMutablePointer<CChar>, value: UnsafeMutablePointer<CChar>)] = []
        if let env = environment {
            envPairs = env.map { (strdup($0.key)!, strdup($0.value)!) }
        }

        // Capture current terminal size and settings
        var winSize = winsize()
        var hasWinSize = false
        if ioctl(STDIN_FILENO, TIOCGWINSZ, &winSize) == 0 {
            hasWinSize = true
        }

        var childTermios = termios()
        var hasTermios = false
        if tcgetattr(STDIN_FILENO, &childTermios) == 0 {
            hasTermios = true
        }

        var masterFD: Int32 = 0
        let pid: pid_t
        if hasTermios && hasWinSize {
            pid = forkpty(&masterFD, nil, &childTermios, &winSize)
        } else if hasTermios {
            pid = forkpty(&masterFD, nil, &childTermios, nil)
        } else if hasWinSize {
            pid = forkpty(&masterFD, nil, nil, &winSize)
        } else {
            pid = forkpty(&masterFD, nil, nil, nil)
        }

        guard pid >= 0 else {
            free(cCommand)
            for i in 0..<arguments.count { free(argv[i]) }
            argv.deallocate()
            for pair in envPairs { free(pair.key); free(pair.value) }
            throw PTYError.forkFailed(errno)
        }

        if pid == 0 {
            // Child process — only POSIX calls, no Swift runtime
            for pair in envPairs {
                setenv(pair.key, pair.value, 1)
            }
            execvp(cCommand, argv)
            perror("execvp")
            _exit(127)
        }

        // Parent process — clean up C allocations
        free(cCommand)
        for i in 0..<arguments.count { free(argv[i]) }
        argv.deallocate()
        for pair in envPairs { free(pair.key); free(pair.value) }

        self.masterFD = masterFD
        self.childPID = pid

        // Set up SIGWINCH forwarding
        Self.setupWinchHandler(masterFD: masterFD)
    }

    /// Put the real terminal into raw mode so keystrokes pass through directly.
    /// Returns the original termios for restoration later.
    public func enableRawMode() -> termios? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        self.originalTermios = original

        var raw = original
        // Disable canonical mode, echo, and signal processing
        raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG | IEXTEN)
        // Disable input processing
        raw.c_iflag &= ~UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        // Disable output processing
        raw.c_oflag &= ~UInt(OPOST)
        // Read returns after 1 byte, no timeout
        raw.c_cc.16 = 1  // VMIN
        raw.c_cc.17 = 0  // VTIME

        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        return original
    }

    /// Restore the original terminal settings.
    public func restoreTerminal() {
        if var original = originalTermios {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        }
    }

    /// Async stream of data chunks from the PTY master.
    public func outputStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            Task.detached { [masterFD, weak self] in
                let bufferSize = 4096
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
                defer { buffer.deallocate() }

                while self?.isRunning == true {
                    let bytesRead = read(masterFD, buffer, bufferSize)
                    if bytesRead > 0 {
                        let data = Data(bytes: buffer, count: bytesRead)
                        continuation.yield(data)
                    } else {
                        break
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Wait for the child process to exit and return its exit code.
    public func waitForExit() -> Int32 {
        var status: Int32 = 0
        waitpid(childPID, &status, 0)
        isRunning = false
        close(masterFD)

        if status & 0x7f == 0 {
            return (status >> 8) & 0xff
        } else {
            return -(status & 0x7f)
        }
    }

    /// Write data to the PTY (for passing input to the child).
    public func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            _ = Darwin.write(masterFD, buffer.baseAddress!, buffer.count)
        }
    }

    // MARK: - SIGWINCH

    // Global storage for the master FD so the signal handler can access it
    private static var activeMasterFD: Int32 = -1

    private static func setupWinchHandler(masterFD: Int32) {
        Self.activeMasterFD = masterFD

        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in
            // Forward terminal size change to the PTY
            var ws = winsize()
            if ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0 {
                _ = ioctl(PTYWrapper.activeMasterFD, TIOCSWINSZ, &ws)
            }
        }
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(SIGWINCH, &action, nil)
    }
}

public enum PTYError: Error, Sendable {
    case forkFailed(Int32)
}
