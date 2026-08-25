// swift-tools-version: 6.3
import PackageDescription

let libraryTargets: [Target] = [
    .target(name: "RVDomain"),
    .target(name: "RVTheme"),
    .target(name: "RVEngine", dependencies: ["RVDomain"]),
    .target(
        name: "RVPacks",
        dependencies: ["RVDomain"],
        resources: [.copy("Resources/packs")]
    ),
    .target(
        name: "RVPolicy",
        dependencies: [
            "RVDomain",
            .product(name: "Crypto", package: "swift-crypto"),
        ]
    ),
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
]

let coreTestTargets: [Target] = [
    .testTarget(name: "RVDomainTests", dependencies: ["RVDomain"]),
    .testTarget(
        name: "RVEngineTests",
        dependencies: ["RVEngine"],
        exclude: ["Fixtures"]
    ),
    .testTarget(name: "RVPacksTests", dependencies: ["RVPacks"]),
    .testTarget(name: "RVPolicyTests", dependencies: ["RVPolicy"]),
    .testTarget(
        name: "RVHooksTests",
        dependencies: ["RVHooks"],
        exclude: ["Fixtures"]
    ),
    .testTarget(name: "RVIPCTests", dependencies: ["RVIPC"]),
    .testTarget(name: "RVPresentationTests", dependencies: ["RVPresentation"]),
    .testTarget(name: "RVThemeTests", dependencies: ["RVTheme"]),
    .testTarget(
        name: "RVTUITests",
        dependencies: ["RVTUI"],
        exclude: ["Fixtures"]
    ),
    .testTarget(name: "RVHistoryTests", dependencies: ["RVHistory"]),
    .testTarget(name: "RVAnalyticsTests", dependencies: ["RVAnalytics"]),
    .testTarget(
        name: "RVCorpusTests",
        dependencies: ["RVDomain", "RVEngine", "RVPacks"]
    ),
]

// 6.3.3 `swift test` has no --target; --filter still typechecks every listed
// test target. Keep Service/CLI tests off the Linux graph so core `swift test`
// does not compile XPC/Darwin (OPE-260).
#if os(Linux)
let darwinTestTargets: [Target] = []
#else
let darwinTestTargets: [Target] = [
    .testTarget(name: "RVServiceTests", dependencies: ["RVService"]),
    .testTarget(name: "RVCLITests", dependencies: ["RVCLI"]),
]
#endif

let package = Package(
    name: "rv",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "RVDomain", targets: ["RVDomain"]),
        .library(name: "RVEngine", targets: ["RVEngine"]),
        .library(name: "RVPacks", targets: ["RVPacks"]),
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
        .package(url: "https://github.com/apple/swift-crypto", from: "4.5.1"),
    ],
    targets: libraryTargets + coreTestTargets + darwinTestTargets,
    swiftLanguageModes: [.v6]
)
