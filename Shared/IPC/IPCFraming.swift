import Foundation

/// Wire format: 4 bytes UInt32 big-endian length prefix + UTF-8 JSON body.
public enum IPCFraming {
    private static let maxFrameLength = 4 * 1024 * 1024 // 4MB

    /// Encode a message to wire format: [4-byte length][JSON data]
    public static func encode(_ message: IPCMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(message)

        var length = UInt32(json.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        return frame
    }

    /// Decode a message from a buffer. Returns the message and bytes consumed,
    /// or nil if the buffer doesn't contain a complete frame.
    public static func decode(from buffer: Data) throws -> (IPCMessage, Int)? {
        guard buffer.count >= 4 else { return nil }

        let start = buffer.startIndex
        let b0 = UInt32(buffer[start])
        let b1 = UInt32(buffer[start + 1])
        let b2 = UInt32(buffer[start + 2])
        let b3 = UInt32(buffer[start + 3])
        let length = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        guard length <= maxFrameLength else {
            throw IPCError.decodingFailed
        }
        let totalSize = 4 + Int(length)

        guard buffer.count >= totalSize else { return nil }

        let jsonData = buffer.subdata(in: start + 4..<start + totalSize)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(IPCMessage.self, from: jsonData)
        return (message, totalSize)
    }
}
