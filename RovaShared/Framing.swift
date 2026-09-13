import Foundation

public enum RovaFrameError: Error, Equatable {
    case tooLarge
    case invalidLength
}

public enum RovaFrameCodec {
    public static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= RovaValidation.maxFrameSize else { throw RovaFrameError.tooLarge }
        let length = UInt32(payload.count)
        var output = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff)
        ])
        output.append(payload)
        return output
    }

    public static func appendAndExtract(_ data: Data, from buffer: inout Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = (UInt32(buffer[start]) << 24)
                | (UInt32(buffer[start + 1]) << 16)
                | (UInt32(buffer[start + 2]) << 8)
                | UInt32(buffer[start + 3])
            guard length <= UInt32(RovaValidation.maxFrameSize) else { throw RovaFrameError.tooLarge }
            let total = 4 + Int(length)
            guard buffer.count >= total else { break }
            frames.append(buffer.subdata(in: (start + 4)..<(start + total)))
            buffer.removeSubrange(start..<(start + total))
        }
        return frames
    }
}

public enum RovaWireCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encode(_ envelope: WireEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try RovaFrameCodec.frame(encoder.encode(envelope))
    }

    public static func decode(_ payload: Data) throws -> WireEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WireEnvelope.self, from: payload)
    }
}
