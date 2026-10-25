// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "RawGatewayCore", platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "RawGatewayCore", targets: ["RawGatewayCore"])],
    targets: [
        .target(name: "RawGatewayCore", path: "RawGateway/Core"),
        .testTarget(name: "RawGatewayCoreTests", dependencies: ["RawGatewayCore"], path: "Tests/RawGatewayCoreTests")
    ]
)
