# Macapad

A menu bar app that lets any frontend control your Mac over HTTP and WebSocket:
media keys, keyboard shortcuts, opening URLs and apps, running Shortcuts and AppleScript.
It also stores a deck of buttons that frontends can share.

## Run it

```sh
./scripts/build-app.sh --install   # builds, copies to ~/Applications, launches
```

On first launch, grant **Accessibility** access (System Settings → Privacy & Security → Accessibility).
Media keys, shortcuts and typing need it.

For development: `swift run`. The menu bar shows a fallback grid icon because the custom icons only load from the bundled app. Set `MACAPAD_PORT` to change the port (default `7317`).

The menu bar icon has **Copy API URL** and **Copy API Token** items.

## Connecting

| From | Base URL |
|---|---|
| Same Wi-Fi | `http://<mac-name>.local:7317` or `http://<lan-ip>:7317` |
| Anywhere on your tailnet | `http://<tailscale-ip>:7317` |
| Tailnet over HTTPS | `https://<mac>.<tailnet>.ts.net` (after `tailscale serve --bg 7317`) |

**If your frontend page is served over `https://`, it must call the HTTPS URL.**
Browsers block `https` pages from calling `http` addresses (mixed content).

CORS is open to any origin. Every request except `/api/health` needs the token:

- HTTP: `Authorization: Bearer <token>`
- WebSocket: `?token=<token>` (browsers can't set headers on WebSockets)

The token lives in `~/.macapad/token`. Delete that file and relaunch to get a new one.

## Steps

Everything the Mac can do is a **step**, written as `{"type": ..., ...}`.
A button or a request runs a list of steps in order and stops at the first failure.

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

The `media` steps send real media-key presses, so they control whatever app is playing,
just like the keys on your keyboard.

The `keystroke` field takes:

- **Modifiers:** `cmd`, `shift`, `opt`/`alt`, `ctrl`, `fn`.
- **Keys:** `a`–`z`, `0`–`9`, punctuation, `f1`–`f20`, `left`, `right`, `up`, `down`,
  `space`, `return`, `tab`, `esc`, `delete`, `forwarddelete`, `home`, `end`, `pageup`, `pagedown`.

Keys map to physical positions on a US keyboard layout.

## HTTP API

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/health` | none (no token needed) | `{"ok":true,"name":"macapad","version":"0.1.0"}` |
| POST | `/api/run` | `{"steps":[...]}` | `{"ok":true}` or `{"ok":false,"error":"Step 2: ..."}` |
| GET | `/api/deck` | none | the deck |
| PUT | `/api/deck` | the whole deck | the saved deck, or `400` with the problem |
| POST | `/api/buttons/:id/press` | none | same as `/api/run` |

`/api/run` waits until all steps finish. Errors in the request itself (bad JSON, unknown step type)
return a 4xx status with `{"error":{"message":"..."}}`.

```sh
curl -X POST http://localhost:7317/api/run \
  -H "Authorization: Bearer $(cat ~/.macapad/token)" \
  -H "Content-Type: application/json" \
  -d '{"steps":[{"type":"media","key":"playPause"}]}'
```

## WebSocket: `/api/ws?token=...`

Use this for a frontend that stays open. Presses are faster than HTTP, and deck changes arrive live.

**The server sends:**

- `{"type":"deck","deck":{...}}`: when you connect, and whenever the deck changes
  (from any client or a hand edit of `deck.json`).
- `{"type":"result","ref":"...","ok":true,"error":""}`: after each `press` or `run`.
- `{"type":"pong"}`: in reply to `ping`.

**You send:**

- `{"type":"press","id":"<button id>"}`: the result's `ref` is the button id.
- `{"type":"run","ref":"<anything>","steps":[...]}`
- `{"type":"ping"}`: send one every ~25s to keep proxies from closing the connection.

```js
const ws = new WebSocket(`${base.replace(/^http/, "ws")}/api/ws?token=${token}`);
ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.type === "deck") render(msg.deck);
  if (msg.type === "result" && !msg.ok) alert(msg.error);
};
ws.send(JSON.stringify({ type: "run", ref: "skip", steps: [{ type: "media", key: "next" }] }));
```

## The deck

The deck is optional shared storage, so every frontend shows the same buttons.
You can ignore it and only use `/api/run`.

It's stored in `~/.macapad/deck.json`. Edit it by hand and connected clients update within moments.

```json
{
  "version": 1,
  "pages": [
    {
      "id": "main", "name": "Main", "columns": 4,
      "buttons": [
        { "id": "playpause", "label": "Play / Pause", "icon": "⏯", "color": "#1db954",
          "steps": [{ "type": "media", "key": "playPause" }] },
        { "id": "sites", "label": "Sites", "icon": "🌐", "steps": [], "page": "sites" }
      ]
    },
    { "id": "sites", "name": "Sites", "folder": true, "buttons": [] }
  ]
}
```

- `columns`, `icon` and `color` are hints for frontends. The Mac ignores them.
- A button with `page` opens that page (a folder) instead of running steps.
- Pages with `"folder": true` are only reachable from such a button.
- The server rejects a deck with duplicate ids, links to missing pages, or no non-folder page.

## Icons

The artwork lives in `assets/`. `icon-source.png` becomes the app icon, and `menubar-source.png`
(a transparent cut-out) becomes the menu bar icon. To regenerate the files in `Resources/`
after changing them:

```sh
python3 scripts/make-icons.py   # needs Pillow: pip install pillow
./scripts/build-app.sh --install
```
