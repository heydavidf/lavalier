// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Lavalier",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lavalier", targets: ["Lavalier"]),
        .executable(name: "lavalier-cli", targets: ["lavalier-cli"]),
        .library(name: "LavalierCore", targets: ["LavalierCore"]),
    ],
    targets: [
        .target(name: "LavalierCore", path: "Sources/LavalierCore"),
        .executableTarget(name: "Lavalier", dependencies: ["LavalierCore"], path: "Sources/Lavalier"),
        .executableTarget(name: "lavalier-cli", dependencies: ["LavalierCore"], path: "Sources/lavalier-cli"),
        .testTarget(name: "LavalierCoreTests", dependencies: ["LavalierCore"], path: "Tests/LavalierCoreTests"),
    ]
)
