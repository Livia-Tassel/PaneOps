import XCTest
@testable import SentinelShared

final class IPCClientTests: XCTestCase {
    func testReceivePreservesBufferedFramesAcrossCalls() throws {
        let sockets = try makeSocketPair()
        let client = try IPCClient(fileDescriptor: sockets.0)
        defer { client.closeConnection() }
        defer { Darwin.close(sockets.1) }

        var frames = try IPCFraming.encode(.heartbeat(agentId: UUID()))
        frames.append(try IPCFraming.encode(.ack(messageId: UUID())))
        _ = frames.withUnsafeBytes { buffer in
            Darwin.write(sockets.1, buffer.baseAddress!, buffer.count)
        }
        _ = Darwin.shutdown(sockets.1, SHUT_WR)

        let first = try client.receive()
        let second = try client.receive()

        if case .heartbeat = first {} else { XCTFail("Expected heartbeat") }
        if case .ack = second {} else { XCTFail("Expected ack") }
    }

    func testSendThrowsWhenPeerIsClosedInsteadOfCrashing() throws {
        let sockets = try makeSocketPair()
        let client = try IPCClient(fileDescriptor: sockets.0)
        defer { client.closeConnection() }
        Darwin.close(sockets.1)

        XCTAssertThrowsError(try client.send(.heartbeat(agentId: UUID()))) { error in
            guard case IPCError.connectionClosed = error else {
                return XCTFail("Expected connectionClosed, got \(error)")
            }
        }
    }

    func testServerConnectionSendThrowsWhenPeerIsClosedInsteadOfCrashing() throws {
        let sockets = try makeSocketPair()
        let connection = IPCServer.ClientConnection(fd: sockets.0)
        defer { connection.close() }
        Darwin.close(sockets.1)

        XCTAssertThrowsError(try connection.send(.heartbeat(agentId: UUID()))) { error in
            guard case IPCError.connectionClosed = error else {
                return XCTFail("Expected connectionClosed, got \(error)")
            }
        }
    }

    private func makeSocketPair() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors)
        guard result == 0 else {
            throw POSIXError(.EIO)
        }
        return (descriptors[0], descriptors[1])
    }
}
