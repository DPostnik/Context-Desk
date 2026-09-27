import Foundation
import Testing
@testable import ContextCore

@Test func fragmentedLargeHistoryIsScannedInLinearTime() throws {
    var buffer = JSONLineBuffer()
    let chunk = Data(repeating: 120, count: 1024)
    let started = ContinuousClock.now
    for _ in 0..<8192 { #expect(try buffer.append(chunk).isEmpty) }
    let lines = try buffer.append(Data("\nnext\npartial".utf8))
    #expect(lines.count == 2)
    #expect(lines[0] == Data(repeating: 120, count: 8 * 1024 * 1024))
    #expect(lines[1] == Data("next".utf8))
    #expect(try buffer.append(Data(" reply\n".utf8)) == [Data("partial reply".utf8)])
    // Generous bound: the former full-buffer rescans take minutes for this input.
    #expect(started.duration(to: .now) < .seconds(5))
}

@Test func lineBufferHandlesSlicesEmptyLinesAndSplitUnicode() throws {
    var buffer = JSONLineBuffer()
    let bytes = Data("xxПривет ✅\n\nlast\n".utf8).dropFirst(2)
    var lines: [Data] = []
    for index in bytes.indices { lines += try buffer.append(bytes[index...index]) }
    #expect(lines == [Data("Привет ✅".utf8), Data(), Data("last".utf8)])
    #expect(try buffer.append(Data()).isEmpty)
}

@Test func lineLimitAppliesToIndividualLinesAcrossChunks() throws {
    var buffer = JSONLineBuffer(maximumLineBytes: 4)
    #expect(try buffer.append(Data("1234\n1234\n12".utf8)).count == 2)
    #expect(throws: JSONLineBuffer.Failure.self) { try buffer.append(Data("345".utf8)) }
    var oversized = JSONLineBuffer(maximumLineBytes: 4)
    #expect(throws: JSONLineBuffer.Failure.self) { try oversized.append(Data("12345\n".utf8)) }
}
