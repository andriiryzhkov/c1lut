// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "c1lut",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "c1lut", targets: ["c1lut"]),
    ],
    targets: [
        // Pure LUT / grid / image logic. Uses only Apple system frameworks.
        .target(name: "C1LUTCore"),
        // Command-line front end used by the Capture One script. The AppleScripts are compiled
        // into the binary so a release is a single file; `c1lut install` writes them out.
        .executableTarget(
            name: "c1lut",
            dependencies: ["C1LUTCore"],
            resources: [
                .embedInCode("Scripts/launcher.applescript"),
                .embedInCode("Scripts/worker.applescript"),
            ]
        ),
        .testTarget(name: "C1LUTCoreTests", dependencies: ["C1LUTCore"]),
    ]
)
