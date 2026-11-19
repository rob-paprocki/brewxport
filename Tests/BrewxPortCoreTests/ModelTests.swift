import Foundation
import Testing
@testable import BrewxPortCore

@Test func refsFromDifferentEnginesDiffer() {
    #expect(PackageRef(engine: .homebrew, kind: .formula, name: "ripgrep")
         != PackageRef(engine: .macports, kind: .port, name: "ripgrep"))
}

@Test func refRoundTripsThroughJSON() throws {
    let r = PackageRef(engine: .mas, kind: .app, name: "640199958")
    #expect(try JSONDecoder().decode(PackageRef.self, from: JSONEncoder().encode(r)) == r)
}
