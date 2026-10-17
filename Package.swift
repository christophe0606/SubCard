// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "SubCard",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SubCardCore", targets: ["SubCardCore"]),
        .executable(name: "SubCard", targets: ["SubCard"]),
    ],
    targets: [
        .target(
            name: "SubCardCore",
            path: "backend",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "SubCard",
            dependencies: ["SubCardCore"],
            path: "apps/swiftui"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
