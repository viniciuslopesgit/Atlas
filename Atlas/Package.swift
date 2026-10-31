// swift-tools-version:5.9
import Foundation
import PackageDescription

var targets: [Target] = [
    .executableTarget(
        name: "Atlas",
        path: "Sources/Atlas"
    )
]
// main has no tests (only what builds the stable version, see .mainignore): the target only exists on dev.
if FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tests/AtlasTests") {
    targets.append(.testTarget(name: "AtlasTests", dependencies: ["Atlas"], path: "Tests/AtlasTests"))
}

let package = Package(
    name: "Atlas",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "Atlas", targets: ["Atlas"])
    ],
    targets: targets
)
