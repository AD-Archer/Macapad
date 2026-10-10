// Macapad tester: serves the docs page (Resources/docs.html, the same one Macapad serves
// when "Docs Page" is on) and finds Macs, because browsers can't do Bonjour or read your tailnet. Everything else (pairing, pressing keys) happens in
// the browser, talking straight to the Mac, like a real frontend would.
//
//   pnpm install && pnpm start      then open http://<this-computer>:7318 on your phone

import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import bonjourService from "bonjour-service";

const PORT = Number(process.env.PORT ?? 7318);
const MACAPAD_PORT = 7317;

const bonjour = new bonjourService.Bonjour();
const lanServices = new Map(); // fqdn -> service
const browser = bonjour
  .find({ type: "macapad" }, (s) => lanServices.set(s.fqdn, s))
  .on("down", (s) => lanServices.delete(s.fqdn));

/** GET <url>/api/health with a short timeout; null if it isn't a Macapad. */
async function health(url) {
  try {
    const res = await fetch(`${url}/api/health`, { signal: AbortSignal.timeout(1200) });
    const body = await res.json();
    if (body?.name !== "macapad") return null;
    return { status: res.status, ...body };
  } catch {
    return null;
  }
}

async function lanCandidates() {
  // Ask again and give Macs a moment to answer, in case one just woke up.
  browser.update();
  await new Promise((r) => setTimeout(r, 800));
  return [...lanServices.values()].flatMap((s) => {
    const ipv4 = (s.addresses ?? []).find((a) => a.includes("."));
    return ipv4 ? [{ via: "lan", url: `http://${ipv4}:${s.port}`, label: s.name }] : [];
  });
}

function tailscaleBinary() {
  return [
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    "/opt/homebrew/bin/tailscale",
    "/usr/local/bin/tailscale",
    "/usr/bin/tailscale",
  ].find(existsSync);
}

/** Every online device on the tailnet (including this one); Macapad is probed on each. */
function tailscaleCandidates() {
  const bin = tailscaleBinary();
  if (!bin) return Promise.resolve([]);
  return new Promise((resolve) => {
    execFile(bin, ["status", "--json"], { timeout: 3000 }, (err, stdout) => {
      if (err) return resolve([]);
      try {
        const status = JSON.parse(stdout);
        const nodes = [status.Self, ...Object.values(status.Peer ?? {})].filter((n) => n && (n.Online || n === status.Self));
        resolve(
          nodes.flatMap((n) => {
            const ip = (n.TailscaleIPs ?? []).find((a) => a.includes("."));
            return ip ? [{ via: "tailscale", url: `http://${ip}:${MACAPAD_PORT}`, label: n.HostName }] : [];
          }),
        );
      } catch {
        resolve([]);
      }
    });
  });
}

/** Finds Macs on both networks and merges entries for the same Mac by its id. */
async function discover() {
  const [lan, tailnet] = await Promise.all([lanCandidates(), tailscaleCandidates()]);
  const candidates = [...lan, ...tailnet];
  const probed = await Promise.all(candidates.map(async (c) => ({ ...c, health: await health(c.url) })));
  const macs = new Map();
  for (const c of probed) {
    if (!c.health?.mac) continue; // not a Macapad, or not discoverable from here
    const mac = macs.get(c.health.mac.id) ?? { id: c.health.mac.id, name: c.health.mac.name, version: c.health.version, routes: [] };
    mac.routes.push({ via: c.via, url: c.url });
    macs.set(mac.id, mac);
  }
  return [...macs.values()];
}

const page = new URL("../Resources/docs.html", import.meta.url);

createServer(async (req, res) => {
  if (req.url === "/discover") {
    const macs = await discover();
    res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
    return res.end(JSON.stringify({ macs }));
  }
  if (req.url === "/" || req.url === "/index.html") {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
    return res.end(await readFile(page));
  }
  res.writeHead(404).end("Not found");
}).listen(PORT, "0.0.0.0", () => {
  console.log(`Macapad tester on http://localhost:${PORT} (open it from your phone using this computer's address)`);
});
