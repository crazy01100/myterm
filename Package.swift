// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MySSHClient",
    defaultLocalization: "zh-Hant",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MySSHClient", targets: ["MySSHClient"])
    ],
    traits: [],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
        .package(
            url: "https://github.com/jedisct1/swift-sodium.git",
            exact: "0.11.0"
        ),
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            exact: "2.9.5"
        )
    ],
    targets: [
        .executableTarget(
            name: "MySSHClient",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            exclude: ["Resources"]
        )
    ],
    swiftLanguageModes: [.v5]
)
