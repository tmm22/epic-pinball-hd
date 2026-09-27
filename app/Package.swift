// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EpicPinball",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EpicPinball", targets: ["EpicPinball"]),
        .library(name: "PinballCore", targets: ["PinballCore"]),
        .library(name: "PinballAudio", targets: ["PinballAudio"]),
    ],
    targets: [
        // Platform-agnostic logic: asset parsing, simulation, camera, viewport maths.
        // Foundation only - no AppKit / Metal - so it is unit-testable anywhere.
        .target(name: "PinballCore"),

        // Metal renderer (no AppKit). Used by both the windowed app and the headless
        // snapshot mode. The shader is shipped as a plain-text resource and compiled at
        // runtime with MTLDevice.makeLibrary(source:), so `swift build` never needs the
        // offline Metal compiler.
        .target(
            name: "PinballRender",
            dependencies: ["PinballCore"],
            resources: [.copy("Shaders/Pinball.metal")]
        ),

        // libopenmpt (Homebrew) for PSM music; found via pkg-config.
        .systemLibrary(
            name: "COpenMPT",
            pkgConfig: "libopenmpt",
            providers: [.brew(["libopenmpt"])]
        ),

        // Sound effects + music playback (AVAudioEngine). No AppKit / Metal.
        .target(
            name: "PinballAudio",
            dependencies: ["PinballCore", "COpenMPT"]
        ),

        // AppKit + MetalKit front end and command-line handling.
        .executableTarget(
            name: "EpicPinball",
            dependencies: ["PinballCore", "PinballRender", "PinballAudio"]
        ),

        .testTarget(
            name: "PinballAudioTests",
            dependencies: ["PinballAudio"]
        ),

        .testTarget(
            name: "PinballCoreTests",
            dependencies: ["PinballCore", "PinballRender"]
        ),
    ]
)
