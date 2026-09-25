// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContextDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ContextDesk", targets: ["ContextDesk"]),
        .executable(name: "context-probe", targets: ["ContextProbe"])
    ],
    dependencies: [.package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ContextCore", dependencies: ["CSQLite", "TOMLDecoder"]),
        .target(name: "ContextTranscript", dependencies: ["ContextCore"]),
        .executableTarget(name: "ContextDesk", dependencies: ["ContextCore", "ContextTranscript"]),
        .executableTarget(name: "ContextProbe", dependencies: ["ContextCore"]),
        .testTarget(name: "ContextCoreTests", dependencies: ["ContextCore", "ContextTranscript", "ContextDesk"])
    ]
)
