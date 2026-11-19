import Testing
import Foundation
import Security
@testable import BrewxPortRun

@Suite struct HelperAuthorizationTests {
    @Test func rightNameAndRuleMatchTheSpike() {
        #expect(brewxPortRunRight == "com.brewxport.run")
        let rule = BrewxPortRunRule.dictionary
        #expect(rule["class"] as? String == "user")
        #expect(rule["group"] as? String == "admin")
        #expect(rule["authenticate-user"] as? Bool == true)
        #expect(rule["allow-root"] as? Bool == false)
        #expect(rule["shared"] as? Bool == false)
        #expect(rule["session-owner"] as? Bool == false)
        #expect(rule["timeout"] as? Int == 300)
    }

    /// What `AuthorizationRightGet` hands back: CF types, plus keys authd adds itself.
    private func installed(_ changes: [String: Any?] = [:]) -> [String: Any] {
        var d: [String: Any] = [
            "class": "user" as NSString, "group": "admin" as NSString,
            "authenticate-user": kCFBooleanTrue!, "allow-root": kCFBooleanFalse!,
            "shared": kCFBooleanFalse!, "session-owner": kCFBooleanFalse!,
            "timeout": NSNumber(value: 300), "version": NSNumber(value: 1),
            "created": NSNumber(value: 785_000_000.0), "modified": NSNumber(value: 785_000_000.0),
            "requirement": "identifier \"com.brewxport.helper\"" as NSString, "comment": "x" as NSString,
        ]
        for (k, v) in changes { d[k] = v }
        return d
    }

    @Test func acceptsTheInstalledDefinition() {
        #expect(BrewxPortRunRule.matches(installed()))
        #expect(BrewxPortRunRule.matches(BrewxPortRunRule.dictionary))
        // authd stores the false flags as bits defaulting to off, so it may leave them out.
        #expect(BrewxPortRunRule.matches(installed(["shared": nil, "allow-root": nil, "session-owner": nil])))
    }

    @Test func refusesAWeakerDefinition() {
        let weaker: [[String: Any?]] = [
            ["allow-root": kCFBooleanTrue!], ["shared": kCFBooleanTrue!], ["session-owner": kCFBooleanTrue!],
            ["authenticate-user": kCFBooleanFalse!], ["authenticate-user": nil],
            ["timeout": NSNumber(value: 0)], ["timeout": NSNumber(value: 86_400)], ["timeout": nil],
            ["class": "allow" as NSString], ["class": "rule" as NSString], ["class": nil],
            ["group": "staff" as NSString], ["group": nil],
            ["rule": ["allow"] as NSArray], ["mechanisms": ["builtin:x"] as NSArray],
            ["k-of-n": NSNumber(value: 1)], ["allow-root": "false" as NSString],
        ]
        for change in weaker {
            #expect(!BrewxPortRunRule.matches(installed(change)), "should refuse \(change)")
        }
    }

    @Test func externalFormMustBeExactly32Bytes() throws {
        #expect(Int(kAuthorizationExternalFormLength) == 32)
        for n in [0, 1, 31, 33, 64, 4096] {
            #expect(throws: HelperError.notAuthorized) {
                _ = try HelperAuthorization.externalForm(from: Data(repeating: 7, count: n))
            }
            #expect(throws: HelperError.notAuthorized) {
                try HelperAuthorization.authorize(externalForm: Data(repeating: 7, count: n))
            }
        }
        let bytes = Data((0..<32).map { UInt8($0) })
        var form = try HelperAuthorization.externalForm(from: bytes)
        #expect(withUnsafeBytes(of: &form) { Data($0) } == bytes)
    }

    /// Asks authd about random bytes; no daemon, no right change, no UI (flags never allow interaction).
    @Test func garbageExternalFormIsNotAuthorized() {
        let garbage = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        #expect(throws: HelperError.notAuthorized) {
            try HelperAuthorization.authorize(externalForm: garbage)
        }
    }

    @Test func interfacePinsArgumentClasses() {
        let sel = #selector(BrewxPortHelperProtocol.runPort(authorization:arguments:reply:))
        let classes = HelperInterfaces.helper().classes(for: sel, argumentIndex: 1, ofReply: false)
        #expect(classes.count == 2)
        #expect(classes.contains(NSArray.self as AnyObject as! AnyHashable))
        #expect(classes.contains(NSString.self as AnyObject as! AnyHashable))
    }
}

@Suite struct HelperClientRequirementTests {
    @Test func readsAParsableRequirement() {
        let req = "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and identifier \"com.brewxport.app\""
        #expect(HelperClientRequirement.read(from: [brewxPortClientRequirementKey: req]) == req)
        #expect(HelperClientRequirement.read(from: [brewxPortClientRequirementKey: "  \(req)\n"]) == req)
    }

    @Test func missingBlankOrBrokenRequirementRefusesEveryone() {
        #expect(HelperClientRequirement.read(from: nil) == nil)
        #expect(HelperClientRequirement.read(from: [:]) == nil)
        #expect(HelperClientRequirement.read(from: [brewxPortClientRequirementKey: ""]) == nil)
        #expect(HelperClientRequirement.read(from: [brewxPortClientRequirementKey: " \n\t"]) == nil)
        #expect(HelperClientRequirement.read(from: [brewxPortClientRequirementKey: NSNumber(value: 1)]) == nil)
        #expect(HelperClientRequirement.read(from: [brewxPortClientRequirementKey: "identifier and and ("]) == nil)
    }
}
