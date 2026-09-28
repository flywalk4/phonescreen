// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QwoviKit",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "QwoviKit", targets: ["QwoviKit"]),
    ],
    targets: [
        .target(name: "QwoviKit"),
        .testTarget(name: "QwoviKitTests", dependencies: ["QwoviKit"]),
    ]
)
