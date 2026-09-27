import Foundation

/// Scan each incoming byte once, even when a large history reply arrives in tiny chunks.
struct JSONLineBuffer {
    private var partial = Data()
    let maximumLineBytes: Int

    init(maximumLineBytes: Int = 32 * 1024 * 1024) {
        self.maximumLineBytes = maximumLineBytes
    }

    enum Failure: Error { case lineTooLarge }

    mutating func append(_ chunk: Data) throws -> [Data] {
        var lines: [Data] = []
        try chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var start = 0
            for index in bytes.indices where bytes[index] == 10 {
                try appendSegment(bytes[start..<index])
                lines.append(partial)
                partial = Data()
                start = index + 1
            }
            try appendSegment(bytes[start..<bytes.count])
        }
        return lines
    }

    private mutating func appendSegment(_ bytes: Slice<UnsafeRawBufferPointer>) throws {
        guard bytes.count <= maximumLineBytes - partial.count else { throw Failure.lineTooLarge }
        partial.append(contentsOf: bytes)
    }
}
