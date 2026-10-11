# Discovery and pairing

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

**Pairing by QR code.** For frontends with a camera. **Pair with QR Code…** in the menu bar (or in Settings)
shows a code that pairs straight away, with no Allow prompt: seeing the screen is the proof. It holds a link:

```
macapad://pair?v=1&id=<mac id>&name=<mac name>&key=<one-time key>&url=http://192.168.1.20:7317&url=http://100.101.102.103:7317
```

There's one `url` per address the Mac can be reached at, best first (local network, then Tailscale), and only for
networks where the Mac lets devices find it. Values are percent-encoded except `:` and `/`. Use the first `url` that
answers `/api/health`, then `POST <url>/api/pair/qr` with `{"key":"…","name":"Kitchen iPad","app":"archersdesk"}`.
You get `{"status":"approved","token":"…","device":{…},"mac":{…}}`. Keep the token; it's handed out once.

Each key works once (a new code appears after every scan), expires after five minutes, and stops working as soon as
the window closes. A used or expired key gets `410`. **Copy Pairing Link** copies the same link, for pasting.
