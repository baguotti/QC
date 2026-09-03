// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QCpie",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "QCpie", targets: ["QCpie"]),
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
            name: "QCpie",
            dependencies: ["VideoQCLib"],
            path: "Sources/VideoQCApp"
        )
    ]
)
