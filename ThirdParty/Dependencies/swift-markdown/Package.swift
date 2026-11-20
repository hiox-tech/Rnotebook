// swift-tools-version:6.2
/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021-2023 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import PackageDescription
import class Foundation.ProcessInfo

let cmarkPackageName = "cmark"

let package = Package(
    name: "swift-markdown",
    products: [
        .library(
            name: "Markdown",
            targets: ["Markdown"]),
    ],
    targets: [
        .target(
            name: "Markdown",
            dependencies: [
                "CAtomic",
                .product(name: "cmark-gfm", package: cmarkPackageName),
                .product(name: "cmark-gfm-extensions", package: cmarkPackageName),
            ],
            exclude: [
                "CMakeLists.txt"
            ],
            swiftSettings: [.unsafeFlags(["-Xcc", "-DCMARK_GFM_STATIC_DEFINE"], .when(platforms: [.windows]))]
        ),
        .testTarget(
            name: "MarkdownTests",
            dependencies: ["Markdown"],
            resources: [.process("Visitors/Everything.md")]),
        .target(name: "CAtomic"),
    ],
    swiftLanguageModes: [.v5]
)

// Pinned local dependency for the offline desktop preview.
package.dependencies += [.package(path: "../cmark")]
