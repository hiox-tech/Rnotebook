// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "EdmundCoreProbe", platforms: [.macOS("14.0")],
    products: [.library(name: "EdmundCore", targets: ["EdmundCore"])],
    dependencies: [.package(path: "../Dependencies/swift-markdown"), .package(path: "../Dependencies/SwiftMath")],
    targets: [.target(name: "EdmundCore", dependencies: [
        .product(name: "Markdown", package: "swift-markdown"),
        .product(name: "SwiftMath", package: "SwiftMath")],
        resources: [.copy("Resources/Syntaxes"), .copy("Resources/Themes")])])
