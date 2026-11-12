// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PhotoCaptureClient",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .singleTargetLibrary("PhotoCaptureClient"),
        .singleTargetLibrary("PhotoCaptureClientLive"),
        .singleTargetLibrary("ObjectDetectionClient"),
        .singleTargetLibrary("ObjectDetectionClientLive"),
        .singleTargetLibrary("ObjectTracking"),
        .singleTargetLibrary("MultiCamClient"),
        .singleTargetLibrary("MultiCamClientLive"),
        .singleTargetLibrary("HistogramKit"),
    ],
    dependencies: [
        .package(
            url: "https://github.com/pointfreeco/swift-composable-architecture.git",
            from: "1.25.5"
        )
    ],
    targets: [
        .target(
            name: "PhotoCaptureClient",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "HistogramKit",
            ]
        ),
        .target(
            name: "PhotoCaptureClientLive",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "PhotoCaptureClient",
                "HistogramKit",
            ],
            resources: [
                .process("Shaders.metal")
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .target(
            name: "ObjectDetectionClient",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture")
            ]
        ),
        .target(
            name: "ObjectDetectionClientLive",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "ObjectDetectionClient",
                "ObjectTracking",
                "PhotoCaptureClient",
            ],
            resources: [
                .copy("Resources/yolo26n.mlpackage"),
                .copy("Resources/yolo26n-seg.mlpackage"),
                .copy("Resources/yolo26n-depth.mlpackage"),
            ]
        ),
        .target(
            name: "ObjectTracking"
        ),
        .target(
            name: "MultiCamClient",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "PhotoCaptureClient",
                "HistogramKit",
            ]
        ),
        .target(
            name: "MultiCamClientLive",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "MultiCamClient",
                "PhotoCaptureClient",
                "HistogramKit",
            ],
            resources: [
                .process("Shaders.metal")
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .target(
            name: "HistogramKit",
            resources: [
                .process("Histogram.metal")
            ],
            linkerSettings: [
                .linkedFramework("Metal")
            ]
        ),
        .testTarget(
            name: "MultiCamClientTests",
            dependencies: [
                "MultiCamClient"
            ]
        ),
        .testTarget(
            name: "PhotoCaptureClientTests",
            dependencies: [
                "PhotoCaptureClient"
            ]
        ),
        .testTarget(
            name: "ObjectDetectionClientTests",
            dependencies: [
                "ObjectDetectionClient"
            ]
        ),
        .testTarget(
            name: "ObjectTrackingTests",
            dependencies: [
                "ObjectTracking"
            ]
        ),
    ]
)

extension Product {
    static func singleTargetLibrary(_ name: String) -> Product {
        .library(name: name, targets: [name])
    }
}
