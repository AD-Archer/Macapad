#!/bin/bash
# Installs Macapad by building it on this Mac. No Homebrew, no xattr:
#
#   curl -fsSL https://raw.githubusercontent.com/AD-Archer/Macapad/main/scripts/install.sh | bash
#
# Downloads the source of the latest release, builds it with the Command Line Tools, signs it
# with a self-signed "Macapad Dev" certificate made on this Mac, and copies it to /Applications.
# Nothing it downloads is quarantined, and an app built here never is, so Gatekeeper lets it open.
# Run it again to update; the certificate stays the same, so Accessibility access survives.
#
# MACAPAD_REF=main (or any branch or tag) builds that instead of the latest release.
set -euo pipefail

REPO="AD-Archer/Macapad"
DEST="/Applications"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Everything runs from here, so a download cut off halfway through runs nothing.
main() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "Macapad only runs on macOS."
  # sysctl, not uname -m: a Terminal running under Rosetta reports x86_64
  [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == "1" ]] || fail "Macapad needs an Apple Silicon Mac."
  local macos
  macos="$(sw_vers -productVersion)"
  (( ${macos%%.*} >= 14 )) || fail "Macapad needs macOS 14 or later (this Mac has $macos)."

  # /usr/bin/swift exists even without the tools; it just opens the installer, so check first.
  if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install 2>/dev/null || true
    fail "Macapad is built with Apple's Command Line Tools. Finish the install window that just opened, then run this again."
  fi
  local swift_major
  swift_major="$(swift --version 2>&1 | grep -oE 'Swift version [0-9]+' | grep -oE '[0-9]+$' || echo 0)"
  (( swift_major >= 6 )) || fail "Macapad needs Swift 6 or later. Update the Command Line Tools in System Settings > General > Software Update."

  local ref="${MACAPAD_REF:-}" version=""
  if [[ -z "$ref" ]]; then
    # releases/latest redirects to .../releases/tag/<tag>
    ref="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" || true)"
    ref="${ref##*/tag/}"
    [[ "$ref" == v* ]] || ref="main"
  fi
  [[ "$ref" == v* ]] && version="${ref#v}"

  # global: the EXIT trap runs after main has returned
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  say "Downloading Macapad ($ref)"
  curl -fsSL "https://github.com/$REPO/archive/$ref.tar.gz" | tar -xz -C "$work" --strip-components 1 \
    || fail "Couldn't download $ref from github.com/$REPO."

  say "Setting up the Macapad Dev signing certificate"
  "$work/scripts/make-signing-cert.sh"

  say "Building (a few minutes the first time)"
  ( cd "$work" && VERSION="$version" ./scripts/build-app.sh ) \
    || fail "The build failed. The output above says why."

  say "Installing to $DEST"
  pkill -x Macapad 2>/dev/null || true
  # copying over the app while it's still quitting can fail
  for _ in {1..25}; do pgrep -x Macapad >/dev/null || break; sleep 0.2; done
  local sudo=""
  [[ -w "$DEST" ]] || { sudo="sudo"; echo "$DEST needs your password to write to."; }
  $sudo rm -rf "$DEST/Macapad.app"
  $sudo ditto "$work/build/Macapad.app" "$DEST/Macapad.app"

  if [[ -d "$HOME/Applications/Macapad.app" ]]; then
    echo "note: there's another copy in ~/Applications. Delete it so you don't open the old one."
  fi

  open "$DEST/Macapad.app"
  say "Macapad ${version:-$ref} is installed and running (look for it in the menu bar)."
  echo "The first time, allow it in System Settings > Privacy & Security > Accessibility."
}

main "$@"
