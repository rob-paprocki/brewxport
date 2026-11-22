import Testing
@testable import BrewxPortRun

struct HelperStateDisplayTests {
    @Test func sidebarSubtitleForEachState() {
        #expect(HelperStateDisplay.shortText(for: nil) == "Checking…")
        #expect(HelperStateDisplay.shortText(for: .notRegistered) == "Not set up")
        #expect(HelperStateDisplay.shortText(for: .requiresApproval) == "Needs approval")
        #expect(HelperStateDisplay.shortText(for: .enabled) == "Ready")
        #expect(HelperStateDisplay.shortText(for: .outdated) == "Out of date")
        #expect(HelperStateDisplay.shortText(for: .failed("x")) == "Not working")
    }

    @Test func warningOnlyWhenTheHelperNeedsTheUser() {
        #expect(HelperStateDisplay.symbol(for: .enabled) == "checkmark.circle.fill")
        #expect(HelperStateDisplay.symbol(for: .requiresApproval) == "exclamationmark.triangle.fill")
        #expect(HelperStateDisplay.symbol(for: .failed("x")) == "exclamationmark.triangle.fill")
        for state: HelperState? in [nil, .notRegistered, .outdated] {
            #expect(HelperStateDisplay.symbol(for: state) == "minus.circle")
        }
    }

    @Test func aboutTextNamesWhereMacOSListsIt() {
        #expect(HelperStateDisplay.about.contains("Login Items & Extensions"))
        #expect(!HelperStateDisplay.about.contains("\n"))
    }
}
