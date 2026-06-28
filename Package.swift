// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Pure, framework-free logic (e.g. transcript composition) so it can be unit
        // tested deterministically without Speech/AVFoundation.
        .target(
            name: "VoiceInputCore",
            path: "Sources/VoiceInputCore"
        ),
        .executableTarget(
            name: "VoiceInput",
            dependencies: ["VoiceInputCore"],
            path: "Sources/VoiceInput",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        // A plain executable test runner (not XCTest) so the suite runs with only the
        // Xcode Command Line Tools — `swift run TranscriptComposerTests`. Exits non-zero
        // on any failure.
        .executableTarget(
            name: "TranscriptComposerTests",
            dependencies: ["VoiceInputCore"],
            path: "Tests/VoiceInputCoreTests"
        )
    ]
)
