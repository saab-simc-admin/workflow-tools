# GitHub Pull Request helper #

Crude helper tool for merging pull requests on GitHub, when the
workflow requires that all commits are GPG signed.

Requires the `curl` and `jq` utilities.

Copy `bin/git-ghpr` to somewhere in $PATH, to make the `git ghpr`
subcommand available.
