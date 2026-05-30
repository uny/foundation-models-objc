// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OnDeviceLlmBridge",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "OnDeviceLlmBridge", type: .static, targets: ["OnDeviceLlmBridge"]),
    ],
    targets: [
        .target(
            name: "OnDeviceLlmBridge",
            linkerSettings: [.linkedFramework("FoundationModels")]
        ),
    ]
)
