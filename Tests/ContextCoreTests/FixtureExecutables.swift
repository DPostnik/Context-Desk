import Foundation

/// Real interpreter for fixture scripts. `/usr/bin/python3` is an xcrun shim;
/// under a fully parallel run its exec chain can stall for longer than the
/// adapters' fixed process deadlines, so fixtures bypass it.
let fixturePython: String = {
    let shim = "/usr/bin/python3", process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: shim)
    process.arguments = ["-c", "import sys; print(sys.executable)"]
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return shim }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    // A shebang cannot contain spaces; keep the shim if the path is unusable.
    guard process.terminationStatus == 0, path.hasPrefix("/"), !path.contains(" "),
          FileManager.default.isExecutableFile(atPath: path) else { return shim }
    return path
}()

private let fixtureLauncher: URL = {
    let launcher = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fixture-launcher")
    // Fixtures are symlinks to this shared file; a stray write must not alter it.
    try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: launcher.path)
    return launcher
}()

/// Makes the script just written at `url` runnable without executing a new file:
/// the script moves to `<url>.fixture` and `url` becomes a symlink to the shared,
/// already-assessed launcher, which runs it with its shebang interpreter.
func installFixtureExecutable(at url: URL) throws {
    let script = url.appendingPathExtension("fixture")
    try? FileManager.default.removeItem(at: script)
    try FileManager.default.moveItem(at: url, to: script)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: fixtureLauncher)
}
