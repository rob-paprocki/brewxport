# Fixture sources

`dependents-zlib.txt`, `dependents-none.txt`, `dependents-notinstalled-stderr.txt`: real `port -q dependents <port>` output, captured
2026-11-21 in a throwaway macOS 27 virtual machine. `zlib` has three installed dependents (exit 0). `nano` has none (empty output, exit 0).
`pcre2` was not installed in the machine, so that case is the error `Error: pcre2 is not installed` (exit 1). The brief named pcre2 for the
dependents case, but it was not installed and installing MacPorts ports needs root, so `zlib` stands in.

`info-ripgrep.txt`, `info-imagemagick.txt`: real `port info --name --description --homepage --version --variants --depends_lib
--depends_run <port>` output (MacPorts 2.12.7), captured 2026-11-21 in a throwaway macOS 27 virtual machine (snapshot `pre-plan6`). Both
exited 0. `info-ripgrep.txt` replaces the earlier capture made without `--name`. `info-imagemagick.txt` was asked for in lower case;
MacPorts matched it ignoring case and printed the port's own name, `ImageMagick`.
