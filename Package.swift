// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoBooth",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PTPKit", targets: ["PTPKit"]),
        .library(name: "SonyCamera", targets: ["SonyCamera"]),
        .library(name: "Uploader", targets: ["Uploader"]),
        .executable(name: "PhotoBooth", targets: ["PhotoBooth"]),
        .executable(name: "booth-spike", targets: ["BoothSpike"]),
    ],
    targets: [
        // Pure protocol code: no ImageCaptureCore, fully unit-testable.
        .target(name: "PTPKit"),
        // ImageCaptureCore transport, Sony session, and the BoothCamera implementation.
        .target(name: "SonyCamera", dependencies: ["PTPKit"]),
        // Local save, persistent upload queue, Google OAuth + Photos Library client.
        .target(name: "Uploader"),
        // Booth logic (state machine, config, key map, fake camera, scenarios): no AppKit/SwiftUI.
        .target(name: "BoothCore", dependencies: ["SonyCamera"]),
        // The SwiftUI booth app.
        .executableTarget(name: "PhotoBooth", dependencies: ["BoothCore", "SonyCamera", "Uploader"]),
        // Phase 0 spike CLI.
        .executableTarget(name: "BoothSpike", dependencies: ["SonyCamera", "PTPKit"]),
        .testTarget(name: "PTPKitTests", dependencies: ["PTPKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SonyCameraTests", dependencies: ["SonyCamera", "PTPKit"]),
        .testTarget(name: "BoothCoreTests", dependencies: ["BoothCore"], path: "Tests/PhotoBoothTests"),
        .testTarget(name: "UploaderTests", dependencies: ["Uploader"]),
    ],
    swiftLanguageModes: [.v5]
)
