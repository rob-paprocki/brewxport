import Foundation
import BrewxPortCore

/// The light or dark appearance a demo window is forced into (`--appearance`).
public enum Appearance: String, Sendable { case light, dark }

/// How a demo launch is set up: parsed from the `--demo` flags, and what `DemoServices.make` builds from.
public struct DemoOptions: Equatable, Sendable {
    /// `--demo-fixtures <dir>`. Nil: the bundle's `Contents/Resources/DemoFixtures`.
    public var fixtures: URL?
    /// `--appearance light|dark`. Nil: the system's.
    public var appearance: Appearance?
    /// `--snapshot <dir>`: write PNGs there and quit.
    public var snapshot: URL?
    /// `--demo-arch arm64|x86_64`.
    public var host: Arch
    /// `--demo-bundle NAME`: one of `DemoSamples.names`, opened on Bundles at launch.
    public var bundle: String?

    public init() {
        fixtures = nil
        appearance = nil
        snapshot = nil
        host = .current
        bundle = nil
    }

    public static let fixturesFlag = "--demo-fixtures"
    public static let appearanceFlag = "--appearance"
    public static let snapshotFlag = "--snapshot"
    public static let archFlag = "--demo-arch"
    public static let bundleFlag = "--demo-bundle"

    /// Reads the demo flags. A flag whose value is missing, starts with `--` or isn't one BrewxPort knows is ignored.
    static func parse(_ flags: [String]) -> DemoOptions {
        var options = DemoOptions()
        var index = flags.startIndex
        while index < flags.endIndex {
            let flag = flags[index]
            let next = flags.index(after: index)
            guard [fixturesFlag, appearanceFlag, snapshotFlag, archFlag, bundleFlag].contains(flag),
                  next < flags.endIndex, !flags[next].hasPrefix("--") else {
                index = next
                continue
            }
            let value = flags[next]
            switch flag {
            case fixturesFlag: options.fixtures = URL(fileURLWithPath: value)
            case snapshotFlag: options.snapshot = URL(fileURLWithPath: value)
            case appearanceFlag: if let appearance = Appearance(rawValue: value) { options.appearance = appearance }
            case bundleFlag: if DemoSamples.names.contains(value) { options.bundle = value }
            default: if let arch = Arch(rawValue: value) { options.host = arch }
            }
            index = flags.index(after: next)
        }
        return options
    }
}

/// What the command line asks for. Parsed before anything else in `main`.
public enum LaunchMode: Equatable {
    case normal, selfCheck, demo(DemoOptions)

    public static let selfCheckFlag = "--self-check"
    public static let demoFlag = "--demo"
    /// scripts/demo.sh's bundle. It has no helper, so it never runs anything but the demo, whatever its arguments
    /// (a Finder double-click or `open` without `--demo`).
    public static let demoBundleIdentifier = "com.brewxport.demo"

    /// `arguments` is the whole argv, program path first. Unknown arguments (AppKit's `-NS…` defaults, `-psn_…`)
    /// are ignored. `--self-check` wins over `--demo`, except in the demo bundle, which is always the demo.
    public static func parse(_ arguments: [String], bundleIdentifier: String? = nil) -> LaunchMode {
        let flags = Array(arguments.dropFirst())
        if bundleIdentifier == demoBundleIdentifier { return .demo(DemoOptions.parse(flags)) }
        if flags.contains(selfCheckFlag) { return .selfCheck }
        if flags.contains(demoFlag) { return .demo(DemoOptions.parse(flags)) }
        return .normal
    }

    /// macOS opened BrewxPort as a login item: the launch's open-application Apple event says so in its property
    /// data (`keyAELaunchedAsLogInItem`). The app passes `NSAppleEventManager.shared().currentAppleEvent` from
    /// `applicationDidFinishLaunching`, the first moment it's there: in `main` and `applicationWillFinishLaunching`
    /// it's still nil.
    public static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
