// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PianoLearning",
    defaultLocalization: "fr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PianoLearning", targets: ["PianoLearning"])
    ],
    targets: [
        .target(name: "PianoCore"),
        .executableTarget(name: "PianoLearning", dependencies: ["PianoCore"]),
        .testTarget(name: "PianoCoreTests", dependencies: ["PianoCore"], resources: [.copy("Fixtures")])
    ]
)
