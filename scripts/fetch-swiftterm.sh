#!/bin/bash
# Fetches SwiftTerm (the VT/xterm engine) at a pinned release and trims its manifest:
# no CLI/fuzz/test targets, no extra package dependencies, and the Metal shader is
# shipped as source (compiled at runtime) so the build does not need Xcode's Metal toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="v1.20.0"
DEST="Vendor/SwiftTerm"
if [ -f "$DEST/.bterm-$TAG" ]; then exit 0; fi
rm -rf "$DEST"
mkdir -p Vendor
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/migueldeicaza/SwiftTerm.git "$DEST"
cat > "$DEST/Package.swift" <<'MANIFEST'
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md", "Apple/Metal/Shaders.metal"],
            plugins: [.plugin(name: "SwiftTermBuildInfoPlugin")]
        ),
        .executableTarget(name: "SwiftTermBuildInfoGenerator", path: "Sources/SwiftTermBuildInfoGenerator"),
        .plugin(name: "SwiftTermBuildInfoPlugin", capability: .buildTool(), dependencies: ["SwiftTermBuildInfoGenerator"]),
    ],
    swiftLanguageModes: [.v5]
)
MANIFEST
touch "$DEST/.bterm-$TAG"
echo "SwiftTerm $TAG ready in $DEST"
