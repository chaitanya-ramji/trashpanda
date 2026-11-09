// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TrashPanda",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "trashpanda", targets: ["TrashPanda"]),
        .library(name: "PandaCore", targets: ["PandaCore"]),
    ],
    targets: [
        .target(name: "PandaCore"),
        .executableTarget(name: "TrashPanda", dependencies: ["PandaCore"]),
        .testTarget(name: "PandaCoreTests", dependencies: ["PandaCore"],
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
