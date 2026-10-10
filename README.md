<p align="center">
  <img src="assets/icon-source.png" alt="Macapad's yellow smiling face" width="220">
</p>

# Macapad

A menu bar app that lets any frontend control your Mac over HTTP and WebSocket:
media keys, keyboard shortcuts, opening URLs and apps, running Shortcuts and AppleScript.
Macapad has no interface of its own. You build the frontend; Macapad runs whatever steps it sends.

## Warning
This probably isn't safe to expose to the web, do not allow your mac to be controlled outisde of your lan unless you know what you're doing

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

The menu bar icon has **Copy API URL**, **Copy API Token** and **Settings…** items.

## Settings

**Settings…** in the menu bar (⌘,) controls who can reach the Mac. They're saved in `~/.macapad/settings.json`.

| Setting | Default | What it does |
|---|---|---|
| Name | the Mac's name | What devices see when they find this Mac |
| Local network → Allow connections | on | Accept requests from devices on your Wi-Fi/Ethernet |
| Local network → Let devices find this Mac | on | Advertise over Bonjour and accept pairing requests from the LAN |
| Tailscale → Allow connections | on | Accept requests from your tailnet (directly or through `tailscale serve`) |
| Tailscale → Let devices find this Mac | on | Show the Mac's name in `/api/health` and accept pairing requests from the tailnet |
| Internet → Allow connections | off | Accept requests from any other address (port forwarding, Tailscale Funnel). Pairing is never allowed from here |
| Paired devices | | Every device you've allowed, with **Remove** to cut one off |

Programs on the Mac itself (localhost) are always allowed. A request from a network that's turned off gets `403`.

## Connecting

| From | Base URL |
|---|---|
| Same Wi-Fi | `http://<mac-name>.local:7317` or `http://<lan-ip>:7317` |
| Anywhere on your tailnet | `http://<tailscale-ip>:7317` |
| Tailnet over HTTPS | `https://<mac>.<tailnet>.ts.net` (after `tailscale serve --bg 7317`) |

**If your frontend page is served over `https://`, it must call the HTTPS URL.**
Browsers block `https` pages from calling `http` addresses (mixed content).

CORS is open to any origin. Every request except `/api/health` and pairing needs a token:

- HTTP: `Authorization: Bearer <token>`
- WebSocket: `?token=<token>` (browsers can't set headers on WebSockets)

There are two kinds of token:

- **Device tokens** come from [pairing](#discovery-and-pairing). Each device gets its own, and you can remove one in Settings without touching the others. Only a hash is stored on the Mac (`~/.macapad/devices.json`).
- **The owner token** lives in `~/.macapad/token`, for scripts and frontends set up by hand. Delete that file and relaunch to get a new one.

## Discovery and pairing

Frontends can find the Mac and ask for a token instead of you copying one over.

**Finding Macs.**

- *Local network:* Macapad advertises `_macapad._tcp` over Bonjour, with `id`, `name` and `v` in its TXT record.
  Browsers can't browse Bonjour, so a web frontend needs a small server (or the native app it runs in) to do this.
- *Tailscale:* there's no multicast on a tailnet. List your devices (`tailscale status --json`) and call
  `GET http://<tailscale-ip>:7317/api/health` on each. A Mac that's discoverable answers with a `mac` field.

The same Mac found both ways has the same `mac.id`, so you can merge them.

**Pairing.**

1. `POST /api/pair` with `{"name":"Kitchen iPad","app":"archersdesk"}`. You get back
   `{"id":"<secret>","code":"4821","expiresIn":120,"mac":{...}}`. Show the `code` to the person.
2. The Mac pops up a prompt with the device name and the same code, and asks Allow / Don't Allow.
3. Poll `GET /api/pair/<id>?wait=25`. Each call waits up to 25 s for a decision, then returns
   `{"status":"pending"}`, `{"status":"approved","token":"…","device":{…}}`, `{"status":"denied"}` or `{"status":"expired"}`.
   The token is handed out once; keep it.

Requests expire after two minutes. A device can only have one request waiting at a time, and the Mac holds at most three.

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

## HTTP API

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/health` | none (no token needed) | `{"ok":true,"name":"macapad","version":"0.3.0","network":"lan","mac":{"id","name"},"pairing":true}`; `mac` and `pairing` only where the Mac is discoverable |
| POST | `/api/pair` | `{"name","app"?}` (no token needed) | `{"id","code","expiresIn","mac"}`; see [pairing](#discovery-and-pairing) |
| GET | `/api/pair/:id?wait=25` | none (no token needed) | `{"status":"pending"\|"approved"\|"denied"\|"expired","token"?,"device"?}` |
| GET | `/api/me` | none | `{"owner":false,"device":{…},"mac":{…}}`: who your token belongs to |
| DELETE | `/api/me` | none | `{"ok":true}`: unpairs this device (owner token can't) |
| POST | `/api/run` | `{"steps":[...]}` | `{"ok":true}` or `{"ok":false,"error":"Step 2: ..."}` |
| GET | `/api/actions` | none | `{"actions":[...]}`: built-ins, then yours |
| POST | `/api/actions` | an action | the saved action (adds, or replaces the same `id`) |
| DELETE | `/api/actions/:id` | none | `{"ok":true}`; built-ins can't be deleted |
| GET | `/api/apps` | none | `{"apps":[{"name","bundleId","path"}]}` |
| GET | `/api/apps/icon?bundleId=…&size=128` | none | the app's icon as a PNG (16–512 px) |
| GET | `/api/shortcuts` | none | `{"shortcuts":["name", …]}` from the Shortcuts app |

`/api/run` waits until all steps finish. Errors in the request itself (bad JSON, unknown step type)
return a 4xx status with `{"error":{"message":"..."}}`.

```sh
curl -X POST http://localhost:7317/api/run \
  -H "Authorization: Bearer $(cat ~/.macapad/token)" \
  -H "Content-Type: application/json" \
  -d '{"steps":[{"type":"media","key":"playPause"}]}'
```

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

## WebSocket: `/api/ws?token=...`

Use this for a frontend that stays open. It's faster than a new HTTP request for every press.

**The server sends:**

- `{"type":"result","ref":"...","ok":true,"error":""}`: after each `run`, with the `ref` you sent.
- `{"type":"pong"}`: in reply to `ping`.

**You send:**

- `{"type":"run","ref":"<anything>","steps":[...]}`
- `{"type":"ping"}`: send one every ~25s to keep proxies from closing the connection.

If you remove a device in Settings, its open WebSocket is closed the next time it sends anything.

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

## Tester

`tester/` is a throwaway web app for trying discovery and pairing from a phone. Its Node server finds Macs
(Bonjour + your tailnet); the page then pairs and presses media keys by talking straight to the Mac.

```sh
cd tester && pnpm install && pnpm start   # then open http://<this-computer>:7318 on your phone
```

Run it on the Mac and open it from your phone to see the LAN and Tailscale settings take effect. Opened on the
Mac itself, every request counts as "this Mac", which is always allowed.

## Icons

The artwork lives in `assets/`. `icon-source.png` becomes the app icon, and `menubar-source.png`
(a transparent cut-out) becomes the menu bar icon. To regenerate the files in `Resources/`
after changing them:

```sh
python3 scripts/make-icons.py   # needs Pillow: pip install pillow
./scripts/build-app.sh --install
```
