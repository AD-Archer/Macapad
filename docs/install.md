# Installing Macapad

Macapad needs an Apple Silicon Mac on macOS 14 or later.

## With one command

```sh
curl -fsSL https://raw.githubusercontent.com/AD-Archer/Macapad/main/scripts/install.sh | bash
```

This builds Macapad on your Mac from the latest release and copies it to `/Applications`, so there's no
Homebrew and no `xattr`. It needs Apple's Command Line Tools; if you don't have them, it opens their installer
and you run the command again afterwards. The first build takes a few minutes.

It signs the app with a self-signed "Macapad Dev" certificate it adds to your login keychain. An app you build
yourself is never quarantined, so Gatekeeper opens it.

Run the same command to update. The certificate stays the same, so you only grant Accessibility once.
To build a branch or tag instead of the latest release: `curl -fsSL ... | MACAPAD_REF=main bash`.

## With Homebrew

```sh
brew tap ad-archer/tap
brew trust ad-archer/tap        # Homebrew 6+ only loads third-party taps you trust
brew install --cask macapad
xattr -dr com.apple.quarantine /Applications/Macapad.app
```

To trust only Macapad instead of the whole tap, use `brew trust --cask ad-archer/tap/macapad`.

## By hand

Download `Macapad.zip` from [Releases](https://github.com/AD-Archer/Macapad/releases),
unzip it, move `Macapad.app` to `/Applications`, then run the same `xattr` command.

**Why `xattr`?** The release build isn't signed with an Apple Developer ID. macOS quarantines everything
downloaded from the internet, and Gatekeeper won't open an unsigned quarantined app (it often says it "is
damaged"). `xattr -dr com.apple.quarantine` removes that flag. Run it again after each upgrade.

**After each upgrade, grant Accessibility again.** A release build looks like a new app to macOS every time it
changes. In System Settings > Privacy & Security > Accessibility, remove Macapad and add it again.
The one-command install doesn't have this problem.

## Updating

Macapad checks GitHub for a newer release every few hours (turn it off in **Settings → Updates**). When one is out:

- **One-command install:** the menu bar shows **Update to Macapad …**. It runs the same install script for that
  release in the background, then reopens Macapad on the new version. It takes a few minutes, and you keep
  Accessibility access. To skip the click, turn on **Settings → Updates → Install updates by itself**. If it fails,
  the menu bar says why and the full output is in `~/.macapad/update.log`. Running the install command again also updates.
- **Homebrew:** the menu bar item copies `brew upgrade --cask macapad`. Run it, then the `xattr` command.
- **A copy somewhere other than `/Applications`:** the menu bar item opens the Releases page.

## First launch

Grant **Accessibility** access (System Settings → Privacy & Security → Accessibility).
Media keys, shortcuts and typing need it.
