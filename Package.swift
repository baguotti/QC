// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VideoQC",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VideoQC", targets: ["VideoQC"]),
        .library(name: "VideoQCLib", targets: ["VideoQCLib"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "VideoQCLib",
            dependencies: [],
            path: "Sources/VideoQCLib"
        ),
        .executableTarget(
            name: "VideoQC",
            dependencies: ["VideoQCLib"],
            path: "Sources/VideoQCApp"
        )
    ]
)
