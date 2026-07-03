// swift-tools-version: 5.9
//
// Headless test harness for the engine core.
//
// The engine was designed GPU-free (Engine.swift imports Foundation
// only; nothing in Core/Logic/Physics/Scene/Platform needs a window
// or a GPU device to COMPILE), so the same sources the Xcode app
// builds can be compiled as a plain SwiftPM library and unit-tested
// on any Mac — including CI runners — with `swift test`.
//
// The macOS editor app still builds from IngotEngine.xcodeproj; this
// manifest exists solely for tests and CI. AppShell/ and Rendering/
// are deliberately not part of the library.
//
import PackageDescription

let package = Package(
    name: "IngotEngineCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "IngotEngineCore",
            path: "IngotEngine",
            sources: ["Core", "Logic", "Physics", "Scene", "Platform"]
        ),
        .testTarget(
            name: "EngineTests",
            dependencies: ["IngotEngineCore"],
            path: "EngineTests"
        ),
    ]
)
