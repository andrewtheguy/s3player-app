// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "S3PlayerApp",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "S3PlayerKit",
            targets: ["S3PlayerKit"]
        ),
        .executable(
            name: "s3-smoke-test",
            targets: ["S3SmokeTest"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/awslabs/aws-sdk-swift",
            from: "1.6.106"
        )
    ],
    targets: [
        .target(
            name: "S3PlayerKit",
            dependencies: [
                .product(name: "AWSS3", package: "aws-sdk-swift"),
                .product(name: "AWSSDKIdentity", package: "aws-sdk-swift")
            ]
        ),
        .executableTarget(
            name: "S3SmokeTest",
            dependencies: ["S3PlayerKit"],
            path: "Sources/S3SmokeTest"
        ),
        .testTarget(
            name: "S3PlayerKitTests",
            dependencies: ["S3PlayerKit"],
            path: "Tests/S3PlayerKitTests"
        )
    ]
)
