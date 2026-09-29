// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "ArrumatorPackages",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ArrumatorCore", targets: ["ArrumatorCore"]),
        .library(name: "ArrumatorExtract", targets: ["ArrumatorExtract"]),
        .library(name: "ArrumatorClassify", targets: ["ArrumatorClassify"]),
        .library(name: "ArrumatorRuntime", targets: ["ArrumatorRuntime"]),
        .executable(name: "arrumator", targets: ["ArrumatorCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
        .package(url: "https://github.com/CoreOffice/CoreXLSX.git", from: "0.14.2"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
    ],
    targets: [
        .target(
            name: "ArrumatorCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [.copy("Resources/Defaults")],
            swiftSettings: strict
        ),
        .target(
            name: "ArrumatorExtract",
            dependencies: [
                "ArrumatorCore",
                .product(name: "CoreXLSX", package: "CoreXLSX"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: strict
        ),
        .target(
            name: "ArrumatorClassify",
            dependencies: ["ArrumatorCore"],
            resources: [.copy("Prompts")],
            swiftSettings: strict
        ),
        .target(
            name: "ArrumatorRuntime",
            dependencies: ["ArrumatorCore", "ArrumatorExtract", "ArrumatorClassify"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "ArrumatorCLI",
            dependencies: [
                "ArrumatorRuntime", "ArrumatorCore", "ArrumatorClassify",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strict
        ),
        .target(name: "ArrumatorTesting", dependencies: ["ArrumatorCore"], path: "Tests/Support", swiftSettings: strict),
        .testTarget(name: "ArrumatorCoreTests", dependencies: ["ArrumatorCore", "ArrumatorTesting"], swiftSettings: strict),
        .testTarget(name: "ArrumatorExtractTests", dependencies: ["ArrumatorExtract", "ArrumatorCore", "ArrumatorTesting"],
                    swiftSettings: strict),
        .testTarget(name: "ArrumatorClassifyTests", dependencies: ["ArrumatorClassify", "ArrumatorCore", "ArrumatorTesting"],
                    swiftSettings: strict),
        .testTarget(name: "ArrumatorRuntimeTests", dependencies: ["ArrumatorRuntime", "ArrumatorCore"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
