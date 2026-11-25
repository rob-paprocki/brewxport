"""Tests of check_repo.py, the personal-value check."""
import contextlib
import hashlib
import importlib.util
import io
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

sys.dont_write_bytecode = True     # a copy that is not a git checkout must stay clean


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


check_repo = load("check_repo", os.path.join(HERE, "check_repo.py"))

# The tests' own git calls ignore the maintainer's git config (signing, hooks, templates): the
# suite also runs on the maintainer's Mac right before a publish.
ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com",
           GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")


def IP(*parts):
    return ".".join(parts)


def git(repo, *args):
    return subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True,
                          check=True, env=ENV).stdout.strip()


def make_repo(files, message="init"):
    d = tempfile.mkdtemp()
    git(d, "init", "-q", "-b", "main")
    add_commit(d, files, message)
    return d


def add_commit(d, files, message):
    for path, text in files.items():
        p = os.path.join(d, path)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
    git(d, "add", "-A")
    git(d, "commit", "-q", "-m", message)


class PatternTests(unittest.TestCase):
    def kinds(self, text):
        return [k for _, k in check_repo.scan_text(text)]

    def test_allowed_values(self):
        self.assertEqual(self.kinds("gw 192.168.100.1, dns 1.1.1.1, lo 127.0.0.1, doc 203.0.113.9\n"
                                    "mac 00:00:5E:00:53:0a, mail admin@example.com, x@y.invalid\n"
                                    "me git@github.com\n"
                                    "bcast 255.255.255.255 v6 2001:db8::1 ::1\n"
                                    "time 01:02:52 version 1.2.3 port 8006"), [])

    def test_disallowed_values(self):
        # The "bad" samples are assembled at runtime so that no disallowed value
        # appears literally in this (public) file.
        self.assertEqual(self.kinds(IP("10", "1", "2", "3")), ["IP address"])         # private
        self.assertEqual(self.kinds(IP("100", "64", "1", "2")), ["IP address"])       # CGNAT
        self.assertEqual(self.kinds(IP("8", "8", "4", "5")), ["IP address"])          # public
        self.assertEqual(self.kinds(":".join(["fd12", "3456", "789a", "", "1"])), ["IPv6 address"])
        self.assertEqual(self.kinds(":".join(["e0", "51", "d8", "00", "11", "22"])), ["MAC address"])
        self.assertEqual(self.kinds("me" + "@" + "mail-provider.com"), ["email address"])

    def test_report_never_contains_the_value(self):
        bad = IP("10", "20", "30", "40")
        d = make_repo({"a.txt": "secret %s here\n" % bad, "private/notes.md": bad + "\n"})
        problems = check_repo.check(d)
        self.assertEqual(problems, ["a.txt:1: IP address not allowed in public files"])   # private/ skipped
        self.assertNotIn(bad, "".join(problems))

    def test_node_modules_skipped(self):
        bad = IP("10", "20", "30", "40")
        d = make_repo({"a.txt": "ok\n", "app/node_modules/x/y.js": bad + "\n"})
        self.assertEqual(check_repo.check(d), [])
        plain = tempfile.mkdtemp()                       # not a git checkout: walks the tree
        os.makedirs(os.path.join(plain, "node_modules"))
        with open(os.path.join(plain, "node_modules", "z.js"), "w") as f:
            f.write(bad + "\n")
        self.assertEqual(check_repo.check(plain), [])

    def test_main_exit_codes(self):
        d = make_repo({"a.txt": "ok\n"})
        self.assertEqual(check_repo.main(["check_repo.py", d]), 0)
        add_commit(d, {"b.txt": IP("10", "1", "1", "1") + "\n"}, "bad")
        self.assertEqual(check_repo.main(["check_repo.py", d]), 1)

    def test_email_allow_list_is_exact(self):
        self.assertEqual(self.kinds("41898282+github-actions[bot]@users.noreply.github.com "
                                    "git@github.com noreply@github.com a@sub.example.com a@x.invalid"), [])
        # The public contact is GitHub itself: no personal address passes, not even a
        # personal noreply address (it names the account).
        for addr in ("a" + "@example.org", "a" + "@example.net",
                     "someone[x]" + "@mail-provider.com",
                     "12345+someone" + "@users.noreply.github.com"):
            self.assertEqual(self.kinds(addr), ["email address"], addr)

    def test_versioned_formula_names_are_not_emails(self):
        # Homebrew's versioned formulae: `python@3.15.rb`, `openssl@3`, in real captured output.
        self.assertEqual(self.kinds('"ruby_source_path": "Formula/p/python' + '@3.15.rb"'), [])
        self.assertEqual(self.kinds("node" + "@22.11.rb icu4c" + "@76.1.rb"), [])
        # A real-looking domain with a digit-only label still counts.
        for addr in ("a" + "@1.2.com", "a" + "@123.example.org", "me" + "@mail2.net"):
            self.assertEqual(self.kinds(addr), ["email address"], addr)

    def test_ip_allow_list_is_exact(self):
        self.assertEqual(self.kinds("1.1.1.1 8.8.8.8 0.0.0.0"), [])
        # 9.9.9.9, 1.0.0.1 and 8.8.4.4 were findings here; the kit's check_patterns.py names them
        # as examples, so check_repo.py allows them now. Their neighbours are still findings.
        self.assertEqual(self.kinds("9.9.9.9 1.0.0.1 8.8.4.4"), [])
        for ip in (IP("9", "9", "9", "8"), IP("1", "0", "0", "2"), IP("8", "8", "4", "3")):
            self.assertEqual(self.kinds(ip), ["IP address"], ip)

    def test_unparsable_four_octet_value_is_a_finding(self):
        self.assertEqual(self.kinds(IP("010", "001", "002", "003")), ["IP address"])
        self.assertEqual(self.kinds(IP("300", "1", "1", "1")), ["IP address"])

    def test_value_in_file_name_is_never_printed(self):
        name = "a" + "@mail-provider.com.txt"
        d = make_repo({name: "fine\n", "z.txt": "ok\n"})
        problems = check_repo.check(d)
        self.assertEqual(problems, ["file #1 (in sorted order): email address in the file name"])
        self.assertNotIn("mail-provider", "".join(problems))
        with open(os.path.join(d, name), "wb") as f:
            f.write(b"\xff\xfe")
        problems = check_repo.check(d)
        self.assertNotIn("mail-provider", "".join(problems))
        self.assertTrue(any("not UTF-8" in p for p in problems))

    def test_bad_root_and_empty_tree_fail(self):
        self.assertEqual(check_repo.main(["check_repo.py", "/nonexistent/dir"]), 1)
        self.assertEqual(check_repo.main(["check_repo.py", tempfile.mkdtemp()]), 1)

    def test_unreadable_tracked_entries_are_findings(self):
        d = make_repo({"a.txt": "ok\n", "sub/b.txt": "ok\n"})
        os.symlink("sub", os.path.join(d, "dirlink"))
        git(d, "add", "-A")
        git(d, "commit", "-q", "-m", "link")
        self.assertEqual(check_repo.check(d), ["dirlink: not a readable regular file"])
        os.unlink(os.path.join(d, "dirlink"))               # deleted, uncommitted: skipped
        self.assertEqual(check_repo.check(d), [])

    def test_pycache_hides_only_bytecode(self):
        d = tempfile.mkdtemp()
        os.makedirs(os.path.join(d, "__pycache__"))
        with open(os.path.join(d, "__pycache__", "x.cpython-313.pyc"), "wb") as f:
            f.write(b"\xff\xfe")
        with open(os.path.join(d, "__pycache__", "note.txt"), "w") as f:
            f.write("me" + "@mail-provider.com\n")
        with open(os.path.join(d, "a.txt"), "w") as f:
            f.write("ok\n")
        self.assertEqual(check_repo.check(d),
                         ["__pycache__/note.txt:1: email address not allowed in public files"])

    def test_strict_mode_skips_nothing(self):
        # The build checks its output in strict mode: bytecode and node_modules there would be
        # published, so they are checked like everything else.
        d = tempfile.mkdtemp()
        os.makedirs(os.path.join(d, "__pycache__"))
        os.makedirs(os.path.join(d, "node_modules"))
        with open(os.path.join(d, "__pycache__", "m.cpython-39.pyc"), "wb") as f:
            f.write(b"\xff\xfe")
        with open(os.path.join(d, "node_modules", "z.js"), "w") as f:
            f.write(IP("10", "20", "30", "40") + "\n")
        self.assertEqual(check_repo.check(d), [])                     # a working tree: skipped
        self.assertEqual(check_repo.check(d, strict=True),
                         ["__pycache__/m.cpython-39.pyc: not UTF-8 text",
                          "node_modules/z.js:1: IP address not allowed in public files"])

    def test_this_repo_is_clean(self):
        self.assertEqual(check_repo.check(ROOT), [])

    # Approved binaries: Tests/approved-binaries.txt lists "SHA-256  path" for each binary file
    # the owner looked at and approved. Exactly that content passes; anything else fails closed.

    def test_approved_binary_passes(self):
        d = binary_repo(PNG, approve=True)
        self.assertEqual(check_repo.check(d), [])
        shutil.rmtree(os.path.join(d, ".git"))                # strict mode reads a plain copy
        self.assertEqual(check_repo.check(d, strict=True), [])

    def test_approved_binary_with_another_hash_fails(self):
        d = binary_repo(PNG, approve=True)
        write_bytes(d, "docs/shot.png", PNG + b"\x00changed")
        problems = check_repo.check(d)
        self.assertEqual(problems, ["docs/shot.png: binary file differs from its approved SHA-256"])

    def test_unlisted_binary_fails(self):
        d = binary_repo(PNG, approve=True)
        write_bytes(d, "docs/other.png", PNG)
        git(d, "add", "-A")
        git(d, "commit", "-q", "-m", "another image")
        self.assertEqual(check_repo.check(d), ["docs/other.png: not UTF-8 text"])

    def test_approved_text_file_is_still_checked_and_hash_bound(self):
        d = make_repo({"a.txt": "ip %s\n" % IP("10", "1", "2", "3")})
        with open(os.path.join(d, "a.txt"), "rb") as f:
            sha = hashlib.sha256(f.read()).hexdigest()
        add_commit(d, {check_repo.APPROVED: "%s  a.txt\n" % sha}, "approve")
        self.assertEqual(check_repo.check(d), ["a.txt:1: IP address not allowed in public files"])

    def test_approval_list_errors_fail_closed(self):
        for text, want in (("not-a-hash  docs/shot.png\n", "line 1"),
                           ("%s  docs/missing.png\n" % ("0" * 64), "isn't in the tree"),
                           ("%s  docs/shot.png\n%s  docs/shot.png\n" % (PNG_SHA, PNG_SHA), "second time")):
            with self.subTest(want=want):
                d = binary_repo(PNG, approve=False)
                add_commit(d, {check_repo.APPROVED: text}, "list")
                problems = check_repo.check(d)
                self.assertTrue(any(want in p and check_repo.APPROVED in p for p in problems), problems)

    def test_approval_never_hides_a_value_in_the_name(self):
        name = "docs/" + IP("10", "1", "2", "3") + ".png"
        d = make_repo({"a.txt": "ok\n"})
        write_bytes(d, name, PNG)
        add_commit(d, {check_repo.APPROVED: "%s  %s\n" % (PNG_SHA, name)}, "approve")
        problems = check_repo.check(d)
        self.assertTrue(any("IP address in the file name" in p for p in problems), problems)
        self.assertNotIn(IP("10", "1", "2", "3"), "".join(problems))

    def test_this_repos_approved_binaries_are_its_only_binaries(self):
        approved, problems = check_repo.load_approved(ROOT)
        self.assertEqual(problems, [])
        self.assertEqual(sorted(approved), ["Resources/bundle/AppIcon.icns", "docs/images/bundles-dark.png", "docs/images/bundles-light.png",
                                    "docs/images/setup-dark.png", "docs/images/setup-light.png",
                                    "docs/images/updates-dark.png", "docs/images/updates-light.png"])


PNG = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff\xfe"        # a few bytes that aren't UTF-8
PNG_SHA = hashlib.sha256(PNG).hexdigest()


def write_bytes(d, path, data):
    full = os.path.join(d, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "wb") as f:
        f.write(data)


def binary_repo(data, approve, extra=None):
    """A repo with docs/shot.png holding DATA; APPROVE lists it in the approval file."""
    files = {"README.md": "hi\n"}
    files.update(extra or {})
    if approve:
        files[check_repo.APPROVED] = "# approved\n%s  docs/shot.png\n" % hashlib.sha256(data).hexdigest()
    d = make_repo(files)
    write_bytes(d, "docs/shot.png", data)
    git(d, "add", "-A")
    git(d, "commit", "-q", "-m", "image")
    return d




if __name__ == "__main__":
    unittest.main()
