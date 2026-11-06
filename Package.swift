// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "LocalSTT", platforms: [.macOS(.v14)],
    products: [.executable(name: "LocalSTT", targets: ["LocalSTT"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.18.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.6")
    ],
    targets: [
        .executableTarget(name: "LocalSTT", dependencies: [
            .product(name: "WhisperKit", package: "WhisperKit"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ], resources: [.copy("LocalModels.json")]),
        .testTarget(name: "LocalSTTTests", dependencies: ["LocalSTT"])
    ]
)
