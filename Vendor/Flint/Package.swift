// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Flint",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Flint", targets: ["Flint"]),
    ],
    targets: [
        .target(name: "Flint"),
        .executableTarget(name: "FlintDemo", dependencies: ["Flint"], path: "Demo"),
        .testTarget(name: "FlintTests", dependencies: ["Flint"]),
    ]
)
