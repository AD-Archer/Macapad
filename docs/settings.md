# Settings

The menu bar icon has **Pair with QR Code…**, **Copy API URL**, **Copy API Token**, **Open Docs Page** (while the docs page is on) and **Settings…** items, plus **Update to Macapad …** when a newer release is out.

**Settings…** in the menu bar (⌘,) controls who can reach the Mac. They're saved in `~/.macapad/settings.json`.

| Setting | Default | What it does |
|---|---|---|
| Name | the Mac's name | What devices see when they find this Mac |
| Local network → Allow connections | on | Accept requests from devices on your Wi-Fi/Ethernet |
| Local network → Let devices find this Mac | on | Advertise over Bonjour and accept pairing requests from the LAN |
| Tailscale → Allow connections | on | Accept requests from your tailnet (directly or through `tailscale serve`) |
| Tailscale → Let devices find this Mac | on | Show the Mac's name in `/api/health` and accept pairing requests from the tailnet |
| Internet → Allow connections | off | Accept requests from any other address (port forwarding, Tailscale Funnel). Pairing is never allowed from here |
| Pause → Pause all devices | off | Nothing runs, from any device or the owner token: for an hour, until tomorrow morning, until a time you pick, or until you turn it back on. Also in the menu bar |
| Paired devices | | Every device you've allowed, with the [named clients](api.md#naming-your-client) using its token underneath. Next to each: when it works (**Always**, **Same as device**, or a schedule), and **⋯** to pause it or remove it |
| API key clients | | Every [named client](api.md#naming-your-client) calling with the owner token, e.g. each archersdesk screen, with where it last called from (network, and the computer's Tailscale name or its address). Same controls; **Forget** clears one until it calls again |
| Updates → Check for updates | on | Asks GitHub every 6 hours (and at launch) whether there's a newer release. Nothing about your Mac is sent |
| Updates → Install updates by itself | off | Installs a newer release as soon as it's found instead of waiting for **Update to Macapad …** in the menu bar. Only for the one-command install. See [Updating](install.md#updating) |
| Docs page → Serve the docs page | off | Serves the [docs page](docs-page.md) at `/`. **Open Docs Page** in the menu bar opens it |
| Schedules | Work hours (weekdays 9–5) | Named hours a device can be set to work in, e.g. an office macro pad that's only on during work. Can run past midnight. Deleting one sets its devices back to **Always** |

Programs on the Mac itself (localhost) are always allowed. A request from a network that's turned off gets `403`.

Pausing and schedules stop `/api/run` and WebSocket `run`, not the rest of the API, so a paused frontend can still show its buttons.
Schedules use the Mac's time zone.
