// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PontoGrava",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "PontoGrava", targets: ["PontoGrava"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "0.9.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "PontoGrava",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/MeetingScribe"
        )
    ],
    swiftLanguageModes: [.v5]
)
