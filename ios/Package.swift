// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ComCore",
    platforms: [.macOS("15.0"), .iOS("26.0")],
    products: [.library(name: "ComCore", targets: ["ComCore"])],
    targets: [
        .target(name: "ComCore", path: "Com/Core"),
        .testTarget(name: "ComCoreTests", dependencies: ["ComCore"], path: "Tests/Core")
    ],
    swiftLanguageModes: [.v6]
)
