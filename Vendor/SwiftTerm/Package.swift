// swift-tools-version:5.9
import PackageDescription

// MyTerm vendors only the library runtime; see UPSTREAM.md for provenance.
let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v11)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [.target(name: "SwiftTerm", path: "Sources/SwiftTerm",
                      exclude: ["iOS", "Mac/README.md"],
                      resources: [.process("Apple/Metal/Shaders.metal")])],
    swiftLanguageVersions: [.v5]
)
