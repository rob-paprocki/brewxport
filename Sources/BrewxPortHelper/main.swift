// BrewxPortHelper: the root LaunchDaemon (SMAppService, bundled by Task 11). It runs only allow-listed MacPorts
// `port` commands, for a client that matches BrewxPortClientRequirement and holds the com.brewxport.run right.
import Foundation
import BrewxPortRun

guard getuid() == 0 else {
    // Outside launchd as root, setting the right could put up a dialog; never try.
    FileHandle.standardError.write(Data("BrewxPortHelper runs only as a root LaunchDaemon.\n".utf8))
    exit(EXIT_FAILURE)
}
helperLog.notice("starting, version \(brewxPortHelperVersion)")

let requirement = HelperClientRequirement.read(from: Bundle.main.infoDictionary)
if requirement == nil {
    helperLog.fault("no usable \(brewxPortClientRequirementKey, privacy: .public) in Info.plist; refusing every connection")
}

// R8: overwrite whatever com.brewxport.run says now, so a weaker definition planted earlier can't stand.
let rightInstall = HelperAuthorization.installRight()
let rightReady = rightInstall == .installed
if !rightReady {
    helperLog.fault("couldn't install \(brewxPortRunRight, privacy: .public) (\(String(describing: rightInstall), privacy: .public)); refusing every run")
}

let listener = NSXPCListener(machServiceName: brewxPortHelperMachService)
if let requirement { listener.setConnectionCodeSigningRequirement(requirement) }
let delegate = ListenerDelegate(requirement: requirement, rightReady: rightReady)
listener.delegate = delegate
listener.resume()
dispatchMain()
