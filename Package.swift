// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AK820Mac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AK820Mac", targets: ["AK820Mac"])
    ],
    targets: [
        .executableTarget(
            name: "AK820Mac",
            path: "Sources/AK820Mac",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        )
    ]
)
