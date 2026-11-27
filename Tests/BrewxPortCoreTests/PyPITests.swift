import Foundation
import Testing
@testable import BrewxPortCore

/// PyPI's captured answers live with pipx's captures (`Fixtures/pipx`, see its SOURCES.md).
private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pipx")

/// A captured PyPI answer (`GET https://pypi.org/pypi/<name>/json`), as its body.
private func pypiBody(_ name: String) throws -> String {
    try String(contentsOf: fixtures.appendingPathComponent("\(name).json"), encoding: .utf8)
}

/// The captured `pypi-cowsay.json` after `change` edits it as JSON. Not a new capture: the real one, edited, for a
/// case PyPI's answer for cowsay doesn't show (a yanked release, a Python requirement).
private func editedCowsay(_ change: (inout [String: Any]) -> Void) throws -> String {
    var json = try #require(try JSONSerialization.jsonObject(with: Data(pypiBody("pypi-cowsay").utf8)) as? [String: Any])
    change(&json)
    return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
}

private let cowsayURL = "https://pypi.org/pypi/cowsay/json"
private let blackURL = "https://pypi.org/pypi/black/json"

@Suite struct PyPITests {
    /// The newest release whose files aren't all yanked and whose Python requirement the tool's Python meets. Edits
    /// of the real cowsay answer.
    @Test func pypiSkipsYankedAndTooNewForThePython() throws {
        func project(_ body: String) throws -> PyPI.Project {
            try JSONDecoder().decode(PyPI.Project.self, from: Data(body.utf8))
        }
        let real = try project(try pypiBody("pypi-cowsay"))
        #expect(real.newerVersion(than: "5.0", python: "3.15.2") == "6.1")
        // 6.1 says >=3.8: a tool built on Python 3.7 gets 6.0.
        #expect(real.newerVersion(than: "5.0", python: "3.7.17") == "6.0")
        #expect(real.newerVersion(than: "6.1", python: "3.15.2") == nil)

        let yanked = try project(try editedCowsay { json in
            var releases = json["releases"] as! [String: [[String: Any]]]
            releases["6.1"] = releases["6.1"]!.map { var file = $0; file["yanked"] = true; return file }
            json["releases"] = releases
        })
        #expect(yanked.newerVersion(than: "5.0", python: "3.15.2") == "6.0")

        // Without `releases` (PyPI calls it deprecated), only `info.version` and its requirement are known.
        let infoOnly = try project(try editedCowsay { json in json.removeValue(forKey: "releases") })
        #expect(infoOnly.newerVersion(than: "5.0", python: "3.15.2") == "6.1")
        #expect(infoOnly.newerVersion(than: "5.0", python: "3.7.17") == nil)
    }

    @Test func pythonRequirements() {
        let python = "3.15.2"
        let allowed = [">=3.8", ">=3.8, <4", "==3.*", "~=3.10", ">=3.15.2", "<=3.15.2", "==3.15.2", "!=3.14.*",
                       "===3.15.2", ">=3.8,", "", " ",
                       // Not PEP 440: ignored, as pip ignores a requirement it can't read.
                       ">=3.6.*", "python3", ">= three"]
        for specifier in allowed {
            #expect(PyPI.pythonAllows(specifier, python: python), "\(specifier)")
        }
        for specifier in ["<3.15", "!=3.15.*", "~=3.16", "~=3.15.3", ">3.15.2", "!=3.15.2", "==3.15", ">=3.8,<3.15",
                          "==2.*"] {
            #expect(!PyPI.pythonAllows(specifier, python: python), "\(specifier)")
        }
        #expect(PyPI.pythonAllows(nil, python: python))
        #expect(PyPI.pythonAllows("<3", python: nil))
    }

    @Test func pythonVersionFromPipx() {
        #expect(PyPI.pythonVersion("Python 3.15.2") == "3.15.2")
        #expect(PyPI.pythonVersion("Python 3.15.0rc1") == "3.15.0")
        #expect(PyPI.pythonVersion("3.9.6") == "3.9.6")
        #expect(PyPI.pythonVersion("Python") == nil)
        #expect(PyPI.pythonVersion(nil) == nil)
    }

    /// A specifier BrewxPort can't read is nil, so each engine decides what that means (pipx's requires_python check
    /// lets it through, as pip does).
    @Test func specifiersBrewxPortCanRead() throws {
        for text in [">=3.6.*", "python3", ">= three", "~=3", "git+https://example.com/x.git", "==", "<"] {
            #expect(PyPI.Specifier(text) == nil, "\(text)")
        }
        let blank = try #require(PyPI.Specifier(" "))
        #expect(blank.allows("0.1"))
        let range = try #require(PyPI.Specifier(">=24, <24.3.0"))
        #expect(range.allows("24.2.0"))
        #expect(!range.allows("26.10.1"))
        #expect(!range.allows("23.12.1"))
        let pin = try #require(PyPI.Specifier("==0.6.0"))
        #expect(pin.allows("0.6.0"))
        #expect(!pin.allows("0.17.6"))
    }

    /// An exact pin (`==X`, `===X`) allows one version; a release must also meet a tool's own requirement (uv records
    /// the one a tool was installed with). The real cowsay answer.
    @Test func pinsAndRequirementsOnReleases() throws {
        for text in ["==0.6.0", "===0.6.0", " == 1.0 "] {
            #expect(PyPI.Specifier(text)?.isExact == true, "\(text)")
        }
        for text in ["==0.6.*", ">=1", "==1.0, !=1.1", ""] {
            #expect(PyPI.Specifier(text)?.isExact == false, "\(text)")
        }
        let cowsay = try JSONDecoder().decode(PyPI.Project.self, from: Data(try pypiBody("pypi-cowsay").utf8))
        #expect(cowsay.newerVersion(than: "5.0", python: "3.15.2", meeting: PyPI.Specifier("<6.1")) == "6.0")
        #expect(cowsay.newerVersion(than: "5.0", python: "3.15.2", meeting: PyPI.Specifier("==5.0")) == nil)
        #expect(cowsay.newerVersion(than: "5.0", python: "3.15.2", meeting: nil) == "6.1")
    }

    // MARK: lookups

    /// A lookup's errors are the asking engine's, and the name is checked as that engine's before anything is asked.
    @Test func lookupsSpeakForTheirEngine() async throws {
        let registry = FakeRegistryFetch([cowsayURL: .failure(RegistryFetchError.status(503))])
        do {
            _ = try await PyPI.project("cowsay", for: .uv, from: registry)
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.engine == .uv)
            #expect(error.message.contains("PyPI"))
        }
        await #expect(throws: EngineError.self) { _ = try await PyPI.project("bad name!", for: .uv, from: registry) }
        #expect(registry.requested.map(\.absoluteString) == [cowsayURL])
        // No such project is no answer, not an error.
        #expect(try await PyPI.project("Black", for: .uv, from: FakeRegistryFetch()) == nil)
    }

    /// Each name is looked up once, and one lookup failing doesn't stop the others.
    @Test func projectsKeepEachLookupsOwnAnswer() async throws {
        let registry = FakeRegistryFetch(bodies: [cowsayURL: try pypiBody("pypi-cowsay")])
        let answers = try await PyPI.projects(["cowsay", "black", "cowsay"], for: .pipx, from: registry)
        #expect(Set(answers.keys) == ["black", "cowsay"])
        #expect(try answers["cowsay"]?.get().info.version == "6.1")
        #expect(throws: EngineError.self) { _ = try answers["black"]?.get() }
        #expect(Set(registry.requested.map(\.absoluteString)) == [blackURL, cowsayURL])
        #expect(registry.requested.count == 2)
        #expect(PyPI.noAnswer(RegistryFetchError.status(503), for: .uv).engine == .uv)
        #expect(PyPI.noAnswer(RegistryFetchError.status(503), for: .uv).message
                .hasPrefix("BrewxPort couldn't check PyPI for newer versions: "))
    }

    /// One wording for every engine's failed lookups (PyPI, crates.io, RubyGems.org, GitHub), in a tool's reason and
    /// in a whole check's failure alike, never with URL credentials or a query. The address is built in parts so the
    /// repository check doesn't read it as an e-mail address.
    @Test func lookupFailuresNeverShowURLCredentials() throws {
        let url = "https://someone:" + "secret@" + "pypi.example.com/simple?token=abc"
        let failure = EngineError(engine: .pipx, message: "Couldn't reach \(url)")
        for text in [OutdatedLookups.describe(failure), PyPI.noAnswer(failure, for: .uv).message,
                     OutdatedLookups.describe(URLError(.notConnectedToInternet))] {
            #expect(!text.contains("secret") && !text.contains("token"), "\(text)")
        }
        #expect(OutdatedLookups.describe(failure) == "Couldn't reach https://pypi.example.com/simple")
        let refused = RegistryFetchError.status(404)
        #expect(OutdatedLookups.describe(refused) == String(describing: refused))
        let crates = [CargoEngine.Crate(name: "ripgrep", version: "14.1.0", source: .cratesIO, bins: ["rg"])]
        do {
            _ = try CargoEngine.updates(crates, index: ["ripgrep": .failure(failure)], rust: nil)
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.message == "BrewxPort couldn't check crates.io for newer versions: Couldn't reach "
                    + "https://pypi.example.com/simple")
        }
    }
}
