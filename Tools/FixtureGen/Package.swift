// swift-tools-version: 6.2
import PackageDescription

// Renders the synthetic fixture corpus in Tests/Fixtures. Deliberately separate from the app package:
// it has no dependencies and is only needed when the corpus changes.
let package = Package(
    name: "FixtureGen",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "fixturegen",
            path: "Sources/FixtureGen",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny"), .treatAllWarnings(as: .error)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
