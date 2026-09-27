// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhoneScreenKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PhoneScreenKit", targets: ["PhoneScreenKit"]),
    ],
    targets: [
        .target(name: "PhoneScreenKit"),
        .testTarget(name: "PhoneScreenKitTests", dependencies: ["PhoneScreenKit"]),
    ]
)
