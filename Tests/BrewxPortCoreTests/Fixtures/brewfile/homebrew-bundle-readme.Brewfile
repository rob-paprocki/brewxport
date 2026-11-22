# Run `brew tap` with a custom URL
tap "user/tap-repository", "https://user@example.com/user/homebrew-tap-repository.git"

# Set arguments passed to all `brew install --cask` commands for `cask "..."`
# In this example, pass `--appdir=~/Applications` and `--require_sha`
cask_args appdir: "~/Applications", require_sha: true

# Pass options to non-Homebrew/core formulae e.g. `brew install denji/nginx/nginx-full --with-rmtp`
# This also runs `brew link --overwrite nginx-full` and `brew services restart nginx-full` afterwards.
brew "denji/nginx/nginx-full", link: :overwrite, args: ["with-rmtp"], restart_service: :always

# Runs `brew install mysql@5.6`, `brew services restart mysql@5.6` only if it was installed or upgraded,
# `brew link mysql@5.6` and `brew unlink mysql` (if `mysql` is installed)
brew "mysql@5.6", restart_service: :changed, link: true, conflicts_with: ["mysql"]

# Runs `brew install postgresql@16` and then runs a postinstall command if `postgresql@16` was installed or upgraded.
brew "postgresql@16",
     postinstall: "${HOMEBREW_PREFIX}/opt/postgresql@16/bin/postgres -D ${HOMEBREW_PREFIX}/var/postgresql@16"

# Runs `brew install ruby` and, afterwards, writes the installed version to the '.ruby-version` file.
brew "ruby", version_file: ".ruby-version"

# Trusts the tap, formula or cask so Homebrew loads it when tap trust is required.
# This works on `tap`, `brew` and `cask` entries.
tap "user/repository", trusted: true
brew "user/repository/formula", trusted: true
cask "user/repository/cask", trusted: true

# Trusts only named formulae, casks or commands from a tap.
tap "user/repository", trusted: {
  formula:  "formula",
  casks:    ["cask"],
  commands: ["command"],
}

# Runs `brew install gnupg` or `brew install glibc` only on the specified OS.
# Note: `brew bundle list` will not output `gnupg` on Linux or `glibc` on macOS` in this case:
# the Ruby logic means they are "hidden" on other platforms.
brew "gnupg" if OS.mac?
brew "glibc" if OS.linux?

# Runs `brew install --cask --appdir=~/my-apps/Applications`
cask "firefox", args: { appdir: "~/my-apps/Applications" }

# Runs `brew upgrade opera` to upgrade an auto-updated or unversioned Opera cask
# to the latest version even if already installed.
# This is used to force an upgrade in software that would typically update itself.
cask "opera", greedy: true

# Runs `brew install --cask google-chrome` only if it is not installed, then `brew pin --cask google-chrome`,
# so neither `brew bundle` nor `brew upgrade` upgrades it afterwards; `brew unpin` undoes it.
# This works on `brew` and `cask` entries. Casks with `auto_updates true` still update themselves.
cask "google-chrome", pin: true

# Runs `brew install --cask java` only if '/usr/libexec/java_home --failfast` fails (i.e there is no Java)
# Note: `brew bundle list` will not output `java` if this `system` command succeeds and
# this `system` command will be run even on `brew bundle check`, not just `brew bundle install`.
cask "java" unless system "/usr/libexec/java_home", "--failfast"

# Runs `brew install --cask` and runs the command if the Google Cloud cask was installed or upgraded.
cask "google-cloud-sdk", postinstall: "${HOMEBREW_PREFIX}/bin/gcloud components update"

# Sets an environment variable to be used e.g. inside `brew bundle exec` or `system` commands in the `Brewfile`.
# Note: HOMEBREW_PREFIX/bin is _not_ in the `PATH` by default so you can set it this way.
ENV["SOME_ENV_VAR"] = "some_value"
