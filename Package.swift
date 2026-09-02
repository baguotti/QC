// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LineFinder5000",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LineFinder5000", targets: ["LineFinder5000"]),
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
            name: "LineFinder5000",
            dependencies: ["VideoQCLib"],
            path: "Sources/VideoQCApp"
        )
    ]
)
