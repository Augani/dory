// swift-tools-version:6.0
import PackageDescription

// In-process VM engine for Dory, built directly on Apple's `containerization` framework. Kept as a
// SEPARATE package (not part of Dory.xcodeproj) so the shipping app stays stable while this large
// integration — the one that unblocks Rosetta-fast x86, device passthrough, memory ballooning, and
// reverse file mounts — is built up and proven.
let package = Package(
    name: "ContainerizationEngine",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ContainerizationEngine", targets: ["ContainerizationEngine"]),
        .executable(name: "dory-vmboot", targets: ["dory-vmboot"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "ContainerizationEngine",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
            ]
        ),
        .executableTarget(
            name: "dory-vmboot",
            dependencies: [
                "ContainerizationEngine",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
            ]
        ),
    ]
)
