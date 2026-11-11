#!/bin/bash
# Fetches SwiftTerm (the VT/xterm engine) at a pinned release and trims its manifest:
# no CLI/fuzz/test targets, no extra package dependencies, and the Metal shader is
# shipped as source (compiled at runtime) so the build does not need Xcode's Metal toolchain.
# SwiftTerm's build-info plugin is replaced by the file it would generate, since the
# version is pinned anyway. The plugin breaks multi-arch and cross-arch builds.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="v1.20.0"
DEST="Vendor/SwiftTerm"
MARK="$DEST/.bterm-$TAG-2"
if [ -f "$MARK" ]; then exit 0; fi
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
            exclude: ["Mac/README.md", "Apple/Metal/Shaders.metal"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
MANIFEST
COMMIT="$(git -C "$DEST" rev-parse HEAD)"
cat > "$DEST/Sources/SwiftTerm/SwiftTermBuildInfo.swift" <<INFO
// Written by bterm's scripts/fetch-swiftterm.sh in place of SwiftTermBuildInfoPlugin.

/// Source-control information for this SwiftTerm build.
public enum SwiftTermBuildInfo {
    public static let branch: String? = nil
    public static let tag: String? = "$TAG"
    public static let commit: String? = "$COMMIT"
    /// The manifest is trimmed, so this is never a pristine checkout.
    public static let hasUncommittedChanges: Bool? = true
    public static let version: String = {
        let base = tag ?? commit.map { String(\$0.prefix(12)) } ?? "unknown"
        return hasUncommittedChanges == true ? "\(base)-modified" : base
    }()
}
INFO
touch "$MARK"
echo "SwiftTerm $TAG ready in $DEST"
