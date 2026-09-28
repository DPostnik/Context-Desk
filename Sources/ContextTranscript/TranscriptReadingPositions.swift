import Foundation

/// Reading positions survive transcript view recreation during history loading.
/// Session-only: no conversation content or position is written to disk.
@MainActor public final class TranscriptReadingPositions {
    static let session = TranscriptReadingPositions()

    enum Position {
        case end
        case anchor(itemID: String, character: Int, offset: CGFloat, fallbackY: CGFloat)
    }

    var values: [String: Position] = [:]

    public init() {}
}
