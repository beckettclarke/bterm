// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "bterm",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "bterm",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/bterm"
        ),
    ]
)
