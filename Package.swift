// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallRecorder",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "ObjCCatch"),
        .executableTarget(name: "CallRecorder", dependencies: ["ObjCCatch"]),
    ],
    swiftLanguageModes: [.v5]
)
