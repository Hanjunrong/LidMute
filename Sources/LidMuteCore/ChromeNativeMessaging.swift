import Foundation

public enum NativeMessageFramingError: Error, Equatable {
    case frameTooLarge(Int)
}

public final class NativeMessageFramer: @unchecked Sendable {
    private var buffer = Data()
    private let maxFrameBytes: Int

    public var bufferedByteCount: Int { buffer.count }

    public init(maxFrameBytes: Int = 262_144) {
        self.maxFrameBytes = maxFrameBytes
    }

    public func feed<S: DataProtocol>(_ bytes: S) throws -> [Data] {
        buffer.append(contentsOf: bytes)
        var frames: [Data] = []

        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes {
                Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
            }
            guard length <= maxFrameBytes else {
                throw NativeMessageFramingError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }

            frames.append(buffer.subdata(in: 4..<(4 + length)))
            buffer.removeSubrange(0..<(4 + length))
        }

        return frames
    }
}
