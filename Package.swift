// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PhotoEngine",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "PhotoEngineCore", targets: ["PhotoEngineCore"]),
        .library(name: "PhotoEnginePersistence", targets: ["PhotoEnginePersistence"]),
        .library(name: "PhotoEngineApple", targets: ["PhotoEngineApple"]),
        .library(name: "PhotoEngineWorkflow", targets: ["PhotoEngineWorkflow"]),
        .executable(name: "photo-engine", targets: ["photo-engine"]),
        .executable(name: "photo-engine-mac", targets: ["photo-engine-mac"]),
        .executable(name: "photo-engine-checks", targets: ["photo-engine-checks"])
    ],
    targets: [
        .target(name: "PhotoEngineCore"),
        .target(name: "PhotoEnginePersistence", dependencies: ["PhotoEngineCore"]),
        .target(name: "PhotoEngineApple", dependencies: ["PhotoEngineCore", "PhotoEnginePersistence"]),
        .target(name: "PhotoEngineWorkflow", dependencies: ["PhotoEngineCore", "PhotoEnginePersistence", "PhotoEngineApple"]),
        .executableTarget(name: "photo-engine", dependencies: ["PhotoEngineApple", "PhotoEngineCore", "PhotoEngineWorkflow"]),
        .executableTarget(name: "photo-engine-mac", dependencies: ["PhotoEngineApple", "PhotoEngineCore", "PhotoEngineWorkflow"]),
        .executableTarget(name: "photo-engine-checks", dependencies: ["PhotoEngineApple", "PhotoEngineCore", "PhotoEnginePersistence", "PhotoEngineWorkflow"])
    ]
)
