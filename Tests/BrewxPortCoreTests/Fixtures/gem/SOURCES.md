# Fixture sources

Real RubyGems output, captured 2026-11-26 in a throwaway macOS 15.6.1 (arm64) virtual machine,
saved afterwards as snapshot `pre-plan9`. RubyGems 4.1.0 with Ruby 4.0.10 from the Homebrew formula `ruby` (Homebrew
7.0.16). In the table, `gem` and `ruby` mean `/opt/homebrew/bin/gem` and `/opt/homebrew/bin/ruby`, not the system Ruby
in `/usr/bin`. Gems install to `/opt/homebrew/lib/ruby/gems/4.0.0` and their executables to
`/opt/homebrew/lib/ruby/gems/4.0.0/bin` (see `environment.txt`). The test gems are `thor` (1.3.2 installed, 1.5.0
latest) and `lolcat` (100.0.0 installed, 100.0.1 latest), which pulls in `manpages`, `optimist` and `paint`.

Every command ran over SSH as `tester` through `env -i`, so the environment held only `HOME=/Users/tester`,
`USER=tester`, `LANG=en_US.UTF-8`, `NO_COLOR=1` and
`PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, plus anything shown in front
of the command below. Stdin was `/dev/null` and there was no terminal. The working directory was `/Users/tester`,
except for the first rows named in the notes, which ran in the empty folder `/Users/tester/capwd`. That doesn't
change their output.

How to read the files: `NAME.json` or `NAME.txt` is stdout, `NAME-stderr.txt` is stderr and `NAME.exit` is the exit
code. A stdout or stderr file is left out when that stream was empty. For a `GET` row, `NAME.http` is the HTTP
status and `NAME.json` or `NAME.txt` is the body, fetched with `curl` in the same machine with the User-Agent
`BrewxPort-fixture-capture`. Rows are in the order they ran. Commands that change packages were run on purpose to
capture their output, and the last rows put back the outdated packages the snapshot `pre-plan9` keeps.

## Files

| File(s) | Command | Exit |
|---|---|---|
| `version.txt`, `version.exit` | `gem --version` | 0 |
| `ruby-version.txt`, `ruby-version.exit` | `ruby --version` | 0 |
| `search-remote-lolcat.txt`, `search-remote-lolcat.exit` | `gem search --remote '^lolcat$'` | 0 |
| `search-remote-broad.txt`, `search-remote-broad.exit` | `gem search --remote lolcat` | 0 |
| `search-remote-nomatch.txt`, `search-remote-nomatch.exit` | `gem search --remote zzqxbrewxportnomatch` | 0 |
| `info-exact-lolcat.txt`, `info-exact-lolcat.exit` | `gem info --exact lolcat` | 0 |
| `info-exact-unknown.txt`, `info-exact-unknown.exit` | `gem info --exact no-such-gem-for-brewxport` | 0 |
| `environment.txt`, `environment.exit` | `gem environment` | 0 |
| `update-thor.txt`, `update-thor.exit` | `gem update --no-document thor` | 0 |
| `list-local-two-versions.txt`, `list-local-two-versions.exit` | `gem list --local thor` | 0 |
| `uninstall-x-two-versions.txt`, `uninstall-x-two-versions.exit` | `gem uninstall -x thor` | 0 |
| `cleanup-thor.txt`, `cleanup-thor.exit` | `gem cleanup thor` | 0 |
| `list-local-after-cleanup.txt`, `list-local-after-cleanup.exit` | `gem list --local thor` | 0 |
| `uninstall-all-x-thor.txt`, `uninstall-all-x-thor.exit` | `gem uninstall --all --executables --abort-on-dependent thor` | 0 |
| `uninstall-not-installed.txt`, `uninstall-not-installed.exit` | `gem uninstall --all --executables --abort-on-dependent thor` | 0 |
| `uninstall-default-gem.txt`, `uninstall-default-gem.exit` | `gem uninstall --all --executables --abort-on-dependent json` | 0 |
| `uninstall-has-dependent-stderr.txt`, `uninstall-has-dependent.exit` | `gem uninstall --all --executables --abort-on-dependent paint` | 1 |
| `install-unknown-stderr.txt`, `install-unknown.exit` | `gem install --no-document no-such-gem-for-brewxport` | 2 |
| `install-network-refused-stderr.txt`, `install-network-refused.exit` | `https_proxy=http://127.0.0.1:9 gem install --no-document thor` | 2 |
| `outdated-network-refused.exit` | `https_proxy=http://127.0.0.1:9 gem outdated` | 0 |
| `index-info-lolcat.txt`, `index-info-lolcat.http` | `GET https://index.rubygems.org/info/lolcat` | HTTP 200 |
| `index-info-thor.txt`, `index-info-thor.http` | `GET https://index.rubygems.org/info/thor` | HTTP 200 |
| `index-info-unknown.txt`, `index-info-unknown.http` | `GET https://index.rubygems.org/info/no-such-gem-for-brewxport` | HTTP 404 |
| `api-gem-lolcat.json`, `api-gem-lolcat.http` | `GET https://rubygems.org/api/v1/gems/lolcat.json` | HTTP 200 |
| `api-gem-unknown.txt`, `api-gem-unknown.http` | `GET https://rubygems.org/api/v1/gems/no-such-gem-for-brewxport.json` | HTTP 404 |
| `api-search-lolcat.json`, `api-search-lolcat.http` | `GET https://rubygems.org/api/v1/search.json?query=lolcat` | HTTP 200 |
| `install-restore-thor.txt`, `install-restore-thor.exit` | `gem install --no-document thor -v 1.3.2` | 0 |
| `list-local-empty.txt`, `list-local-empty.exit` | `gem list --local` | 0 |
| `outdated-empty.txt`, `outdated-empty.exit` | `gem outdated` | 0 |
| `install-thor-1.3.2.txt`, `install-thor-1.3.2.exit` | `gem install --no-document thor -v 1.3.2` | 0 |
| `install-lolcat-100.0.0.txt`, `install-lolcat-100.0.0.exit` | `gem install --no-document lolcat -v 100.0.0` | 0 |
| `list-local.txt`, `list-local.exit` | `gem list --local` | 0 |
| `outdated.txt`, `outdated.exit` | `gem outdated` | 0 |
| `list-local-final.txt`, `list-local-final.exit` | `gem list --local` | 0 |

## Notes

- The first two rows (`version`, `ruby-version`) ran in `/Users/tester/capwd`.
- Order: the last seven rows (`list-local-empty` to `list-local-final`) were captured in a second pass, after the gems
  were uninstalled and installed again. `list-local-empty.txt` and `outdated-empty.txt` show the state before `thor` and
  `lolcat` were installed: Ruby's own default and bundled gems only.
- Scrubbed: Homebrew's Ruby bundles `net-imap` at a four-part version (`0.6.4` with a fourth part `1`), and
  `Tests/check_repo.py` reads any four-part version as an IPv4 address. So the `net-imap` line was removed from
  `list-local-empty.txt`, `list-local.txt` and `list-local-final.txt`, and the `net-imap` line (latest `0.6.8`) from
  `outdated-empty.txt` and `outdated.txt`. Nothing else was changed. Uninstalling that gem before the second pass didn't help, because a second copy in the formula's own gem
  folder still showed in the list; the removed copy was installed again afterwards.
- `outdated` lists default and bundled gems too: 46 of them before anything was installed (45 lines after the scrub).
- With the network refused (`https_proxy=http://127.0.0.1:9`), `outdated` printed nothing and exited 0, the same as
  "nothing outdated". `install` failed with exit 2.
- `update thor` installed 1.5.0 next to 1.3.2 (`list-local-two-versions.txt`) until `cleanup thor` removed the old one.
- `uninstall -x thor` with two versions installed and stdin closed printed its version menu and `Error: must enter a
  number [1-3]`, removed nothing, and exited 0. It ran under a 60-second alarm in case it waited for input; the alarm
  didn't fire.
- `uninstall` of a gem that isn't installed, and of a default gem (`json`), print a message and exit 0. With a dependent
  installed, `--abort-on-dependent` exits 1 with a Ruby backtrace on stderr (this Ruby's gem configuration has
  `:backtrace => true`).
- `info --exact` of an unknown gem and `search --remote` with no match print one empty line and exit 0.
- `install` of an unknown gem exits 2.
- `index-info-*.txt` are the compact index files from `index.rubygems.org`; `api-*.json` are from `rubygems.org/api/v1`.
  A 404 body is plain text.

## Task 13 captures (`t13-*`)

Homebrew's Ruby 4.0.10 and RubyGems 4.1.0 (`gem` and `ruby` mean `/opt/homebrew/bin/gem` and `/opt/homebrew/bin/ruby`, links into the Cellar: `t13-ruby-path-ls.txt`), and macOS's own Ruby 2.6.10 in `/usr/bin` (RubyGems 3.0.3 with a fourth part `1`), from which nothing was installed. `<executablesScript>` and `<confirmationScript>` stand for the exact text of `GemEngine.executablesScript` and `GemEngine.confirmationScript`, joined from the Swift source and passed as the one argument after `-e`. The gems at the start: `thor` 1.3.2 and `lolcat` 100.0.0 (with `manpages`, `optimist`, `paint`).

Captured 2026-11-27 in the same throwaway macOS 15.6.1 (arm64) virtual machine, starting from the snapshot `pre-plan9` (the state the rows above leave behind); the machine was put back to that snapshot afterwards. Same environment and file conventions as above: `env -i` with `HOME=/Users/tester`, `USER=tester`, `LANG=en_US.UTF-8`, `NO_COLOR=1` and `PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, plus anything shown in front of a command; stdin `/dev/null`, no terminal, working directory `/Users/tester` unless a row says otherwise. `NAME.json` or `NAME.txt` is stdout, `NAME-stderr.txt` stderr and `NAME.exit` the exit code; a stream that was empty has no file. A `/bin/cat` row is a copy of that file as it was on disk (no exit file). Every file name starts with `t13-`, and rows are in the order they ran. Steps that only set something up (making a folder, deleting a file on purpose, writing a config file) weren't captured; the notes say where they happened.

| File(s) | Command | Exit |
|---|---|---|
| `t13-ruby-path-ls.txt`, `t13-ruby-path-ls.exit` | `/bin/ls -l /opt/homebrew/bin/ruby /opt/homebrew/bin/gem` | 0 |
| `t13-executables-script.txt`, `t13-executables-script.exit` | `ruby -e <executablesScript>` | 0 |
| `t13-confirmation-installed-stderr.txt`, `t13-confirmation-installed.exit` | `ruby -e <confirmationScript> -- thor lolcat` | 1 |
| `t13-confirmation-default-gem.exit` | `ruby -e <confirmationScript> -- json` | 0 |
| `t13-confirmation-bundled-gem-stderr.txt`, `t13-confirmation-bundled-gem.exit` | `ruby -e <confirmationScript> -- rake` | 1 |
| `t13-confirmation-not-installed.exit` | `ruby -e <confirmationScript> -- no-such-gem-for-brewxport` | 0 |
| `t13-install-remote-mustache.txt`, `t13-install-remote-mustache.exit` | `gem install --remote --no-document mustache` | 0 |
| `t13-update-remote-thor.txt`, `t13-update-remote-thor.exit` | `gem update --remote --no-document thor` | 0 |
| `t13-list-local-thor-after-update.txt`, `t13-list-local-thor-after-update.exit` | `gem list --local thor` | 0 |
| `t13-executables-script-after-update.txt`, `t13-executables-script-after-update.exit` | `ruby -e <executablesScript>` | 0 |
| `t13-install-remote-two.txt`, `t13-install-remote-two.exit` | `gem install --remote --no-document rainbow tty-color` | 0 |
| `t13-update-remote-two.txt`, `t13-update-remote-two.exit` | `gem update --remote --no-document lolcat mustache` | 0 |
| `t13-uninstall-mustache.txt`, `t13-uninstall-mustache.exit` | `gem uninstall --all --executables --abort-on-dependent mustache` | 0 |
| `t13-confirmation-after-uninstall.exit` | `ruby -e <confirmationScript> -- mustache` | 0 |
| `t13-executables-script-end.txt`, `t13-executables-script-end.exit` | `ruby -e <executablesScript>` | 0 |
| `t13-system-ruby-version.txt`, `t13-system-ruby-version.exit` | `/usr/bin/ruby --version` | 0 |
| `t13-system-gem-environment.txt`, `t13-system-gem-environment.exit` | `/usr/bin/gem environment` | 0 |
| `t13-system-gem-list-local.txt`, `t13-system-gem-list-local.exit` | `/usr/bin/gem list --local` | 0 |
| `t13-system-executables-script.txt`, `t13-system-executables-script.exit` | `/usr/bin/ruby -e <executablesScript>` | 0 |
| `t13-system-confirmation-rake-stderr.txt`, `t13-system-confirmation-rake.exit` | `/usr/bin/ruby -e <confirmationScript> -- rake` | 1 |
| `t13-brew-info-ruby.json`, `t13-brew-info-ruby.exit` | `brew info --json=v2 ruby` | 0 |

### Notes

- On Homebrew's Ruby every bundled gem with executables (debug, irb, minitest, racc, rake, rbs, rdoc, test-unit, typeprof) shows two copies in `t13-executables-script.txt`, `user` and `ruby`: Homebrew's formula links each bundled gemspec from the Cellar into `/opt/homebrew/lib/ruby/gems/4.0.0/specifications` (the links are dated when the formula was poured), so `Gem::Specification` finds one copy under each folder. `t13-confirmation-bundled-gem` names `rake` as still installed for the same reason.
- On macOS's own Ruby both scripts run (Ruby 2.6); its `rake` shows as `user`.
- `t13-update-remote-thor`: `update` installs 1.5.0 beside 1.3.2. `t13-update-remote-two` with one gem already current says so and exits 0.
- Scrubbed: `Tests/check_repo.py` reads a four-part version as an IPv4 address. The `rdoc` line was removed from `t13-system-executables-script.txt`, the `RUBYGEMS VERSION` line from `t13-system-gem-environment.txt`, and the `rdoc` and `rexml` lines from `t13-system-gem-list-local.txt`; `/usr/bin/gem --version` was captured but not kept, since its one line is such a version. Nothing else was changed.
