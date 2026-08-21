// swift-tools-version:6.0
import PackageDescription

// Low-level Hypervisor.framework VM engine for Dory. The app and dory-vmm fallback support macOS
// 14, while this raw-HV helper intentionally starts at macOS 15. doryd must keep that distinction
// in sync with the helper's LC_BUILD_VERSION deployment target.
let package = Package(
    name: "ContainerizationEngine",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "dory-hv", targets: ["dory-hv"]),
    ],
    dependencies: [
        // Keep the guest control wire protocol in one implementation. DoryCore embeds the Rust
        // handshake + mux + protobuf client that doryd and dory-vmm already use; raw dory-hv feeds
        // its in-process virtio-vsock stream to the same client through a local socketpair.
        .package(path: "../../dory-core-swift"),
    ],
    targets: [
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
                "DoryHVUSBShim",
                .product(name: "DoryCore", package: "dory-core-swift"),
            ],
            linkerSettings: [
                .linkedFramework("Hypervisor"),
                .linkedFramework("CoreServices"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
                .linkedFramework("OpenGL"),
            ]
        ),
        .executableTarget(
            name: "dory-hv",
            dependencies: [
                "DoryHV",
                .product(name: "DoryCore", package: "dory-core-swift"),
                .product(name: "DorydKit", package: "dory-core-swift"),
                .product(name: "DoryOperations", package: "dory-core-swift"),
                .product(name: "DoryVMMKit", package: "dory-core-swift"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .testTarget(
            name: "DoryHVTests",
            dependencies: [
                "DoryHV",
                "dory-hv",
                .product(name: "DoryCore", package: "dory-core-swift"),
                .product(name: "DoryOperations", package: "dory-core-swift"),
            ]
        ),
    ]
)
