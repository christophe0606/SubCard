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
            name: "SubCardSQLite",
            path: "vendor/sqlite",
            exclude: ["README.md"],
            sources: ["src/sqlite3.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_OMIT_LOAD_EXTENSION"),
                .define("SQLITE_DQS", to: "0"),
                .define("SQLITE_TEMP_STORE", to: "3"),
            ]
        ),
        .target(
            name: "SubCardCore",
            dependencies: ["SubCardSQLite"],
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
