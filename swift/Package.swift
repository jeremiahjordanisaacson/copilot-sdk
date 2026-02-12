// swift-tools-version: 5.9
// ----------------------------------------------------------------------------------------------------
//  Copyright (c) Microsoft Corporation. All rights reserved.
// ----------------------------------------------------------------------------------------------------

import PackageDescription

let package = Package(
    name: "CopilotSDK",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(
            name: "CopilotSDK",
            targets: ["CopilotSDK"]
        ),
    ],
    targets: [
        .target(
            name: "CopilotSDK",
            path: "Sources/CopilotSDK"
        ),
        .executableTarget(
            name: "BasicExample",
            dependencies: ["CopilotSDK"],
            path: "Examples/BasicExample"
        ),
    ]
)
