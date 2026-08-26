// swift-tools-version:6.0
import PackageDescription

// Low-level Hypervisor.framework VM engine for Dory. The app and dory-vmm fallback support macOS
// 14, while this raw-HV helper intentionally starts at macOS 15. doryd must keep that distinction
// in sync with the helper's LC_BUILD_VERSION deployment target.
let package = Package(
    name: "ContainerizationEngine",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DoryFSWorkerContracts", targets: ["DoryFSWorkerContracts"]),
        .library(name: "DoryFSWorkerServiceCore", targets: ["DoryFSWorkerServiceCore"]),
        .library(
            name: "DoryRendererWorkerContracts",
            targets: ["DoryRendererWorkerContracts"]
        ),
        .library(
            name: "DoryRendererWorkerServiceCore",
            targets: ["DoryRendererWorkerServiceCore"]
        ),
        .library(
            name: "DoryRendererWorkerMetalTransport",
            targets: ["DoryRendererWorkerMetalTransport"]
        ),
        .library(
            name: "DoryRendererWorkerVirglBackend",
            targets: ["DoryRendererWorkerVirglBackend"]
        ),
        .library(name: "DoryHV", targets: ["DoryHV"]),
        .executable(name: "dory-hv", targets: ["dory-hv"]),
        .executable(
            name: "dory-renderer-worker",
            targets: ["DoryRendererWorkerXPCService"]
        ),
    ],
    dependencies: [
        // Keep the guest control wire protocol in one implementation. DoryCore embeds the Rust
        // handshake + mux + protobuf client that doryd and dory-vmm already use; raw dory-hv feeds
        // its in-process virtio-vsock stream to the same client through a local socketpair.
        .package(path: "../../dory-core-swift"),
    ],
    targets: [
        // Foundation-only wire contracts shared by the VMM-side broker and signed XPC service.
        // SwiftPM builds the protocol leaf and executable test surface; Dory.xcodeproj owns the
        // actual sandboxed XPC bundle, nested embed, and inside-out signing graph.
        .target(name: "DoryFSWorkerContracts"),
        // Path-free worker-side authority acquisition. Keep this leaf independent of the VMM,
        // Hypervisor.framework, IOKit, and the daemon so a signed service can embed it directly.
        .target(
            name: "DoryFSWorkerServiceCore",
            dependencies: ["DoryFSWorkerContracts"]
        ),
        // Path-free binary authority shared by the VMM and the signed renderer service. The
        // contract intentionally has no dependency on Hypervisor.framework, AppKit, Metal, or the
        // foreign renderer ABI.
        .target(
            name: "DoryRendererWorkerContracts",
            dependencies: [
                .product(
                    name: "DoryRendererWorkerWireContracts",
                    package: "dory-core-swift"
                ),
            ]
        ),
        // Metal/XPC transport is deliberately outside the Foundation/CryptoKit authority package
        // consumed by doryd. Only the signed runner and renderer service depend on this leaf.
        .target(
            name: "DoryRendererWorkerMetalTransport",
            dependencies: ["DoryRendererWorkerContracts"],
            linkerSettings: [.linkedFramework("Metal")]
        ),
        .target(
            name: "DoryRendererWorkerServiceCore",
            dependencies: [
                "DoryGuestMemoryShim",
                "DoryRendererWorkerContracts",
                "DoryRendererWorkerMetalTransport",
            ]
        ),
        .target(
            name: "DoryVirglRendererShim"
        ),
        .target(
            name: "DoryRendererWorkerVirglBackend",
            dependencies: [
                "DoryRendererWorkerContracts",
                "DoryRendererWorkerServiceCore",
                "DoryVirglRendererShim",
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
            ]
        ),
        .target(
            name: "DoryGuestMemoryShim"
        ),
        .target(
            name: "DoryHVUSBShim",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
            ]
        ),
        .target(
            name: "DoryHV",
            dependencies: [
                "DoryFSWorkerContracts",
                "DoryGuestMemoryShim",
                "DoryRendererWorkerContracts",
                "DoryRendererWorkerMetalTransport",
                "DoryHVUSBShim",
                .product(name: "DoryCore", package: "dory-core-swift"),
                .product(name: "DoryVMContracts", package: "dory-core-swift"),
            ],
            linkerSettings: [
                .linkedFramework("Hypervisor"),
                .linkedFramework("CoreServices"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
            ]
        ),
        .executableTarget(
            name: "dory-hv",
            dependencies: [
                "DoryFSWorkerContracts",
                "DoryHV",
                "DoryRendererWorkerContracts",
                .product(name: "DoryCore", package: "dory-core-swift"),
                .product(name: "DorydKit", package: "dory-core-swift"),
                .product(name: "DoryOperations", package: "dory-core-swift"),
                .product(name: "DoryVMContracts", package: "dory-core-swift"),
                .product(name: "DoryVMMKit", package: "dory-core-swift"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "DoryRendererWorkerXPCService",
            dependencies: [
                "DoryRendererWorkerContracts",
                "DoryRendererWorkerMetalTransport",
                "DoryRendererWorkerServiceCore",
                "DoryRendererWorkerVirglBackend",
            ]
        ),
        .testTarget(
            name: "DoryFSWorkerServiceCoreTests",
            dependencies: [
                "DoryFSWorkerContracts",
                "DoryFSWorkerServiceCore",
            ]
        ),
        .testTarget(
            name: "DoryRendererWorkerContractsTests",
            dependencies: [
                "DoryRendererWorkerContracts",
                "DoryRendererWorkerMetalTransport",
            ]
        ),
        .testTarget(
            name: "DoryRendererWorkerServiceCoreTests",
            dependencies: [
                "DoryGuestMemoryShim",
                "DoryRendererWorkerContracts",
                "DoryRendererWorkerServiceCore",
            ]
        ),
        .testTarget(
            name: "DoryRendererWorkerVirglBackendTests",
            dependencies: [
                "DoryRendererWorkerContracts",
                "DoryRendererWorkerServiceCore",
                "DoryRendererWorkerVirglBackend",
                "DoryVirglRendererShim",
            ]
        ),
        .testTarget(
            name: "DoryHVTests",
            dependencies: [
                "DoryFSWorkerContracts",
                "DoryFSWorkerServiceCore",
                "DoryRendererWorkerContracts",
                "DoryHV",
                "DoryVirglRendererShim",
                "dory-hv",
                .product(name: "DoryCore", package: "dory-core-swift"),
                .product(name: "DoryOperations", package: "dory-core-swift"),
                .product(name: "DoryVMContracts", package: "dory-core-swift"),
            ]
        ),
    ]
)
