// swift-tools-version:6.0
// Whisperer: local Superwhisper clone. Built by build.sh (Command Line Tools only, no Xcode).
import PackageDescription

let brew = "/opt/homebrew"
let cFlags: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(brew)/include", "-Xcc", "-I\(brew)/opt/whisper.cpp/include"])]
let linkFlags: [LinkerSetting] = [
    .unsafeFlags(["-L\(brew)/opt/whisper.cpp/lib", "-L\(brew)/opt/ggml/lib",
                  "-Xlinker", "-rpath", "-Xlinker", "\(brew)/opt/whisper.cpp/lib"]),
    .linkedLibrary("whisper"), .linkedLibrary("ggml"), .linkedLibrary("ggml-base"),
]

let package = Package(
    name: "Whisperer",
    platforms: [.macOS("26.0")],
    targets: [
        .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),
        .target(name: "WhispererCore", dependencies: ["CWhisper"], swiftSettings: cFlags, linkerSettings: linkFlags),
        .executableTarget(name: "Whisperer", dependencies: ["WhispererCore"], swiftSettings: cFlags, linkerSettings: linkFlags),
        .executableTarget(name: "Bench", dependencies: ["WhispererCore"], swiftSettings: cFlags, linkerSettings: linkFlags),
        .executableTarget(name: "CoreChecks", dependencies: ["WhispererCore"], swiftSettings: cFlags, linkerSettings: linkFlags),
    ],
    swiftLanguageModes: [.v5]
)
