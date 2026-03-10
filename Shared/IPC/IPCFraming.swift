import Foundation

/// Wire format: 4 bytes UInt32 big-endian length prefix + UTF-8 JSON body.
public enum IPCFraming {

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
        let lengthBytes = buffer.subdata(in: start..<start + 4)
        let length = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let totalSize = 4 + Int(length)

        guard buffer.count >= totalSize else { return nil }

        let jsonData = buffer.subdata(in: start + 4..<start + totalSize)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(IPCMessage.self, from: jsonData)
        return (message, totalSize)
    }
}
