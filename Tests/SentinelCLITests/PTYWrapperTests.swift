import XCTest
@testable import SentinelCLI

final class PTYWrapperTests: XCTestCase {
    func testWriteAllRetriesPartialWritesAndInterruptedCalls() throws {
        let expected = Data("hello".utf8)
        var captured = Data()
        var callCount = 0

        try PTYWrapper.writeAll(to: 123, data: expected) { _, buffer, count in
            callCount += 1
            if callCount == 1 {
                errno = EINTR
                return -1
            }

            let chunkSize = min(2, count)
            captured.append(buffer.assumingMemoryBound(to: UInt8.self), count: chunkSize)
            return chunkSize
        }

        XCTAssertEqual(captured, expected)
        XCTAssertGreaterThanOrEqual(callCount, 3)
    }
}
