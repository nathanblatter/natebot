// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "natebot",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "natebot",
            path: "natebot",
            exclude: ["Resources"],
            resources: [
                .copy("Resources/natebot.json")
            ],
            linkerSettings: [
                // Link system SQLite3 (no third-party packages needed)
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
