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
        .executable(name: "photo-engine", targets: ["photo-engine"]),
        .executable(name: "photo-engine-mac", targets: ["photo-engine-mac"])
    ],
    targets: [
        .target(name: "PhotoEngineCore"),
        .target(name: "PhotoEngineApple", dependencies: ["PhotoEngineCore"]),
        .executableTarget(name: "photo-engine", dependencies: ["PhotoEngineApple", "PhotoEngineCore"]),
        .executableTarget(name: "photo-engine-mac", dependencies: ["PhotoEngineApple", "PhotoEngineCore"])
    ]
)
