// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ribbon",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ribbon-daemon", targets: ["ribbon-daemon"]),
        .executable(name: "ribbon", targets: ["ribbon-cli"])
    ],
    targets: [
        .target(
            name: "RibbonCore",
            dependencies: []
        ),
        .target(
            name: "RibbonAccessibility",
            dependencies: ["RibbonCore"]
        ),
        .executableTarget(
            name: "ribbon-daemon",
            dependencies: ["RibbonCore", "RibbonAccessibility"]
        ),
        .executableTarget(
            name: "ribbon-cli",
            dependencies: []
        )
    ]
)
