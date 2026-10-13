<p align="center">
  <img src="assets/icon-source.png" alt="Macapad's yellow smiling face" width="160">
</p>

# Macapad

A menu bar app that lets other devices control your Mac: media keys, keyboard shortcuts, opening apps and URLs,
running Shortcuts and AppleScript. Can be used by a client over http

<div align="center">
<table>
  <tr>
    <td align="center">
      <img src="assets/image.png" alt="archersdesk: a pad of eight keys on a black screen: volume down, volume up, previous, next, play/pause, mute, and app icons for Supersonic and Firefox Developer Edition" height="160"><br>
      <a href="https://github.com/AD-Archer/archersdesk"><b>archersdesk</b></a>
    </td>
    <td align="center">
      <img src="https://github.com/AD-Archer/vita-macapad/raw/main/screenshots/dashboard.png" alt="vita-macapad: the time and date, the weather, the song playing on the Mac with its artwork, progress and play controls, and the Mac's CPU, memory, battery and disk" height="160"><br>
      <a href="https://github.com/AD-Archer/vita-macapad"><b>vita-macapad</b></a>
    </td>
    <td align="center">
      <img src="https://github.com/AD-Archer/3ds-macapad/raw/main/screenshots/dashboard.png" alt="3ds-macapad: the time and weather, a now playing card, CPU, memory, battery and disk tiles, and a page of media and system buttons" height="160"><br>
      <a href="https://github.com/AD-Archer/3ds-macapad"><b>3ds-macapad</b></a>
    </td>
  </tr>
</table>
</div>

## Install

Apple Silicon, macOS 14 or later:

```sh
curl -fsSL https://raw.githubusercontent.com/AD-Archer/Macapad/main/scripts/install.sh | bash
```

Then allow Macapad in System Settings > Privacy & Security > Accessibility.
Homebrew and other ways: [docs/install.md](docs/install.md).

> [!WARNING]
> Keep Macapad on your local network or tailnet. Don't expose it to the internet unless you know what you're doing.

## Clients(as of right now)

- [archersdesk](https://github.com/AD-Archer/archersdesk): a web dashboard for wall screens, tablets and phones.
- [vita-macapad](https://github.com/AD-Archer/vita-macapad): a PlayStation Vita app.
- [3ds-macapad](https://github.com/AD-Archer/3ds-macapad): a Nintendo 3DS app.

## Features
- Mouse Jiggeler
- Use Client device as controller
- Stop device from sleeping
- Accesibilty settings
- Toggle wifi/bluetooth

## Docs

- [Install](docs/install.md)
- [Settings](docs/settings.md): who can reach the Mac, pausing, schedules, Wi-Fi places
- [API](docs/api.md): connecting, tokens, HTTP endpoints, status, WebSocket
- [Pairing](docs/pairing.md): finding Macs and getting a token, by code or QR
- [Steps and actions](docs/steps.md): everything the Mac can do
- [Docs page](docs/docs-page.md): try the API from your phone
- [Development](docs/development.md): building, releasing, icons
