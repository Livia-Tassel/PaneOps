import Foundation

/// IPC server: listens on Unix Domain Socket, accepts connections, dispatches messages.
public final class IPCServer: @unchecked Sendable {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private var isRunning = false
    private let handler: @Sendable (IPCMessage, ClientConnection) -> Void

    /// A connected client's file descriptor wrapper.
    public final class ClientConnection: @unchecked Sendable {
        public let fd: Int32
        private let sendLock = NSLock()

        init(fd: Int32) {
            self.fd = fd
        }

        public func send(_ message: IPCMessage) throws {
            let frame = try IPCFraming.encode(message)
            sendLock.lock()
            defer { sendLock.unlock() }

            try frame.withUnsafeBytes { buffer in
                var totalSent = 0
                while totalSent < buffer.count {
                    let sent = Darwin.send(fd, buffer.baseAddress!.advanced(by: totalSent),
                                           buffer.count - totalSent, 0)
                    guard sent > 0 else { throw IPCError.sendFailed(errno) }
                    totalSent += sent
                }
            }
        }

        func close() {
            Darwin.close(fd)
        }
    }

    public init(socketPath: String = AppConfig.socketPath,
                handler: @escaping @Sendable (IPCMessage, ClientConnection) -> Void) {
        self.socketPath = socketPath
        self.handler = handler
    }

    /// Start listening. Call from a background task.
    public func start() throws {
        // Remove stale socket
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socketCreationFailed(errno) }
        self.listenFD = fd

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

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw IPCError.bindFailed(errno)
        }

        // Socket permissions: user-only
        chmod(socketPath, 0o600)

        guard listen(fd, 8) == 0 else {
            close(fd)
            throw IPCError.listenFailed(errno)
        }

        isRunning = true
        SentinelLogger.ipc.info("IPC server listening on \(self.socketPath)")

        // Accept loop
        while isRunning {
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else {
                if !isRunning { break }
                SentinelLogger.ipc.warning("Accept failed: \(errno)")
                continue
            }

            let conn = ClientConnection(fd: clientFD)
            Task.detached { [handler] in
                await self.handleClient(conn, handler: handler)
            }
        }
    }

    /// Stop the server and clean up.
    public func stop() {
        isRunning = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
        SentinelLogger.ipc.info("IPC server stopped")
    }

    private func handleClient(_ conn: ClientConnection,
                              handler: @escaping @Sendable (IPCMessage, ClientConnection) -> Void) async {
        var buffer = Data()
        let chunkSize = 4096
        let chunk = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 1)
        defer {
            chunk.deallocate()
            conn.close()
        }

        while true {
            let bytesRead = recv(conn.fd, chunk, chunkSize, 0)
            guard bytesRead > 0 else { break }
            buffer.append(chunk.assumingMemoryBound(to: UInt8.self), count: bytesRead)

            // Process all complete frames in buffer
            while true {
                do {
                    guard let (message, consumed) = try IPCFraming.decode(from: buffer) else { break }
                    buffer.removeFirst(consumed)
                    handler(message, conn)
                } catch {
                    SentinelLogger.ipc.error("Frame decode error: \(error.localizedDescription)")
                    buffer.removeAll()
                    break
                }
            }
        }
    }
}
