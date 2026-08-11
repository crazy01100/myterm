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
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            revision: "3219b171cacbe011635f1c1b6c47b0725ff56d3a"
        ),
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
            resources: [
                .copy("Resources/PlatformIcons")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
