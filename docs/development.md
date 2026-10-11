# Developing Macapad

## Building

You need Xcode or the Command Line Tools (`xcode-select --install`). The Now Playing adapter builds with
CMake if you have it, and with plain clang if you don't. Tasks run through
[just](https://github.com/casey/just) (`brew install just`); `just` lists them.
Each one calls a script in `scripts/`, which you can also run directly.

```sh
git clone https://github.com/AD-Archer/Macapad.git && cd Macapad
just cert      # once; see below
just install   # builds, copies to ~/Applications, launches
```

Run `just cert` once before building. It adds a self-signed "Macapad Dev"
certificate to your login keychain, and the build signs with it, so macOS keeps the Accessibility
permission across rebuilds. Without it the app is signed ad-hoc and every rebuild counts as a new app.

For development: `just dev` (runs `swift run`; `just dev 7399` for another port). The menu bar shows a fallback grid icon because the custom icons only load from the bundled app. Set `MACAPAD_PORT` to change the port (default `7317`).


## Icons

The artwork lives in `assets/`. `icon-source.png` becomes the app icon, and `menubar-source.png`
(a transparent cut-out) becomes the menu bar icon. To regenerate the files in `Resources/`
after changing them:

```sh
just icons     # needs Pillow: pip install pillow
just install
```
