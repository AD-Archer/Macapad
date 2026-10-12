# Steps and actions

## Steps

Everything the Mac can do is a **step**, written as `{"type": ..., ...}`.
Each request runs a list of steps in order and stops at the first failure.

| type | fields | example |
|---|---|---|
| `media` | `key`: `playPause` `next` `previous` `volumeUp` `volumeDown` `mute` `brightnessUp` `brightnessDown` | `{"type":"media","key":"next"}` |
| `keystroke` | `keys`: modifiers + one key | `{"type":"keystroke","keys":"cmd+shift+t"}` |
| `typeText` | `text` | `{"type":"typeText","text":"hello"}` |
| `openURL` | `url` (opens in the default browser) | `{"type":"openURL","url":"https://hackclub.com"}` |
| `openApp` | `app`: name or bundle id | `{"type":"openApp","app":"Spotify"}` |
| `shortcut` | `name`: as shown in the Shortcuts app | `{"type":"shortcut","name":"Focus Mode"}` |
| `appleScript` | `source` | `{"type":"appleScript","source":"beep"}` |
| `wait` | `ms` (max 60000) | `{"type":"wait","ms":500}` |
| `action` | `id` of a built-in or custom action | `{"type":"action","id":"reload"}` |
| `window` | `to`: where the front window goes (below) | `{"type":"window","to":"left"}` |
| `keepAwake` | `on` (leave out to switch it), `minutes` (leave out for until it's turned off) | `{"type":"keepAwake","minutes":60}` |
| `jiggler` | the same | `{"type":"jiggler","on":true}` |
| `click` | `button`: `left` (default) `right` `middle`; `count`: 1 or 2 | `{"type":"click","button":"right"}` |
| `scroll` | `dx`, `dy` in lines; positive `dy` scrolls down | `{"type":"scroll","dy":5}` |
| `moveMouse` | `dx`, `dy` in points | `{"type":"moveMouse","dx":100,"dy":0}` |
| `toggle` | `setting`: `wifi` `bluetooth` `hiddenFiles` `stageManager` `darkMode`; `on` (leave out to switch it) | `{"type":"toggle","setting":"darkMode"}` |

The `media` steps send real media-key presses, so they control whatever app is playing,
just like the keys on your keyboard.

The `keystroke` field takes:

- **Modifiers:** `cmd`, `shift`, `opt`/`alt`, `ctrl`, `fn`.
- **Keys:** `a`–`z`, `0`–`9`, punctuation, `f1`–`f20`, `left`, `right`, `up`, `down`,
  `space`, `return`, `tab`, `esc`, `delete`, `forwarddelete`, `home`, `end`, `pageup`, `pagedown`.

Keys map to physical positions on a US keyboard layout.

`window` moves and resizes the window in front, on the screen it's on (leaving the menu bar and Dock clear):
`left` `right` `top` `bottom` (halves), `top-left` `top-right` `bottom-left` `bottom-right` (quarters),
`left-third` `center-third` `right-third` `left-two-thirds` `right-two-thirds`, `maximize`, `center`,
`next-display`, and `restore`, which puts the window back where it was before Macapad last moved it.

`keepAwake` stops the Mac's display and idle sleep. `jiggler` nudges the pointer a pixel and back whenever the Mac
has been idle for 30 seconds, so the Mac, and apps like Slack and Teams, never count you as away. Both show in the
menu bar, stop when their `minutes` run out, and turn off when Macapad quits. `/api/status` says whether each is on.

`toggle` turns a Mac setting on or off. `hiddenFiles` relaunches Finder so it shows the change. Turning off
Wi-Fi or Bluetooth also cuts off any device that reaches the Mac that way, and it can't turn it back on.

To hold keys down or move the pointer in real time (a controller or trackpad), use
[live input](api.md#live-input) instead of steps.

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
| system | `emoji` `spotlight` `screenshot-ui` `screenshot-area` `screenshot-screen` `mission-control` `app-windows` `lock-screen` `keep-awake` `jiggler` `siri` `brightness-up` `brightness-down` `dark-mode` `wifi` `bluetooth` `stage-manager` `hidden-files` `empty-trash` `eject-disks` `sleep-display` `sleep` `restart` `shut-down` `screen-saver` `show-desktop` `force-quit` |
| accessibility | `accessibility-shortcuts` `voiceover` `zoom` `zoom-in` `zoom-out` `invert-colors` `speak-selection` |
| windows | `minimize` `fullscreen` `close-window` `next-window` `hide-app` `quit-app` `window-left` `window-right` `window-top` `window-bottom` `window-top-left` `window-top-right` `window-bottom-left` `window-bottom-right` `window-maximize` `window-center` `window-next-display` `window-restore` |
| mouse | `left-click` `right-click` |
| browser | `reload` `hard-reload` `new-tab` `close-tab` `reopen-tab` `next-tab` `previous-tab` `address-bar` |
| editing | `copy` `paste` `cut` `undo` `redo` `select-all` `find` `save` |

`keep-awake`, `jiggler`, `dark-mode`, `wifi`, `bluetooth`, `stage-manager` and `hidden-files` switch on and off.
`restart` and `shut down` ask open apps to quit first, so unsaved work still gets its "Save?" prompt. `dark-mode`,
`restart` and `shut-down` ask the first time whether Macapad may control System Events; `empty-trash` and
`eject-disks` ask about Finder. In the accessibility category, `accessibility-shortcuts` (the panel that turns Zoom, VoiceOver, Invert colors
and the rest on and off) and `voiceover` work out of the box; `zoom`, `zoom-in`, `zoom-out`, `invert-colors` and
`speak-selection` need their keyboard shortcut turned on first, in System Settings > Accessibility (Zoom, Spoken
Content) or Keyboard > Keyboard Shortcuts > Accessibility.

**Your own:** `POST /api/actions` saves one in `~/.macapad/actions.json`. Leave `id` empty and one is
made from the name. Ids are lowercase letters, numbers and dashes, and can't reuse a built-in id.
Actions can run other actions, nested up to 4 deep.
