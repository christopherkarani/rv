// swift-tools-version: 6.4
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
// Official Linux tarball has no SQLite3 clang module. OpenCode talks system
// libsqlite3 (no SPM package). Darwin keeps `import SQLite3`.
let scanLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("sqlite3"),
]
#else
let extraPackageDependencies: [Package.Dependency] = []
let policyTargetDependencies: [Target.Dependency] = [
    "RVDomain",
]
let scanLinkerSettings: [LinkerSetting] = []
#endif

// Landlock trampoline: restrict_self + exec in a fresh process. Never
// Landlock the Swift caller (tests / later rvd). Linux-only.
#if os(Linux)
let isolationExecProducts: [Product] = [
    .executable(name: "rv-isolation-exec", targets: ["rv-isolation-exec"]),
]
let isolationExecTargets: [Target] = [
    .executableTarget(
        name: "rv-isolation-exec",
        cSettings: [
            .headerSearchPath("../RVIsolation/include"),
        ]
    ),
]
let isolationTestDependencies: [Target.Dependency] = ["RVIsolation", "rv-isolation-exec"]
#else
let isolationExecProducts: [Product] = []
let isolationExecTargets: [Target] = []
let isolationTestDependencies: [Target.Dependency] = ["RVIsolation"]
#endif

let coreLibraryTargets: [Target] = [
    .target(name: "RVDomain"),
    .target(
        name: "RVIsolation",
        dependencies: ["RVDomain"],
        // SwiftPM rejects mixed-language targets. The C shim is compiled
        // only into Linux `rv-isolation-exec`.
        exclude: [
            "landlock_apply.c",
            "include",
        ]
    ),
    .target(name: "RVTheme"),
    .target(name: "RVEngine", dependencies: ["RVDomain"]),
    .target(
        name: "RVPacks",
        dependencies: ["RVDomain"],
        resources: [.copy("Resources/packs")]
    ),
    .target(
        name: "RVScan",
        dependencies: ["RVDomain", "RVEngine", "RVPacks"],
        linkerSettings: scanLinkerSettings
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
    .library(name: "RVIsolation", targets: ["RVIsolation"]),
    .library(name: "RVEngine", targets: ["RVEngine"]),
    .library(name: "RVPacks", targets: ["RVPacks"]),
    .library(name: "RVScan", targets: ["RVScan"]),
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
    .testTarget(name: "RVIsolationTests", dependencies: isolationTestDependencies),
    .testTarget(
        name: "RVEngineTests",
        dependencies: ["RVEngine"],
        exclude: ["Fixtures"]
    ),
    .testTarget(name: "RVPacksTests", dependencies: ["RVPacks"]),
    .testTarget(
        name: "RVScanTests",
        dependencies: ["RVScan"],
        exclude: ["Fixtures"],
        linkerSettings: scanLinkerSettings
    ),
    .testTarget(name: "RVPolicyTests", dependencies: ["RVPolicy"]),
    .testTarget(
        name: "RVHooksTests",
        dependencies: ["RVHooks", "RVEngine"],
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
        dependencies: ["RVDomain", "RVEngine", "RVPacks"],
        exclude: ["disk-rule-coverage.json"]
    ),
]

// P2 (OPE-261): RVService + rvd + RVServiceTests on the Linux graph.
// P3 (OPE-262): RVCLI + rv + RVCLITests return. XPC stays #if canImport(XPC).
let serviceLibraryAndDaemon: [Target] = [
    .target(
        name: "RVService",
        dependencies: [
            "RVDomain", "RVEngine", "RVPacks", "RVPolicy", "RVHooks", "RVIPC", "RVHistory",
            "RVAnalytics",
        ]
    ),
    .executableTarget(
        name: "rvd",
        dependencies: ["RVService"]
    ),
]
let serviceProducts: [Product] = [
    .library(name: "RVService", targets: ["RVService"]),
    .executable(name: "rvd", targets: ["rvd"]),
]
let serviceTestTargets: [Target] = [
    .testTarget(name: "RVServiceTests", dependencies: ["RVService", "RVAnalytics"]),
]

let cliTargets: [Target] = [
    .target(
        name: "RVCLI",
        dependencies: [
            "RVDomain", "RVEngine", "RVPolicy", "RVHooks", "RVIPC",
            "RVPresentation", "RVScan", "RVTheme", "RVTUI", "RVService", "RVHistory",
            "RVAnalytics",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ],
        resources: [
            .embedInCode("Resources/launchd"),
            .embedInCode("Resources/systemd"),
        ]
    ),
    .executableTarget(
        name: "rv",
        dependencies: [
            "RVCLI",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),
]
let cliProducts: [Product] = [
    .library(name: "RVCLI", targets: ["RVCLI"]),
    .executable(name: "rv", targets: ["rv"]),
]
let cliTestTargets: [Target] = [
    .testTarget(name: "RVCLITests", dependencies: ["RVCLI", "RVService"]),
]

let package = Package(
    name: "rv",
    platforms: [
        .macOS(.v26),
    ],
    products: coreProducts + isolationExecProducts + serviceProducts + cliProducts,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
    ] + extraPackageDependencies,
    targets: coreLibraryTargets + isolationExecTargets + serviceLibraryAndDaemon + cliTargets
        + coreTestTargets + serviceTestTargets + cliTestTargets,
    swiftLanguageModes: [.v6]
)
