# The docs page

`Resources/docs.html` is the API docs as a web page that also works as a frontend: pair from it (by code, by scanning
the QR code, or by pasting a pairing link), and every example has a **Try** button that runs on your Mac.

- **From the Mac:** turn on **Settings → Docs page → Serve the docs page**. Macapad then serves it at `/`, e.g.
  `http://<lan-ip>:7317/` (**Open Docs Page** in the menu bar opens it). Off by default. It only knows about the Mac that served it.
- **From the tester:** `tester/` serves the same page plus `/discover`, which finds Macs over Bonjour and your
  tailnet (browsers can't do either). Run it on the Mac and open it from your phone:

  ```sh
  just tester   # then open http://<this-computer>:7318 on your phone
  ```

  Opened on the Mac itself, every request counts as "this Mac", which is always allowed.

- **Public copy:** `.github/workflows/docs.yml` publishes the same page to GitHub Pages on every push to `main` that
  touches it (one-time setup: repo Settings → Pages → Source: **GitHub Actions**). Browsers block HTTPS pages from
  calling `http://` addresses, so that copy reads as plain docs and tells people to open the live one from their Mac.
  Only a Mac's `tailscale serve` HTTPS address works from it. The page holds no addresses of its own; the IPs in it
  are examples.

Scanning a QR code needs the camera, which browsers only allow on HTTPS or localhost (e.g. through `tailscale serve`).
On plain `http://`, paste the link from **Copy Pairing Link** instead. Under `swift run` the page is read from the
source tree on every request, so edits show up on reload.
