# ubp-bootstrap

Puts a new Mac or Linux machine on the [ubp](https://github.com/FpTargeT/uniform_bash_prompt_kit) rails:
Homebrew (Mac), the GitHub CLI, the private ubp repository at one release tag, then `ubp init` and `ubp sync`.
It contains no host name, address or secret. Everything private stays in the ubp repository, behind GitHub sign-in.

## Install

Pick a release tag (never `main`), then:

```bash
TAG=v0.1.1
cd "$(mktemp -d)" && curl -fsSLO "https://raw.githubusercontent.com/FpTargeT/ubp-bootstrap/$TAG/bootstrap.sh" \
  && curl -fsSLO "https://raw.githubusercontent.com/FpTargeT/ubp-bootstrap/$TAG/SHA256SUMS" \
  && shasum -a 256 -c SHA256SUMS && less bootstrap.sh && bash bootstrap.sh
```

That is the careful way: download, check the checksum, read it, run it. The one-liner, if you trust the tag:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/FpTargeT/ubp-bootstrap/v0.1.1/bootstrap.sh)"
```

`bash -c "$(curl ...)"` rather than `curl | bash`: the whole file is downloaded before anything runs, and the
prompts keep working.

## Options

| Option | Meaning |
|---|---|
| `--role dev\|admin\|user\|server\|generic` | role of this account; asked if omitted |
| `--yes` | no questions (needs `--role`) |
| `--keep-gh` | stay signed in to GitHub afterwards (default: signed out unless the role is `dev`) |
| `--dry-run` | print what would happen, change nothing |

## On someone else's Mac

Run it yourself, at the keyboard, with `--role user` (or `admin`). It signs you out of `gh` at the end, so no token of
yours stays on that machine. Later updates reach it as a payload (`ubp package` on your dev Mac), never through GitHub.

## Releasing (owner only)

1. In the ubp repository: `git tag -a vX.Y.Z -m vX.Y.Z` on a clean, tested commit.
2. `bootstrap/make-release.sh vX.Y.Z` pins that tag inside `bootstrap.sh` and writes `SHA256SUMS`.
3. Copy `bootstrap.sh`, `SHA256SUMS` and this file to the public `ubp-bootstrap` repository, commit, tag the same `vX.Y.Z`.
4. Publish the sha256 in the tag message.

The Homebrew installer is pinned to a commit and a checksum inside the script; bump both together, on purpose.
