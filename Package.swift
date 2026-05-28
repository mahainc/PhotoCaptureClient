// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PhotoCaptureClient",
    platforms: [
        .iOS(.v17), .macOS(.v14)
    ],
    products: [
        .singleTargetLibrary("PhotoCaptureClient"),
        .singleTargetLibrary("PhotoCaptureClientLive"),
        .singleTargetLibrary("ObjectDetectionClient"),
        .singleTargetLibrary("ObjectDetectionClientLive"),
        .singleTargetLibrary("MultiCamClient"),
        .singleTargetLibrary("MultiCamClientLive"),
    ],
    dependencies: [
        .package(
            url: "https://github.com/pointfreeco/swift-composable-architecture.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/ultralytics/yolo-ios-app.git",
            branch: "main"
        ),
    ],
    targets: [
        .target(
            name: "PhotoCaptureClient",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .target(
            name: "PhotoCaptureClientLive",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "PhotoCaptureClient"
            ],
            resources: [
                .process("Shaders.metal"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .target(
            name: "ObjectDetectionClient",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .target(
            name: "ObjectDetectionClientLive",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "YOLO", package: "yolo-ios-app", condition: .when(platforms: [.iOS])),
                "ObjectDetectionClient",
                "PhotoCaptureClient",
            ],
            resources: [
                .copy("Resources/yolo11n.mlpackage"),
            ]
        ),
        .target(
            name: "MultiCamClient",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "PhotoCaptureClient",
            ]
        ),
        .target(
            name: "MultiCamClientLive",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "MultiCamClient",
                "PhotoCaptureClient",
            ],
            resources: [
                .process("Shaders.metal"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .testTarget(
            name: "MultiCamClientTests",
            dependencies: [
                "MultiCamClient",
            ]
        ),
        .testTarget(
            name: "PhotoCaptureClientTests",
            dependencies: [
                "PhotoCaptureClient",
            ]
        ),
        .testTarget(
            name: "ObjectDetectionClientTests",
            dependencies: [
                "ObjectDetectionClient",
            ]
        ),
    ]
)

extension Product {
    static func singleTargetLibrary(_ name: String) -> Product {
        .library(name: name, targets: [name])
    }
}
