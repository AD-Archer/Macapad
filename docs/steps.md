# Steps and actions

## Steps

Everything the Mac can do is a **step**, written as `{"type": ..., ...}`.
Each request runs a list of steps in order and stops at the first failure.

| type | fields | example |
|---|---|---|
| `media` | `key`: `playPause` `next` `previous` `volumeUp` `volumeDown` `mute` | `{"type":"media","key":"next"}` |
| `keystroke` | `keys`: modifiers + one key | `{"type":"keystroke","keys":"cmd+shift+t"}` |
| `typeText` | `text` | `{"type":"typeText","text":"hello"}` |
| `openURL` | `url` (opens in the default browser) | `{"type":"openURL","url":"https://hackclub.com"}` |
| `openApp` | `app`: name or bundle id | `{"type":"openApp","app":"Spotify"}` |
| `shortcut` | `name`: as shown in the Shortcuts app | `{"type":"shortcut","name":"Focus Mode"}` |
| `appleScript` | `source` | `{"type":"appleScript","source":"beep"}` |
| `wait` | `ms` (max 60000) | `{"type":"wait","ms":500}` |
| `action` | `id` of a built-in or custom action | `{"type":"action","id":"reload"}` |

The `media` steps send real media-key presses, so they control whatever app is playing,
just like the keys on your keyboard.

The `keystroke` field takes:

- **Modifiers:** `cmd`, `shift`, `opt`/`alt`, `ctrl`, `fn`.
- **Keys:** `a`–`z`, `0`–`9`, punctuation, `f1`–`f20`, `left`, `right`, `up`, `down`,
  `space`, `return`, `tab`, `esc`, `delete`, `forwarddelete`, `home`, `end`, `pageup`, `pagedown`.

Keys map to physical positions on a US keyboard layout.

## Actions

An action is a named list of steps that any request can run with `{"type":"action","id":"…"}`.

```json
{ "id": "reload", "name": "Reload", "icon": "refresh", "category": "browser",
  "steps": [{ "type": "keystroke", "keys": "cmd+r" }], "custom": false }
```

`icon` is a [Material Symbols](https://fonts.google.com/icons) name, a hint for frontends.

**Built-ins:**

| category | ids |
|---|---|
| media | `play-pause` `next-track` `previous-track` `volume-up` `volume-down` `mute` |
| system | `emoji` `spotlight` `screenshot-ui` `screenshot-area` `screenshot-screen` `mission-control` `app-windows` `lock-screen` |
| windows | `minimize` `fullscreen` `close-window` `next-window` `hide-app` `quit-app` |
| browser | `reload` `hard-reload` `new-tab` `close-tab` `reopen-tab` `next-tab` `previous-tab` `address-bar` |
| editing | `copy` `paste` `cut` `undo` `redo` `select-all` `find` `save` |

**Your own:** `POST /api/actions` saves one in `~/.macapad/actions.json`. Leave `id` empty and one is
made from the name. Ids are lowercase letters, numbers and dashes, and can't reuse a built-in id.
Actions can run other actions, nested up to 4 deep.
