// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "natebot",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .executableTarget(
            name: "natebot",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "natebot",
            exclude: ["Resources"],
            resources: [
                .copy("Resources/natebot.example.json")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
