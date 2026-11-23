// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacClean",
    defaultLocalization: "ko",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacClean", targets: ["MacClean"]),
    ],
    targets: [
        .target(name: "MacCleanCore", path: "Sources/MacCleanCore"),
        .executableTarget(name: "MacClean", dependencies: ["MacCleanCore"], path: "Sources/MacClean"),
        .executableTarget(name: "mccheck", dependencies: ["MacCleanCore"], path: "Sources/mccheck"),
    ]
)
