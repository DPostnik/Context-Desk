import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
import ContextCore

private func jpegFixture() throws -> Data {
    let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}
private func photoCommand(_ photos: [RemotePhoto], kind: String = "send") -> RemoteCommand {
    RemoteCommand(owner: UUID().uuidString, device: UUID().uuidString, project: UUID().uuidString,
                  chat: "chat", kind: kind, photos: photos)
}
@Test func mobilePhotosValidateAndMaterializeWithoutOverwriting() throws {
    let data = try jpegFixture()
    let photo = RemotePhoto(data: data)
    let command = photoCommand([photo])
    try command.validate() // Sending a photo without a caption is valid.
    let decoded = try JSONDecoder().decode(RemoteCommand.self, from: JSONEncoder().encode(command))
    #expect(decoded.photos == [photo])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let prompt = try decoded.photoPrompt(directory: directory)
    let file = directory.appendingPathComponent(command.id).appendingPathComponent(photo.id.uuidString + ".jpg")
    #expect(prompt.contains(file.path))
    #expect(try Data(contentsOf: file) == data)
    #expect(throws: (any Error).self) { try command.photoPrompt(directory: directory) }
    #expect(try Data(contentsOf: file) == data)
}
@Test func mobilePhotosRejectInvalidOrExcessPayloadsAndKeepOldCommandsCompatible() throws {
    let photo = RemotePhoto(data: try jpegFixture())
    #expect(throws: RemoteFailure.self) { try photoCommand([photo], kind: "stop").validate() }
    #expect(throws: RemoteFailure.self) { try photoCommand([photo, photo]).validate() }
    #expect(throws: RemoteFailure.self) { try photoCommand((0..<5).map { _ in RemotePhoto(data: photo.data) }).validate() }
    #expect(throws: RemoteFailure.self) { try RemotePhoto(data: Data([0xff, 0xd8, 0xff, 0])).validate() }
    #expect(throws: RemoteFailure.self) { try RemotePhoto(data: Data(repeating: 0, count: RemotePhoto.maximumBytes + 1)).validate() }
    var old = photoCommand([]); old.text = "legacy"
    let bytes = try JSONEncoder().encode(old)
    #expect(!String(decoding: bytes, as: UTF8.self).contains("photos"))
    try JSONDecoder().decode(RemoteCommand.self, from: bytes).validate()
}
