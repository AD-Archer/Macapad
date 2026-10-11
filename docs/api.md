# HTTP and WebSocket API

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

- **Device tokens** come from [pairing](pairing.md). Each device gets its own, and you can remove one in Settings without touching the others. Only a hash is stored on the Mac (`~/.macapad/devices.json`).
- **The owner token** lives in `~/.macapad/token`, for scripts and frontends set up by hand. Delete that file and relaunch to get a new one.

### Naming your client

Requests with the owner token must also say who's calling, or they get `400`:

- HTTP: `X-Macapad-Client: Office display` (percent-encode names that aren't plain ASCII)
- WebSocket: `?client=Office%20display`

Each name shows up in Settings with its own schedule and pause, so one server can call for several screens
(archersdesk does: one name per screen) and each can keep different hours. Paired devices already have a name, so for
them it's optional; one that sends it gets a named client under the device, which follows the device's schedule
unless you pick another.

Add `X-Macapad-Client-Id` (or `?clientId=`), a stable id up to 64 characters, to keep a client's settings when it's
renamed. Names are matched ignoring case. Each token can have up to 40 named clients.

## HTTP API

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/health` | none (no token needed) | `{"ok":true,"name":"macapad","version":"0.3.0","network":"lan","mac":{"id","name"},"pairing":true}`; `mac` and `pairing` only where the Mac is discoverable |
| POST | `/api/pair` | `{"name","app"?}` (no token needed) | `{"id","code","expiresIn","mac"}`; see [pairing](pairing.md) |
| POST | `/api/pair/qr` | `{"key","name","app"?}` (no token needed) | `{"status":"approved","token","device","mac"}`; see [pairing by QR code](pairing.md) |
| GET | `/api/pair/:id?wait=25` | none (no token needed) | `{"status":"pending"\|"approved"\|"denied"\|"expired","token"?,"device"?}` |
| GET | `/api/me` | none | `{"owner":false,"device":{…},"client":{…},"mac":{…},"off":{…}}`: who your token belongs to and the client you named; `off` only while it [can't run anything](#paused-and-off-hours) |
| DELETE | `/api/me` | none | `{"ok":true}`: unpairs this device (owner token can't) |
| POST | `/api/run` | `{"steps":[...]}` | `{"ok":true}` or `{"ok":false,"error":"Step 2: ..."}`; `423` while [paused or off hours](#paused-and-off-hours) |
| GET | `/api/actions` | none | `{"actions":[...]}`: built-ins, then yours |
| POST | `/api/actions` | an action | the saved action (adds, or replaces the same `id`) |
| DELETE | `/api/actions/:id` | none | `{"ok":true}`; built-ins can't be deleted |
| GET | `/api/apps` | none | `{"apps":[{"name","bundleId","path"}]}` |
| GET | `/api/apps/icon?bundleId=…&size=128` | none | the app's icon as a PNG (16–512 px) |
| GET | `/api/shortcuts` | none | `{"shortcuts":["name", …]}` from the Shortcuts app |
| GET | `/api/status` | none | what the Mac is doing now; see [Status](#status) |
| GET | `/api/status/artwork?size=256` | none | the playing track's artwork as a PNG (16–512 px); `404` when there is none |

`/api/run` waits until all steps finish. Errors in the request itself (bad JSON, unknown step type)
return a 4xx status with `{"error":{"message":"..."}}`.

```sh
curl -X POST http://localhost:7317/api/run \
  -H "Authorization: Bearer $(cat ~/.macapad/token)" \
  -H "X-Macapad-Client: My script" \
  -H "Content-Type: application/json" \
  -d '{"steps":[{"type":"media","key":"playPause"}]}'
```

### Status

`GET /api/status` is for frontends with a screen to fill. It's cheap enough to poll every couple of seconds.

```json
{ "time": "2026-10-10T20:31:36Z", "utcOffset": -14400,
  "mac": { "id": "…", "name": "arch’s MacBook Air" }, "frontApp": "Safari",
  "nowPlaying": { "app": "Spotify", "bundleId": "com.spotify.client", "playing": true, "title": "…", "artist": "…", "album": "…",
                  "duration": 215000, "position": 81000, "artworkId": "9f2c01aa" },
  "stats": { "cpu": 31, "memoryUsed": 12865634304, "memoryTotal": 17179869184,
             "battery": 31, "charging": false, "pluggedIn": false,
             "diskFree": 32191135862, "diskTotal": 245107195904, "uptime": 151635, "thermal": "nominal" } }
```

- `time` and `utcOffset` are the Mac's clock, for devices whose own clock is wrong.
- `nowPlaying` is missing when nothing is playing or paused. It's what Control Center shows, from any app (Spotify,
  Music, a browser tab, a podcast app…), read through the bundled
  [mediaremote-adapter](../Vendor/mediaremote-adapter/VENDORED.md): macOS only lets Apple-signed programs read it, so
  Macapad has `/usr/bin/perl` load a small framework that streams it back. If that stops working (a macOS update
  can close the gap), Macapad falls back to asking **Spotify and Music** over AppleScript; the first time, macOS asks
  whether Macapad may control each app. `app` is the player's name and `bundleId` its bundle id. Times are in
  milliseconds.
- `artworkId` changes with the track; fetch `/api/status/artwork` again when it does. Missing = no artwork.
- `cpu` is percent of all cores since the previous call. Sizes are bytes. `battery`, `charging` and `pluggedIn` are
  missing on Macs without a battery. `off` is the same object as in [`/api/me`](#paused-and-off-hours).

### Paused and off hours

While the Mac is paused, the device or client is paused, or it's outside its schedule (the client's, or else the
device's), `/api/run` runs nothing and returns `423`:

```json
{ "error": { "message": "Outside Work hours. Office display is off until Monday at 9:00 AM" },
  "off": { "reason": "schedule", "until": "2026-10-19T13:00:00Z", "message": "Outside Work hours. …" } }
```

`reason` is `mac` (everything is paused), `device` (the device or client is paused) or `schedule`. `until` is when
it can run again, taking all of them into account; it's missing when it stays off until someone turns it back on.
`message` is ready to show. `GET /api/me` has the same `off` object, so a frontend can grey out its buttons up front.

## WebSocket: `/api/ws?token=...&client=...`

Use this for a frontend that stays open. It's faster than a new HTTP request for every press.

**The server sends:**

- `{"type":"result","ref":"...","ok":true,"error":""}`: after each `run`, with the `ref` you sent. When nothing ran
  because of a [pause or schedule](#paused-and-off-hours) it's `"ok":false` with an `off` object too.
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
