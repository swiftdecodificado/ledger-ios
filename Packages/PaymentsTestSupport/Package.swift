// swift-tools-version: 6.0
import PackageDescription

// An in-memory server that follows the payments HTTP contract, used by the app and by tests
// until a real backend exists. It is development and test infrastructure, not production code.
let package = Package(
    name: "PaymentsTestSupport",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PaymentsTestSupport", targets: ["PaymentsTestSupport"]),
    ],
    dependencies: [
        .package(path: "../Payments"),
    ],
    targets: [
        .target(name: "PaymentsTestSupport", dependencies: ["Payments"]),
        .testTarget(name: "PaymentsTestSupportTests", dependencies: ["Payments", "PaymentsTestSupport"]),
    ]
)
