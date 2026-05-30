// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MovieStats",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MovieStats",
            path: "Sources/MovieStats"
        )
    ]
)
