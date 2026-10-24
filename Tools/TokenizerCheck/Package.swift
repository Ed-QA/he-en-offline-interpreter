// swift-tools-version: 5.9
import PackageDescription

// Standalone macOS check: loads the generated Model/ folder with the exact same
// swift-transformers code the iOS app uses, so tokenizer problems surface in CI
// instead of on the phone.
let package = Package(
    name: "TokenizerCheck",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "TokenizerCheck",
            dependencies: [.product(name: "Tokenizers", package: "swift-transformers")]
        )
    ]
)
