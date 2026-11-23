// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CodexScheduler",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SchedulerCore", targets: ["SchedulerCore"]),
        .executable(name: "codex-scheduler", targets: ["CodexScheduler"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.0"),
    ],
    targets: [
        .target(
            name: "SchedulerCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AppleBridge",
            dependencies: ["SchedulerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("EventKit")]
        ),
        .target(
            name: "SchedulerStore",
            dependencies: ["SchedulerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "SchedulerTools",
            dependencies: [
                "SchedulerCore",
                "AppleBridge",
                "SchedulerStore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CodexScheduler",
            dependencies: [
                "SchedulerCore",
                "AppleBridge",
                "SchedulerStore",
                "SchedulerTools",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SchedulerCoreTests",
            dependencies: ["SchedulerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SchedulerToolsTests",
            dependencies: [
                "SchedulerTools",
                "SchedulerCore",
                "SchedulerStore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
