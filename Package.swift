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
    ],
    dependencies: [
        .package(
            url: "https://github.com/pointfreeco/swift-composable-architecture.git",
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
            ]
        ),
        .testTarget(
            name: "PhotoCaptureClientTests",
            dependencies: [
                "PhotoCaptureClient",
            ]
        ),
    ]
)

extension Product {
    static func singleTargetLibrary(_ name: String) -> Product {
        .library(name: name, targets: [name])
    }
}
