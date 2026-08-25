// swift-tools-version: 6.3
import PackageDescription

// Crypto / swift-crypto is Linux-only. Darwin RVPolicy keeps CryptoKit and
// must not fetch swift-crypto + swift-asn1 (OPE-260 review).
#if os(Linux)
let extraPackageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto", from: "4.5.1"),
]
let policyTargetDependencies: [Target.Dependency] = [
    "RVDomain",
    .product(name: "Crypto", package: "swift-crypto"),
]
#else
let extraPackageDependencies: [Package.Dependency] = []
let policyTargetDependencies: [Target.Dependency] = [
    "RVDomain",
]
#endif

let coreLibraryTargets: [Target] = [
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
        dependencies: policyTargetDependencies
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
]

let coreProducts: [Product] = [
    .library(name: "RVDomain", targets: ["RVDomain"]),
    .library(name: "RVEngine", targets: ["RVEngine"]),
    .library(name: "RVPacks", targets: ["RVPacks"]),
    .library(name: "RVPolicy", targets: ["RVPolicy"]),
    .library(name: "RVHooks", targets: ["RVHooks"]),
    .library(name: "RVIPC", targets: ["RVIPC"]),
    .library(name: "RVPresentation", targets: ["RVPresentation"]),
    .library(name: "RVTheme", targets: ["RVTheme"]),
    .library(name: "RVTUI", targets: ["RVTUI"]),
    .library(name: "RVHistory", targets: ["RVHistory"]),
    .library(name: "RVAnalytics", targets: ["RVAnalytics"]),
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

// 6.3.3 `swift test` has no --target and still typechecks every listed
// target/product. Keep Service/CLI/XPC + their tests off the Linux graph
// (OPE-260). They stay Darwin; P2/P3 own Linux rvd/CLI.
#if os(Linux)
let darwinLibraryTargets: [Target] = []
let darwinProducts: [Product] = []
let darwinTestTargets: [Target] = []
#else
let darwinLibraryTargets: [Target] = [
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
let darwinProducts: [Product] = [
    .library(name: "RVService", targets: ["RVService"]),
    .library(name: "RVCLI", targets: ["RVCLI"]),
    .executable(name: "rv", targets: ["rv"]),
    .executable(name: "rvd", targets: ["rvd"]),
]
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
    products: coreProducts + darwinProducts,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
    ] + extraPackageDependencies,
    targets: coreLibraryTargets + darwinLibraryTargets + coreTestTargets + darwinTestTargets,
    swiftLanguageModes: [.v6]
)
