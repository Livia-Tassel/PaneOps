import os

/// Centralized logging using os.Logger with subsystem categories.
public enum SentinelLogger {
    private static let subsystem = "com.paneops.agent-sentinel"

    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let monitor = Logger(subsystem: subsystem, category: "monitor")
    public static let tmux = Logger(subsystem: subsystem, category: "tmux")
    public static let rules = Logger(subsystem: subsystem, category: "rules")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let ipc = Logger(subsystem: subsystem, category: "ipc")
}
