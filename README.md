<p align="center">
  <img src="assets/icon-source.png" alt="Macapad's yellow smiling face" width="220">
</p>

# Macapad

A menu bar app that lets any frontend control your Mac over HTTP and WebSocket:
media keys, keyboard shortcuts, opening URLs and apps, running Shortcuts and AppleScript.
Macapad has no interface of its own. You build the frontend; Macapad runs whatever steps it sends.

## Run it

```sh
./scripts/build-app.sh --install   # builds, copies to ~/Applications, launches
```

On first launch, grant **Accessibility** access (System Settings → Privacy & Security → Accessibility).
Media keys, shortcuts and typing need it.

Run `./scripts/make-signing-cert.sh` once before building. It adds a self-signed "Macapad Dev"
certificate to your login keychain, and the build signs with it, so macOS keeps the Accessibility
permission across rebuilds. Without it the app is signed ad-hoc and every rebuild counts as a new app.

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

`/api/run` waits until all steps finish. Errors in the request itself (bad JSON, unknown step type)
return a 4xx status with `{"error":{"message":"..."}}`.

```sh
curl -X POST http://localhost:7317/api/run \
  -H "Authorization: Bearer $(cat ~/.macapad/token)" \
  -H "Content-Type: application/json" \
  -d '{"steps":[{"type":"media","key":"playPause"}]}'
```

## WebSocket: `/api/ws?token=...`

Use this for a frontend that stays open. It's faster than a new HTTP request for every press.

**The server sends:**

- `{"type":"result","ref":"...","ok":true,"error":""}`: after each `run`, with the `ref` you sent.
- `{"type":"pong"}`: in reply to `ping`.

**You send:**

- `{"type":"run","ref":"<anything>","steps":[...]}`
- `{"type":"ping"}`: send one every ~25s to keep proxies from closing the connection.

```js
const ws = new WebSocket(`${base.replace(/^http/, "ws")}/api/ws?token=${token}`);
ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.type === "result" && !msg.ok) alert(msg.error);
};
ws.onopen = () => {
  ws.send(JSON.stringify({ type: "run", ref: "skip", steps: [{ type: "media", key: "next" }] }));
};
```

## Icons

The artwork lives in `assets/`. `icon-source.png` becomes the app icon, and `menubar-source.png`
(a transparent cut-out) becomes the menu bar icon. To regenerate the files in `Resources/`
after changing them:

```sh
python3 scripts/make-icons.py   # needs Pillow: pip install pillow
./scripts/build-app.sh --install
```
