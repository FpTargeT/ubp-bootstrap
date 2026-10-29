#!/usr/bin/env bash
# =============================================================================
# ubp-bootstrap -- put a new machine on the ubp rails (ADR-006).
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/FpTargeT/ubp-bootstrap/<TAG>/bootstrap.sh)"
#
# Always run a TAG-pinned copy (never main) and check it against SHA256SUMS first; README.md has
# the "download, read, run" way. This script holds no host name, address or secret.
#
# What it does, in order (it says so and asks before starting):
#   1. Mac: install Homebrew (installer pinned to a commit + sha256) if missing.   Linux: use apt.
#   2. Install the GitHub CLI (gh) and sign in (web flow, your MFA/passkey).
#   3. Clone the private ubp repository at the release tag this script is pinned to.
#   4. Run `ubp init --role dev` and `ubp sync`. Other roles never get a clone: they install a payload.
#   5. If the account turns out to be registered with another role: sign gh out again.
#
# Options: --role dev (the only role; default) | --yes (no questions) | --keep-gh | --dry-run | --help
# Runs under macOS's stock bash 3.2: no associative arrays, no mapfile, no ${var,,}.
# =============================================================================
set -euo pipefail
trap 'echo "Gracefully stopped by user (exit 130)." >&2; exit 130' INT

# Set by bootstrap/make-release.sh when a release is cut. A bootstrap tag installs exactly one ubp tag.
UBP_TAG='v0.1.4'
UBP_REPO='FpTargeT/uniform_bash_prompt_kit'
UBP_DIR="$HOME/.local/share/ubp"

# Homebrew's installer, pinned (reviewed 2026-10-23). Bump both values together, on purpose.
BREW_INSTALLER_COMMIT='a2fe82ef3a9ec7a5c72a559c09676256d6f354f6'
BREW_INSTALLER_SHA256='5f333bbe53bc490e51e7ccb1df8779b3dd6ee73a1a7379efda216edb08ccb148'
BREW_INSTALLER_URL="https://raw.githubusercontent.com/Homebrew/install/$BREW_INSTALLER_COMMIT/install.sh"

ROLE="dev"
ASSUME_YES=0
KEEP_GH=0
DRY_RUN=0

say()  { printf '%s\n' "$*" >&2; }
step() { printf '\n==> %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Print what would change, change nothing.
run() {
    if (( DRY_RUN )); then
        say "[dry-run] $*"
        return 0
    fi
    "$@"
}

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    fi
}

usage() { sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

detect_os() {
    case "$(uname -s)" in
        Darwin) echo mac ;;
        Linux)  echo linux ;;
        *)      return 1 ;;
    esac
}

# Apple Silicon: /opt/homebrew, Intel: /usr/local. Brew can be installed yet absent from PATH in a fresh shell
# (always so on Apple Silicon), which would trigger a needless second install and make `brew install gh` fail.
load_brew_env() {
    local prefix
    # UBP_FAKE_BREW_PREFIXES: test hook, so a test never reaches the host's real Homebrew.
    for prefix in ${UBP_FAKE_BREW_PREFIXES-/opt/homebrew /usr/local}; do
        if [[ -x "$prefix/bin/brew" ]]; then
            eval "$("$prefix/bin/brew" shellenv)"
            return 0
        fi
    done
}

ensure_brew_mac() {
    local tmp got
    load_brew_env
    if command -v brew >/dev/null 2>&1; then
        say "Homebrew already installed."
        return 0
    fi
    step "Installing Homebrew (pinned installer ${BREW_INSTALLER_COMMIT:0:12})"
    if (( DRY_RUN )); then
        say "[dry-run] download $BREW_INSTALLER_URL, verify sha256, run it"
        return 0
    fi
    tmp="$(mktemp -d)"
    curl -fsSL "$BREW_INSTALLER_URL" -o "$tmp/install.sh" || { rm -rf "$tmp"; die "could not download the Homebrew installer"; }
    got="$(sha256_of "$tmp/install.sh")"
    if [[ "$got" != "$BREW_INSTALLER_SHA256" ]]; then
        rm -rf "$tmp"
        die "[SECURITY] the Homebrew installer does not match its pinned checksum (got $got): refusing to run it"
    fi
    if (( ASSUME_YES )); then
        NONINTERACTIVE=1 /bin/bash "$tmp/install.sh"
    else
        /bin/bash "$tmp/install.sh"
    fi
    rm -rf "$tmp"
    load_brew_env
}

ensure_gh() {
    local os="$1"
    if command -v gh >/dev/null 2>&1; then
        say "gh already installed."
        return 0
    fi
    step "Installing the GitHub CLI"
    if [[ "$os" == "mac" ]]; then
        run brew install gh
    elif command -v apt-get >/dev/null 2>&1; then
        # gh is not in every distro's default apt sources (e.g. Debian stable): stop with the fix, add no third-party repo.
        if (( DRY_RUN )); then
            say "[dry-run] sudo apt-get install -y gh git"
        elif ! sudo apt-get install -y gh git; then
            die "gh is not in your apt sources: add GitHub's official repository (https://github.com/cli/cli/blob/trunk/docs/install_linux.md), then re-run"
        fi
    else
        die "no supported package manager to install gh: install it from https://cli.github.com then re-run"
    fi
}

ensure_gh_login() {
    if (( DRY_RUN )); then
        say "[dry-run] gh auth login (skipped if already signed in)"
        return 0
    fi
    if gh auth status >/dev/null 2>&1; then
        say "gh already signed in."
        return 0
    fi
    step "Signing in to GitHub: gh shows a one-time code and a URL; open it in a browser on ANY device (your passkey / MFA applies)"
    gh auth login --hostname github.com --git-protocol https --web
}

clone_ubp() {
    local kind
    step "Fetching ubp $UBP_TAG into $UBP_DIR"
    if [[ -e "$UBP_DIR" && ! -e "$UBP_DIR/.git" ]]; then
        die "$UBP_DIR exists and is not a git clone: move it away first"
    fi
    if (( DRY_RUN )); then
        say "[dry-run] gh repo clone $UBP_REPO $UBP_DIR -- --branch $UBP_TAG ; verify the tag is annotated"
        return 0
    fi
    if [[ -e "$UBP_DIR/.git" ]]; then
        git -C "$UBP_DIR" fetch --tags -q
        git -C "$UBP_DIR" checkout -q "refs/tags/$UBP_TAG"
    else
        mkdir -p "${UBP_DIR%/*}"
        gh repo clone "$UBP_REPO" "$UBP_DIR" -- --branch "$UBP_TAG" -q
    fi
    kind="$(git -C "$UBP_DIR" cat-file -t "refs/tags/$UBP_TAG" 2>/dev/null)" || kind=""
    if [[ "$kind" != "tag" ]]; then
        die "[SECURITY] $UBP_TAG is not an annotated release tag in $UBP_REPO: refusing to continue"
    fi
}

main() {
    local os role_args=() assume=() account_role
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --role)    ROLE="${2-}"; shift 2 ;;
            --role=*)  ROLE="${1#*=}"; shift ;;
            --yes|-y)  ASSUME_YES=1; shift ;;
            --keep-gh) KEEP_GH=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option '$1' (see --help)" ;;
        esac
    done
    if [[ "$UBP_TAG" == "v0.0.0" ]]; then
        # Placeholder tag: only bootstrap/make-release.sh pins a real one. Never act on a machine with it.
        (( DRY_RUN )) || die "this copy is not a release (UBP_TAG is the placeholder v0.0.0): use a tagged copy, or --dry-run"
        say "NOTE: this copy is not a release (UBP_TAG is the placeholder v0.0.0); dry-run only."
    fi
    if [[ -n "$ROLE" ]]; then
        case "$ROLE" in
            dev) ;;
            admin|user|server|generic)
                # This path clones the whole private repo (hosts.bash, dev roles): only a dev account may hold that.
                die "bootstrap is for dev accounts only: other roles get a role-filtered payload (ubp package <alias>, ubp root-install)" ;;
            *) die "invalid role (dev|admin|user|server|generic)" ;;
        esac
    fi
    os="$(detect_os)" || die "unsupported system: $(uname -s) (macOS and Linux/WSL only)"
    if [[ "$(id -u)" == "0" ]]; then
        die "do not run this as root: Homebrew refuses it and your own account is the one to set up"
    fi

    say "ubp-bootstrap: this will set up $USER on this $os machine from $UBP_REPO at $UBP_TAG."
    if (( ! ASSUME_YES && ! DRY_RUN )); then
        read -r -p "Continue? [y/N] " answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            say "Nothing done."
            exit 0
        fi
    fi

    if [[ "$os" == "mac" ]]; then
        ensure_brew_mac
    fi
    ensure_gh "$os"
    ensure_gh_login
    clone_ubp

    step "Registering this account and syncing"
    role_args=(--role "$ROLE")
    if (( ASSUME_YES )); then assume=(--yes); fi
    if (( DRY_RUN )); then
        say "[dry-run] $UBP_DIR/bin/ubp init ${role_args[*]-} ${assume[*]-}"
        say "[dry-run] $UBP_DIR/bin/ubp sync"
        exit 0
    fi
    "$UBP_DIR/bin/ubp" init "${role_args[@]+"${role_args[@]}"}" "${assume[@]+"${assume[@]}"}"
    "$UBP_DIR/bin/ubp" sync

    # A token left on a machine that is not yours is a standing credential for your whole account.
    account_role="$("$UBP_DIR/bin/ubp" whoami | awk '{print $2}')" || account_role=""
    if [[ "$account_role" != "dev" ]] && (( ! KEEP_GH )); then
        step "Signing gh out (this is not a dev machine; use --keep-gh to stay signed in)"
        gh auth logout --hostname github.com || say "could not sign out automatically: run: gh auth logout"
    fi
    say "Done. Open a new terminal. Check this account any time with: ubp doctor"
}

main "$@"
