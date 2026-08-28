// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Spender",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Spender", targets: ["Spender"]),
    ],
    targets: [
        .executableTarget(
            name: "Spender",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(name: "SpenderTests", dependencies: ["Spender"]),
    ],
    swiftLanguageModes: [.v5]
)
