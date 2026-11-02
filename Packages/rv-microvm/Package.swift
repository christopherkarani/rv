// swift-tools-version: 6.4
import PackageDescription

// rv-microvm: the only rv binary that links apple/containerization and the
// only one that carries com.apple.security.virtualization. It is a separate
// package so the main rv graph stays free of swift-crypto/NIO/gRPC on Darwin
// (OPE-260) and so Containerization's 0.x churn is contained here.
let package = Package(
    name: "rv-microvm",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "rv-microvm", targets: ["rv-microvm"]),
    ],
    dependencies: [
        // 0.x: source-stable only within a minor. The vminit image pin in
        // MicroVMPins must move with this version.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.54.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
        // Same pin as the main package: 1.7.x emits Swift 6.4 borrow runtime
        // calls unavailable on the macOS 26 release runner.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.6.0"),
    ],
    targets: [
        .target(name: "RVMicroVMCore"),
        .executableTarget(
            name: "rv-microvm",
            dependencies: [
                "RVMicroVMCore",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "RVMicroVMCoreTests", dependencies: ["RVMicroVMCore"]),
    ],
    swiftLanguageModes: [.v6]
)
