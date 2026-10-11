// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MD2Audio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MD2Audio", path: "Sources/MD2Audio")
    ]
)
