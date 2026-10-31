// swift-tools-version: 6.2

import PackageDescription

/// The LGPL FFmpeg that AudioEngine links (AudioEngine/Package.swift, ADR-096).
/// Presence imports Playback, which imports AudioEngine, so Swift loads the
/// CFFmpeg module here too and the headers must be named. Never point this at
/// /opt/homebrew/include: that is Homebrew's GPL FFmpeg.
let ffmpegPrefix = Context.environment["FFMPEG_PREFIX"]
    ?? "\(Context.packageDirectory)/../../build/ffmpeg-lgpl"

let package = Package(
    name: "Presence",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "Presence", targets: ["Presence"]),
    ],
    dependencies: [
        .package(path: "../Observability"),
        .package(path: "../AudioEngine"),
        .package(path: "../Playback"),
    ],
    targets: [
        .target(
            name: "Presence",
            dependencies: [
                .product(name: "Observability", package: "Observability"),
                // PlaybackState comes from AudioEngine (Playback re-observes it);
                // the transitive CFFmpeg header flag below is load-bearing.
                .product(name: "AudioEngine", package: "AudioEngine"),
                .product(name: "Playback", package: "Playback"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .unsafeFlags(["-Xcc", "-I\(ffmpegPrefix)/include"]),
            ]
        ),
        .testTarget(
            name: "PresenceTests",
            dependencies: [
                "Presence",
                .product(name: "Observability", package: "Observability"),
                .product(name: "AudioEngine", package: "AudioEngine"),
                .product(name: "Playback", package: "Playback"),
            ],
            path: "Tests/PresenceTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                // Loading Presence loads CFFmpeg transitively, so the test
                // target names the same headers (see the note above).
                .unsafeFlags(["-Xcc", "-I\(ffmpegPrefix)/include"]),
            ]
        ),
    ]
)
