// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "thermac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "thermac", targets: ["thermac"]),
        .executable(name: "ThermacBar", targets: ["ThermacBar"]),
        .library(name: "ThermacCore", targets: ["ThermacCore"]),
    ],
    targets: [
        .target(
            name: "CThermacPrivate",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("IOReport"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "ThermacCore",
            dependencies: ["CThermacPrivate"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "thermac",
            dependencies: ["ThermacCore"]
        ),
        .executableTarget(
            name: "ThermacBar",
            dependencies: ["ThermacCore"]
        ),
        .testTarget(
            name: "ThermacCoreTests",
            dependencies: ["ThermacCore"]
        ),
    ]
)
