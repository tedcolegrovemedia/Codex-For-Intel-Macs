// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexIntelApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "CodexIntelApp",
            targets: ["CodexIntelApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "CodexIntelApp"
        )
    ]
)
