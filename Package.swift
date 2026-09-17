// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PhotoEngine",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "PhotoEngineCore", targets: ["PhotoEngineCore"]),
        .library(name: "PhotoEngineApple", targets: ["PhotoEngineApple"]),
        .executable(name: "photo-engine", targets: ["photo-engine"])
    ],
    targets: [
        .target(name: "PhotoEngineCore"),
        .target(name: "PhotoEngineApple", dependencies: ["PhotoEngineCore"]),
        .executableTarget(name: "photo-engine", dependencies: ["PhotoEngineApple", "PhotoEngineCore"])
    ]
)
