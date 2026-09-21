// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhoneSnap",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PhoneSnap", targets: ["PhoneSnap"])
    ],
    targets: [
        .executableTarget(
            name: "PhoneSnap",
            dependencies: ["NearbyTransport"],
            path: "Sources/PhoneSnap"
        ),
        .target(name: "NearbyTransport"),
        .testTarget(name: "NearbyTransportTests", dependencies: ["NearbyTransport"]),
        .testTarget(
            name: "PhoneSnapTests",
            dependencies: ["PhoneSnap"],
            path: "Tests/PhoneSnapTests"
        )
    ]
)
