// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrewxPortCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BrewxPortCore", targets: ["BrewxPortCore"]),
        .library(name: "BrewxPortRun", targets: ["BrewxPortRun"]),
        .executable(name: "BrewxPort", targets: ["BrewxPort"]),
        .executable(name: "BrewxPortHelper", targets: ["BrewxPortHelper"]),
        .executable(name: "brewxport-askpass", targets: ["brewxport-askpass"]),
    ],
    targets: [
        .target(name: "BrewxPortCore"),
        .target(name: "BrewxPortRun", dependencies: ["BrewxPortCore"]),
        // The SwiftUI views, view models and service seams.
        .target(name: "BrewxPortUI", dependencies: ["BrewxPortCore", "BrewxPortRun"]),
        // A check tool, never shipped. `login-path` runs the app's login-shell PATH probe (Tests/scripts).
        .executableTarget(name: "brewxport-smoke", dependencies: ["BrewxPortCore", "BrewxPortUI"]),
        // The app. scripts/build-app.sh puts it in BrewxPort.app with the helper and brewxport-askpass.
        .executableTarget(name: "BrewxPort", dependencies: ["BrewxPortCore", "BrewxPortRun", "BrewxPortUI"]),
        // The root LaunchDaemon. Task 11's build script embeds its Info.plist (BrewxPortClientRequirement).
        .executableTarget(name: "BrewxPortHelper", dependencies: ["BrewxPortRun"]),
        // sudo's SUDO_ASKPASS helper. Darwin only, no dependencies: it handles the password.
        .executableTarget(name: "brewxport-askpass"),
        .testTarget(name: "BrewxPortCoreTests", dependencies: ["BrewxPortCore"], exclude: ["Fixtures"]),
        .testTarget(name: "BrewxPortRunTests", dependencies: ["BrewxPortRun", "BrewxPortCore"], exclude: ["Fixtures"]),
        .testTarget(name: "BrewxPortUITests", dependencies: ["BrewxPortUI", "BrewxPortCore", "BrewxPortRun"]),
    ],
    swiftLanguageModes: [.v6]
)
