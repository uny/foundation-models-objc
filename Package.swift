// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FoundationModelsObjC",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "FoundationModelsObjC", type: .static, targets: ["FoundationModelsObjC"]),
    ],
    targets: [
        .target(
            name: "FoundationModelsObjC",
            linkerSettings: [.linkedFramework("FoundationModels")]
        ),
    ]
)
