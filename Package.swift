// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nobet",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "Nobet",
            path: "Sources/Nobet"
        ),
        .testTarget(
            name: "NobetTests",
            dependencies: ["Nobet"],
            path: "Tests/NobetTests"
        )
    ]
)
