import Foundation

/// IPC client: connects to the sentinel socket, sends messages, receives responses.
public final class IPCClient: @unchecked Sendable {
    private let socketPath: String
    private var fileDescriptor: Int32
    private var receiveBuffer = Data()
    private let sendLock = NSLock()
    private let receiveLock = NSLock()
    private let closeLock = NSLock()

    public init(socketPath: String = AppConfig.socketPath) throws {
        self.socketPath = socketPath

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCError.socketCreationFailed(errno)
        }
        self.fileDescriptor = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw IPCError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw IPCError.connectionFailed(errno)
        }

        try Self.configureSocket(fd)
    }

    init(fileDescriptor: Int32) throws {
        self.socketPath = ""
        self.fileDescriptor = fileDescriptor
        try Self.configureSocket(fileDescriptor)
    }

    deinit {
        closeConnection()
    }

    /// Send a message to the server.
    public func send(_ message: IPCMessage) throws {
        let frame = try IPCFraming.encode(message)
        sendLock.lock()
        defer { sendLock.unlock() }

        let fd = currentFileDescriptor()
        guard fd >= 0 else {
            throw IPCError.connectionClosed
        }

        try frame.withUnsafeBytes { buffer in
            var totalSent = 0
            while totalSent < buffer.count {
                let sent = Darwin.send(
                    fd,
                    buffer.baseAddress!.advanced(by: totalSent),
                    buffer.count - totalSent,
                    0
                )
                if sent < 0, errno == EINTR {
                    continue
                }
                guard sent > 0 else {
                    if errno == EPIPE || errno == ECONNRESET {
                        throw IPCError.connectionClosed
                    }
                    throw IPCError.sendFailed(errno)
                }
                totalSent += sent
            }
        }
    }

    /// Receive a single message from the server.
    public func receive() throws -> IPCMessage {
        receiveLock.lock()
        defer { receiveLock.unlock() }

        let chunkSize = 4096
        let chunk = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 1)
        defer { chunk.deallocate() }

        while true {
            if let (message, consumed) = try IPCFraming.decode(from: receiveBuffer) {
                receiveBuffer.removeFirst(consumed)
                return message
            }

            let fd = currentFileDescriptor()
            guard fd >= 0 else {
                throw IPCError.connectionClosed
            }

            let bytesRead = recv(fd, chunk, chunkSize, 0)
            if bytesRead < 0, errno == EINTR {
                continue
            }
            guard bytesRead > 0 else {
                throw IPCError.connectionClosed
            }
            receiveBuffer.append(chunk.assumingMemoryBound(to: UInt8.self), count: bytesRead)
        }
    }

    public func closeConnection() {
        closeLock.lock()
        defer { closeLock.unlock() }
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func currentFileDescriptor() -> Int32 {
        closeLock.lock()
        defer { closeLock.unlock() }
        return fileDescriptor
    }

    private static func configureSocket(_ fd: Int32) throws {
        var noSigPipe: Int32 = 1
        let result = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        )
        guard result == 0 else {
            throw IPCError.socketConfigurationFailed(errno)
        }
    }
}

public enum IPCError: Error, Sendable {
    case socketCreationFailed(Int32)
    case socketConfigurationFailed(Int32)
    case pathTooLong
    case connectionFailed(Int32)
    case sendFailed(Int32)
    case connectionClosed
    case bindFailed(Int32)
    case listenFailed(Int32)
    case acceptFailed(Int32)
    case decodingFailed
}
