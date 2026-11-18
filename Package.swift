// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "bterm",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "Vendor/Flint"),
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "bterm",
            dependencies: [
                .product(name: "Flint", package: "Flint"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/bterm"
        ),
    ]
)
