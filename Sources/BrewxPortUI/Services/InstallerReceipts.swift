import Foundation
import BrewxPortCore

/// Reads the installer receipts the `.pkg` leaves behind.
public protocol InstallerReceiptReading: Sendable {
    /// When the package with this ID was installed; nil when there's no receipt or it can't be read.
    func installDate(_ packageID: String) async -> Date?
}

public enum InstallerReceipt {
    public static let appPackageID = "com.brewxport.app.pkg"
    public static let setupChoicePackageID = "com.brewxport.setup-engine.pkg"
    /// How much older than the app's own receipt the setup marker may be and still count as the same install.
    public static let tolerance: TimeInterval = 60

    /// The "Set up …" checkbox was ticked in this install: the marker receipt exists and is no older than the app's
    /// receipt (less a minute, for the two components being written one after the other). With no app receipt
    /// (a DMG or zip install) the marker can only be left over from an earlier install, so it doesn't count.
    public static func setupChoiceIsCurrent(_ receipts: any InstallerReceiptReading) async -> Bool {
        await setupChoiceDate(receipts) != nil
    }

    /// The marker's install date when the choice is current, else nil.
    public static func setupChoiceDate(_ receipts: any InstallerReceiptReading) async -> Date? {
        guard let marker = await receipts.installDate(setupChoicePackageID),
              let app = await receipts.installDate(appPackageID),
              marker >= app.addingTimeInterval(-tolerance) else { return nil }
        return marker
    }
}

/// Demo mode and anywhere else with no installer: there are never receipts.
public struct NoReceipts: InstallerReceiptReading {
    public init() {}
    public func installDate(_ packageID: String) async -> Date? { nil }
}

/// `pkgutil --pkg-info-plist <id>`, whose `install-time` is seconds since 1970.
public struct PkgutilReceipts: InstallerReceiptReading {
    private let runner: any CommandRunning
    private let pkgutil: URL

    public init(runner: any CommandRunning, pkgutil: URL = URL(fileURLWithPath: "/usr/sbin/pkgutil")) {
        self.runner = runner
        self.pkgutil = pkgutil
    }

    public func installDate(_ packageID: String) async -> Date? {
        guard let result = try? await runner.run(
            pkgutil, ["--pkg-info-plist", packageID], options: RunOptions(timeout: BrewxPortTimeouts.engineQuery)),
              result.exitCode == 0 else { return nil }
        return Self.installDate(fromPlist: Data(result.stdout.utf8))
    }

    static func installDate(fromPlist data: Data) -> Date? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let seconds = dict["install-time"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: seconds.doubleValue)
    }
}
