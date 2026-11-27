import Foundation
import Testing
@testable import BrewxPortCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

/// A captured stderr file (see each engine's SOURCES.md).
private func capturedStderr(_ path: String) throws -> String {
    try String(contentsOf: fixtures.appendingPathComponent(path), encoding: .utf8)
}

/// None of these strings is a capture: no captured output had credentials in it, so they're written to look like what
/// pip, pipx, uv and npm print around an index or registry URL.
@Suite struct CredentialScrubberTests {
    private func expectScrubbed(_ cases: KeyValuePairs<String, String>) {
        for (text, expected) in cases {
            #expect(CredentialScrubber.scrub(text) == expected, "\(text)")
        }
    }

    /// A URL's user name and password (or token) are taken out, wherever the URL is, and each of two URLs side by
    /// side is cleaned on its own.
    @Test func urlsLoseTheirUserinfo() {
        expectScrubbed([
            "Looking in indexes: https://__token__:s3cret@pypi.example.com/simple/":
                "Looking in indexes: https://pypi.example.com/simple/",
            "git+https://someone@example.com/x.git and http://a:b@c.example.com/d":
                "git+https://example.com/x.git and http://c.example.com/d",
            // uv masks the password itself; the user name goes too.
            "error: Failed to fetch: `https://__token__:****@pypi.example.com/simple/isort/`":
                "error: Failed to fetch: `https://pypi.example.com/simple/isort/`",
            // A password with an `@` that should have been %40: everything up to the last one before the path.
            "https://user:p@ss@pypi.example.com/simple": "https://pypi.example.com/simple",
            "(https://aws:s3cret@repo.example.com/pypi/simple/)": "(https://repo.example.com/pypi/simple/)",
            // Two URLs with nothing but a comma between them: the second `scheme://` splits them.
            "https://a:s3cret@one.example.com/x,https://c:s3cret@two.example.com/y":
                "https://one.example.com/x,https://two.example.com/y",
            // A comma is legal in a password.
            "https://u:pa,s3cret@pypi.example.com/simple": "https://pypi.example.com/simple",
            // A URL inside another one's query.
            "https://pypi.example.com/simple/?redirect=https://u:s3cret@other.example.com/":
                "https://pypi.example.com/simple/https://other.example.com/",
        ])
    }

    /// A password with an unencoded `'`, `)`, `/`, `?` or `#` goes too; an `@` after a `/` is a path, as in npm's
    /// scoped packages, and a git URL's `@ref` stays.
    @Test func awkwardPasswordsGoAndPathsStay() {
        expectScrubbed([
            "https://user:pa'ss@pypi.example.com/simple": "https://pypi.example.com/simple",
            "https://user:pa)ss@pypi.example.com/simple": "https://pypi.example.com/simple",
            "https://user:pa/ss@pypi.example.com/simple/x": "https://pypi.example.com/simple/x",
            "https://user:pa?ss@pypi.example.com/simple": "https://pypi.example.com/simple",
            "https://me@example.com:pa/ss@pypi.example.com/simple": "https://pypi.example.com/simple",
        ])
        for text in ["https://registry.npmjs.org/@scope%2fname",
                     "https://registry.npmjs.org/@scope/name/-/name-1.0.0.tgz",
                     "https://registry.npmjs.org:443/@scope/name", "git+https://github.com/someone/tool.git@v1.0",
                     "http://[::1]:8080/simple/"] {
            #expect(CredentialScrubber.scrub(text) == text, "\(text)")
        }
        #expect(CredentialScrubber.scrub("https://u:s3cret@npm.example.com/@scope/name")
                == "https://npm.example.com/@scope/name")
    }

    /// Every URL loses its query, whatever it holds; a fragment stays.
    @Test func queriesAreTakenOut() {
        expectScrubbed([
            "Failed to fetch: https://pypi.example.com/simple/isort/?token=s3cret":
                "Failed to fetch: https://pypi.example.com/simple/isort/",
            "Looking in indexes: https://pypi.example.com/simple?t=s3cret":
                "Looking in indexes: https://pypi.example.com/simple",
            "https://files.example.com/a.whl?X-Amz-Signature=s3cret&X-Amz-Expires=60 then":
                "https://files.example.com/a.whl then",
            "https://pypi.example.com/simple/?page=2&api_key=s3cret#files": "https://pypi.example.com/simple/#files",
            "'https://pypi.example.com/simple?Password=s3cret'": "'https://pypi.example.com/simple'",
            "(https://pypi.example.com/simple?s3cret)": "(https://pypi.example.com/simple)",
            "https://pypi.org/simple/?page=2": "https://pypi.org/simple/",
            "--find-links https://example.com/wheels/?page=2": "--find-links https://example.com/wheels/",
            // A comma inside the query (bundler asks `?gems=a,b`).
            "GET https://rubygems.example.com/api/v1/dependencies?gems=a,b&token=s3cret 200":
                "GET https://rubygems.example.com/api/v1/dependencies 200",
            // A `'` or `)` in the path doesn't end the URL before its query.
            "https://files.example.com/fo(o)/x?token=s3cret": "https://files.example.com/fo(o)/x",
            "https://files.example.com/it's/x?token=s3cret": "https://files.example.com/it's/x",
        ])
    }

    /// Index options and variables: their URLs lose userinfo and query like any other.
    @Test func indexValuesLoseUserinfoAndQuery() {
        expectScrubbed([
            "pip install --index-url https://pypi.example.com/simple?s3cret black":
                "pip install --index-url https://pypi.example.com/simple black",
            "--extra-index-url=https://u:s3cret@extra.example.com/simple?x=1":
                "--extra-index-url=https://extra.example.com/simple",
            "-i https://pypi.example.com/simple/?v=s3cret": "-i https://pypi.example.com/simple/",
            "uv tool install --index internal=https://pypi.example.com/simple?v=s3cret ruff":
                "uv tool install --index internal=https://pypi.example.com/simple ruff",
            "--default-index 'https://pypi.example.com/simple?v=s3cret'":
                "--default-index 'https://pypi.example.com/simple'",
            "UV_INDEX_URL=https://__token__:s3cret@pypi.example.com/simple":
                "UV_INDEX_URL=https://pypi.example.com/simple",
            "UV_INDEX=internal=https://pypi.example.com/simple?v=s3cret":
                "UV_INDEX=internal=https://pypi.example.com/simple",
            "UV_DEFAULT_INDEX=https://pypi.example.com/b?v=2": "UV_DEFAULT_INDEX=https://pypi.example.com/b",
        ])
    }

    /// A variable named like a secret loses its value; so does a pip variable whose URL carries credentials.
    @Test func secretVariablesLoseTheirValues() {
        expectScrubbed([
            "NPM_TOKEN=npm_s3cret npm publish": "NPM_TOKEN=*** npm publish",
            "NODE_AUTH_TOKEN=s3cret": "NODE_AUTH_TOKEN=***",
            "UV_INDEX_INTERNAL_PASSWORD='s3cret value' uv tool install ruff":
                "UV_INDEX_INTERNAL_PASSWORD=*** uv tool install ruff",
            "export MY_SECRET=\"s3cret\" MY_AUTH=s3cret": "export MY_SECRET=*** MY_AUTH=***",
            "//registry.npmjs.org/:_authToken=npm_s3cret": "//registry.npmjs.org/:_authToken=***",
            #"PIP_INDEX_URL="https://pypi.example.com/simple?v=s3cret" pip install x"#:
                "PIP_INDEX_URL=*** pip install x",
            "PIP_EXTRA_INDEX_URL=https://u:s3cret@pypi.example.com/a UV_DEFAULT_INDEX=https://pypi.example.com/b":
                "PIP_EXTRA_INDEX_URL=*** UV_DEFAULT_INDEX=https://pypi.example.com/b",
            // Inside another option's value, with an unclosed quote, with a quote inside.
            "docker run --env=NPM_TOKEN=s3cret node": "docker run --env=NPM_TOKEN=*** node",
            #"NPM_TOKEN="s3cret and more"#: "NPM_TOKEN=*** and more",
            #"NPM_TOKEN=s3"cret done"#: "NPM_TOKEN=*** done",
        ])
    }

    /// Text without credentials comes back exactly as it was: plain URLs, other variables, addresses and `user@host`
    /// outside a URL. The captured lines are uv's own.
    @Test func textWithoutCredentialsIsUnchanged() throws {
        let captured = [
            try capturedStderr("uv/tool-list-outdated-network-refused-stderr.txt"),
            try capturedStderr("uv/tool-install-network-refused-stderr.txt"),
            try capturedStderr("uv/tool-upgrade-isort-stderr.txt"),
            try capturedStderr("uv/tool-install-unknown-stderr.txt"),
        ]
        #expect(captured[0].contains("Failed to fetch: https://pypi.org/simple/ruff/"))
        let written = [
            "git@github.com:someone/tool.git", "Mail someone@example.com about it", "UV_INDEX_STRATEGY=first-index",
            "ls -i ./file", "PIP_INDEX_URL=https://pypi.example.com/simple", "TOKEN_COUNT=3", "a == b", "",
            // pip's requirement lines: `==` is a version, not a value.
            "Collecting google_auth==2.0", "Requirement already satisfied: django_rest_auth==0.9.5",
        ]
        for text in captured + written {
            #expect(CredentialScrubber.scrub(text) == text, "\(text)")
        }
    }

    /// Every line of a multi-line answer is cleaned.
    @Test func everyLineIsCleaned() {
        let text = """
            Looking in indexes: https://__token__:s3cret@pypi.example.com/simple/
            error: Failed to fetch: https://pypi.example.com/simple/black/?token=s3cret
              hint: UV_INDEX_URL=https://pypi.example.com/simple?s3cret
            """
        let scrubbed = CredentialScrubber.scrub(text)
        #expect(!scrubbed.contains("s3cret"))
        #expect(!scrubbed.contains("__token__"))
        #expect(scrubbed.split(separator: "\n").count == 3)
        #expect(scrubbed.contains("Failed to fetch: https://pypi.example.com/simple/black/\n"))
    }
}
