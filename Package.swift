// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "rv",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "RVDomain", targets: ["RVDomain"]),
        .library(name: "RVEngine", targets: ["RVEngine"]),
        .library(name: "RVPacks", targets: ["RVPacks"]),
        .library(name: "RVScan", targets: ["RVScan"]),
        .library(name: "RVPolicy", targets: ["RVPolicy"]),
        .library(name: "RVHooks", targets: ["RVHooks"]),
        .library(name: "RVIPC", targets: ["RVIPC"]),
        .library(name: "RVService", targets: ["RVService"]),
        .library(name: "RVPresentation", targets: ["RVPresentation"]),
        .library(name: "RVTheme", targets: ["RVTheme"]),
        .library(name: "RVTUI", targets: ["RVTUI"]),
        .library(name: "RVCLI", targets: ["RVCLI"]),
        .library(name: "RVHistory", targets: ["RVHistory"]),
        .library(name: "RVAnalytics", targets: ["RVAnalytics"]),
        .executable(name: "rv", targets: ["rv"]),
        .executable(name: "rvd", targets: ["rvd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
    ],
    targets: [
        .target(name: "RVDomain"),
        .target(name: "RVTheme"),
        .target(name: "RVEngine", dependencies: ["RVDomain"]),
        .target(
            name: "RVPacks",
            dependencies: ["RVDomain"],
            resources: [.copy("Resources/packs")]
        ),
        .target(
            name: "RVScan",
            dependencies: ["RVDomain", "RVEngine", "RVPacks"]
        ),
        .target(name: "RVPolicy", dependencies: ["RVDomain"]),
        .target(
            name: "RVHooks",
            dependencies: ["RVDomain"],
            resources: [.embedInCode("Resources/hosts")]
        ),
        .target(name: "RVIPC", dependencies: ["RVDomain"]),
        .target(name: "RVHistory", dependencies: ["RVDomain"]),
        .target(name: "RVAnalytics"),
        .target(name: "RVPresentation", dependencies: ["RVDomain", "RVTheme"]),
        .target(name: "RVTUI", dependencies: ["RVTheme", "RVPresentation"]),
        .target(
            name: "RVService",
            dependencies: [
                "RVDomain", "RVEngine", "RVPacks", "RVPolicy", "RVHooks", "RVIPC", "RVHistory",
                "RVAnalytics",
            ]
        ),
        .target(
            name: "RVCLI",
            dependencies: [
                "RVDomain", "RVEngine", "RVPolicy", "RVHooks", "RVIPC",
                "RVPresentation", "RVTheme", "RVTUI", "RVService", "RVHistory",
                "RVAnalytics",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [
                .embedInCode("Resources/launchd"),
            ]
        ),
        .executableTarget(
            name: "rv",
            dependencies: [
                "RVCLI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "rvd",
            dependencies: ["RVService"]
        ),
        .testTarget(name: "RVDomainTests", dependencies: ["RVDomain"]),
        .testTarget(
            name: "RVEngineTests",
            dependencies: ["RVEngine"],
            exclude: ["Fixtures"]
        ),
        .testTarget(name: "RVPacksTests", dependencies: ["RVPacks"]),
        .testTarget(name: "RVScanTests", dependencies: ["RVScan"]),
        .testTarget(name: "RVPolicyTests", dependencies: ["RVPolicy"]),
        .testTarget(
            name: "RVHooksTests",
            dependencies: ["RVHooks"],
            exclude: ["Fixtures"]
        ),
        .testTarget(name: "RVIPCTests", dependencies: ["RVIPC"]),
        .testTarget(name: "RVServiceTests", dependencies: ["RVService"]),
        .testTarget(name: "RVPresentationTests", dependencies: ["RVPresentation"]),
        .testTarget(name: "RVThemeTests", dependencies: ["RVTheme"]),
        .testTarget(
            name: "RVTUITests",
            dependencies: ["RVTUI"],
            exclude: ["Fixtures"]
        ),
        .testTarget(name: "RVCLITests", dependencies: ["RVCLI"]),
        .testTarget(name: "RVHistoryTests", dependencies: ["RVHistory"]),
        .testTarget(name: "RVAnalyticsTests", dependencies: ["RVAnalytics"]),
        .testTarget(
            name: "RVCorpusTests",
            dependencies: ["RVDomain", "RVEngine", "RVPacks"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
