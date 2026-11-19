import Testing
import Foundation
@testable import BrewxPortUI

@Suite struct StartupPolicyTests {
    @Test func normalOnMarkedMacIsNotice() {
        #expect(StartupPolicy.decide(mode: .normal, developmentMac: true) == .developmentMacNotice)
    }

    @Test func normalOnUnmarkedMacIsLive() {
        #expect(StartupPolicy.decide(mode: .normal, developmentMac: false) == .live)
    }

    @Test func demoAndSelfCheckIgnoreTheMarker() {
        for marked in [true, false] {
            #expect(StartupPolicy.decide(mode: .demo(DemoOptions()), developmentMac: marked) == .demo)
            #expect(StartupPolicy.decide(mode: .selfCheck, developmentMac: marked) == .live)
        }
    }

    @Test func markerValueIsReadWithoutDisk() {
        #expect(StartupPolicy.developmentMacFlag(from: nil) == false)
        #expect(StartupPolicy.developmentMacFlag(from: kCFBooleanTrue) == true)
        #expect(StartupPolicy.developmentMacFlag(from: kCFBooleanFalse) == false)
        #expect(StartupPolicy.developmentMacFlag(from: true as NSNumber) == true)
        #expect(StartupPolicy.developmentMacFlag(from: false as NSNumber) == false)
        #expect(StartupPolicy.developmentMacFlag(from: NSNumber(value: 1)) == true)
        #expect(StartupPolicy.developmentMacFlag(from: NSNumber(value: 0)) == false)
        for text in ["1", "true", "yes", "TRUE", "Yes"] {
            #expect(StartupPolicy.developmentMacFlag(from: text as NSString) == true, "\(text)")
        }
        for text in ["0", "false", "no", "", "maybe"] {
            #expect(StartupPolicy.developmentMacFlag(from: text as NSString) == false, "\(text)")
        }
        #expect(StartupPolicy.developmentMacFlag(from: [1] as NSArray) == false)
    }

    @Test func markerLivesInTheAppDomain() {
        #expect(StartupPolicy.developmentMacKey == "BrewxPortDevelopmentMac")
        #expect(StartupPolicy.domain == "com.brewxport.app")
        #expect(StartupPolicy.developmentMacNotice == "This Mac is marked as a development Mac, so BrewxPort won't touch "
                + "its engines or its helper here. Launch it with --demo.")
    }
}

@Suite struct MainWindowSizeTests {
    @Test func firstWindowFitsTheDisplay() {
        // A big display gets the ideal size; a small one a window inside its visible area; never below the minimum.
        #expect(MainWindowSize.initial(visible: CGSize(width: 2560, height: 1400)) == CGSize(width: 1200, height: 760))
        #expect(MainWindowSize.initial(visible: CGSize(width: 1180, height: 740)) == CGSize(width: 1100, height: 660))
        #expect(MainWindowSize.initial(visible: CGSize(width: 800, height: 500)) == MainWindowSize.minimum)
    }
}
