// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ConvenienceIsland",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ConvenienceIsland", targets: ["ConvenienceIsland"])
    ],
    targets: [
        .executableTarget(
            name: "ConvenienceIsland",
            path: "Sources/ConvenienceIsland"
        ),
        .testTarget(
            name: "ConvenienceIslandTests",
            dependencies: ["ConvenienceIsland"],
            path: "Tests/ConvenienceIslandTests"
        )
    ]
)
