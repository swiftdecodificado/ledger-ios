// swift-tools-version: 6.0
import PackageDescription

// The client side of the payments contract (intent, request, HTTP transport).
let package = Package(
    name: "Payments",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Payments", targets: ["Payments"]),
    ],
    targets: [
        .target(name: "Payments"),
        .testTarget(name: "PaymentsTests", dependencies: ["Payments"]),
    ]
)
