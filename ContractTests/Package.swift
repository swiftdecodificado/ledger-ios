// swift-tools-version: 6.0
import PackageDescription

// Checks the payments HTTP contract (see Contracts/payments/openapi.yaml) against the in-memory
// server and, with LEDGERCORE_BASE_URL set, against a real backend. Kept separate from the
// Payments and PaymentsTestSupport packages so contract coverage isn't mistaken for unit coverage
// of either package.
let package = Package(
    name: "PaymentsContractTests",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(path: "../Packages/Payments"),
        .package(path: "../Packages/PaymentsTestSupport"),
    ],
    targets: [
        .testTarget(
            name: "PaymentsContractTests",
            dependencies: ["Payments", "PaymentsTestSupport"]
        ),
    ]
)
