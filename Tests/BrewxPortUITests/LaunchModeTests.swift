import Testing
import Foundation
@testable import BrewxPortUI

@Suite struct LaunchModeTests {
    static let program = "/Applications/BrewxPort.app/Contents/MacOS/BrewxPort"

    @Test func parsesSelfCheck() {
        #expect(LaunchMode.parse([Self.program, "--self-check"]) == .selfCheck)
        // --self-check wins over --demo, whichever comes first.
        #expect(LaunchMode.parse([Self.program, "--demo", "--self-check"]) == .selfCheck)
    }

    @Test func parsesDemoAndNormal() {
        #expect(LaunchMode.parse([Self.program, "--demo"]) == .demo(DemoOptions()))
        #expect(LaunchMode.parse([Self.program]) == .normal)
        #expect(LaunchMode.parse([]) == .normal)
    }

    @Test func ignoresUnknownArgumentsAndTheProgramPath() {
        #expect(LaunchMode.parse([Self.program, "-NSDocumentRevisionsDebugMode", "YES", "-psn_0_12345"]) == .normal)
        // Only flags count, never argv[0].
        #expect(LaunchMode.parse(["--self-check"]) == .normal)
    }

    @Test func demoBundleIsAlwaysTheDemo() {
        let demo = "com.brewxport.demo"
        #expect(LaunchMode.parse([Self.program], bundleIdentifier: demo) == .demo(DemoOptions()))
        #expect(LaunchMode.parse([Self.program, "--self-check"], bundleIdentifier: demo) == .demo(DemoOptions()))
        var dark = DemoOptions()
        dark.appearance = .dark
        #expect(LaunchMode.parse([Self.program, "--appearance", "dark"], bundleIdentifier: demo) == .demo(dark))
        // The real bundle, and `swift run` (no bundle id), still need the flag.
        #expect(LaunchMode.parse([Self.program], bundleIdentifier: "com.brewxport.app") == .normal)
        #expect(LaunchMode.parse([Self.program], bundleIdentifier: nil) == .normal)
    }

    @Test func demoBundleFlagParsed() {
        var inventory = DemoOptions()
        inventory.bundle = "inventory"
        #expect(LaunchMode.parse([Self.program, "--demo", "--demo-bundle", "inventory"]) == .demo(inventory))
        var brewfile = DemoOptions()
        brewfile.bundle = "brewfile"
        brewfile.appearance = .dark
        #expect(LaunchMode.parse([Self.program, "--demo-bundle", "brewfile", "--appearance", "dark"],
                                 bundleIdentifier: "com.brewxport.demo") == .demo(brewfile))
        // An unknown sample, a path, or a missing value is ignored; without --demo it's not a demo.
        #expect(LaunchMode.parse([Self.program, "--demo", "--demo-bundle", "vm-export"]) == .demo(DemoOptions()))
        #expect(LaunchMode.parse([Self.program, "--demo", "--demo-bundle", "/tmp/x.brewxportbundle"])
                == .demo(DemoOptions()))
        #expect(LaunchMode.parse([Self.program, "--demo", "--demo-bundle"]) == .demo(DemoOptions()))
        #expect(LaunchMode.parse([Self.program, "--demo-bundle", "inventory"]) == .normal)
    }

    /// The launch event the way loginwindow sends it: an open-application event whose property data says "login item".
    static func openEvent(_ property: NSAppleEventDescriptor?,
                          eventID: AEEventID = AEEventID(kAEOpenApplication)) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: eventID,
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        if let property { event.setParam(property, forKeyword: AEKeyword(keyAEPropData)) }
        return event
    }

    @Test func loginItemLaunchIsReadFromTheLaunchEvent() {
        let loginItem = NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem))
        #expect(LaunchMode.isLoginItemLaunch(Self.openEvent(loginItem)))
        // A plain launch (Finder, Dock, `open`), no event at all, or a reopen are not.
        #expect(!LaunchMode.isLoginItemLaunch(Self.openEvent(nil)))
        #expect(!LaunchMode.isLoginItemLaunch(nil))
        #expect(!LaunchMode.isLoginItemLaunch(Self.openEvent(loginItem, eventID: AEEventID(kAEReopenApplication))))
        // Another enum in the same place (a service launch, say) is not a login item either.
        #expect(!LaunchMode.isLoginItemLaunch(Self.openEvent(NSAppleEventDescriptor(
            enumCode: OSType(keyAELaunchedAsServiceItem)))))
    }
}
