# mediaremote-adapter (vendored)

From https://github.com/ungive/mediaremote-adapter at commit `797729d9b16316dc313844476c153d7a107ca0df`
(2026-10-10), BSD 3-Clause (see LICENSE). Unmodified; `scripts/` and the README were left out.

It lets Macapad read the system-wide Now Playing info, which macOS 15.4+ only allows Apple-signed processes to
read: `/usr/bin/perl` runs `bin/mediaremote-adapter.pl`, which loads `MediaRemoteAdapter.framework`.
`scripts/build-app.sh` builds the framework with CMake and bundles both into
`Macapad.app/Contents/Resources/MediaRemoteAdapter/`. Used by `Sources/Macapad/Status.swift`.

To update: copy `CMakeLists.txt`, `LICENSE`, `bin/`, `include/` and `src/` from a newer commit and change the hash above.
