# agee.dev dashboards

This is the single reference for how the captain's personal `*.agee.dev` dashboards are served on this machine.
Each public host is a Cloudflare tunnel that maps to a local port, and a launchd agent keeps the local app running.

## Standing rule

A dashboard runs on `main` in ONE checkout, never in a disposable treehouse worktree.
The one checkout is the primary clone under `~/Sites/firstmate/projects/<name>`.
A treehouse worktree is scratch space for a single task and gets pruned, so serving from one means the site dies when that task ends.
The captain set this serving rule on 2026-08-19.

## Host map

Each host has two independent pieces: the local app (a launchd agent serving a port) and the Cloudflare tunnel (a separate launchd agent that maps the public host to that port).
Either can fail on its own, so both labels are listed.

| Public host | Local port | Server launchd label | Tunnel launchd label | Tunnel config | Checkout | Command |
|---|---|---|---|---|---|---|
| agee.dev | 3200 | `dev.agee.dashboard-app` | `dev.agee.cloudflared-root` | `~/.cloudflared/agee-root-config.yml` | `~/Sites/firstmate/projects/agee-dev-dashboard` (on `main`) | `npm run start` (prod build) |
| subs.agee.dev | 3000 | `dev.agee.usage-tracker` | `dev.agee.cloudflared-subs` | `~/.cloudflared/subs-config.yml` | `~/Sites/firstmate/projects/usage-tracker` (on `main`) | `npm run start` (prod build) |
| ci.agee.dev | 4200 | separate aos CI backend | `dev.agee.cloudflared-aos-ci` | `~/.cloudflared/aos-ci-config.yml` | separate aos CI backend | out of scope here |
| aos.agee.dev | 4112 | separate aos review service | `dev.agee.cloudflared-aos-review` | `~/.cloudflared/aos-review-config.yml` | separate aos review service | out of scope here |

`agee.dev` is one Next.js app that serves `/`, `/fleet`, and `/subs`.
`subs.agee.dev` is a different app (the usage tracker), not the `agee.dev/subs` page.
`agee.dev/fleet` gets its data in-process: the app runs `bin/fm-fleet-snapshot.sh --json` itself (see `lib/fleet/snapshot.server.ts` in the dashboard repo) and caches the result, so there is no separate snapshot server to run or crash.

## Restart recipe

Both `agee.dev` and `subs.agee.dev` serve a production build, so a restart must rebuild first, then restart the launchd agent.
Each app has its own checkout and its own launchd label, so use the block for the app you are restarting.

For `agee.dev`:

```bash
cd ~/Sites/firstmate/projects/agee-dev-dashboard &&
  git checkout main &&           # the checkout must be on main, not detached
  npm run build &&
  launchctl kickstart -k gui/$(id -u)/dev.agee.dashboard-app
```

For `subs.agee.dev`:

```bash
cd ~/Sites/firstmate/projects/usage-tracker &&
  git checkout main &&
  npm run build &&
  launchctl kickstart -k gui/$(id -u)/dev.agee.usage-tracker
```

The commands are chained with `&&` so a failed checkout or build stops the sequence and never restarts a stale build.

`launchctl kickstart -k` restarts the app without touching the Cloudflare tunnel, so the public host stays mapped through the few seconds of reboot.
Serving a production build is what makes the restart pick up the current `main` reliably; `next dev` can keep serving a stale in-memory build after the code under it changes.

To confirm the local app is serving after a restart (a local health check, not a public-reachability check), curl the port for the app you just restarted:

```bash
# agee.dev
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/fleet

# subs.agee.dev
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/
```

The port must match the app just restarted. That local curl is the definitive up/down check: a 200 means that specific app is up.
The public curl only tells you whether tunnel routing works. Both hosts sit behind Cloudflare Access, so an unauthenticated curl often returns 302 to the Access login even when everything is healthy. Treat 200 or 302-to-Access as reachable; a 302 is the Access gate, not a down tunnel. Tunnel-down is a refused connection or Cloudflare 502/530 (no origin), not any non-200.

```bash
# agee.dev
curl -s -o /dev/null -w '%{http_code}' https://agee.dev/fleet

# subs.agee.dev
curl -s -o /dev/null -w '%{http_code}' https://subs.agee.dev/
```

If the local check is 200 and the public check is refused / 502 / 530, the tunnel is down (see "When a dashboard is unreachable").
To confirm a specific code change is live, open the page in a browser.

## When a dashboard is unreachable

The tunnel is a separate failure point from the local app, so check both.
Probe the local port of the host you are diagnosing:

```bash
# agee.dev
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/fleet

# subs.agee.dev
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/
```

A 200 on that port confirms that specific local app is up.

If the local port does not answer, the app is down: rebuild and restart its server agent with the restart recipe above.

If the local port answers, the app is up. The public curl only distinguishes tunnel routing from a down tunnel. Both hosts sit behind Cloudflare Access, so an unauthenticated curl often returns 302 to the Access login even when the tunnel and app are healthy. 200 or 302-to-Access means the host is reachable; a 302 is the Access gate, not tunnel-down. Tunnel-down is a refused connection or Cloudflare 502/530 (no origin).

```bash
# agee.dev
curl -s -o /dev/null -w '%{http_code}' https://agee.dev/fleet

# subs.agee.dev
curl -s -o /dev/null -w '%{http_code}' https://subs.agee.dev/
```

If the local port answers but the public check is refused / 502 / 530, the tunnel is down: restart the tunnel agent whose label matches the affected host from the host map. The label is `dev.agee.cloudflared-<name>`, where `<name>` is `root`, `subs`, `aos-ci`, or `aos-review`.

```bash
launchctl kickstart -k gui/$(id -u)/dev.agee.cloudflared-<name>
```

This happened on 2026-08-24: the root tunnel (`dev.agee.cloudflared-root`) had crashed while the local `:3200` app was healthy and returning 200, so `agee.dev` was unreachable even though nothing was wrong with the app.
Restarting the tunnel agent, not the app, is the fix for that case.

## Retired hosts

`firstmate.agee.dev` (port 7860) was a standalone fleet dashboard that never landed on `main`.
It was retired on 2026-08-24: its launchd agent and its process were removed, because the fleet view already lives at `agee.dev/fleet`.
That server also answered `/api/snapshot`, which `agee.dev/fleet` fetched for its data, so retiring it moved the snapshot in-process into the dashboard app (`lib/fleet/snapshot.server.ts`) rather than dropping it.
Its tunnel (`dev.agee.cloudflared-firstmate`, config `~/.cloudflared/firstmate-config.yml`) was stopped on 2026-08-24 and its launchd plist disabled (renamed to `.disabled`), so nothing serves `firstmate.agee.dev`. Its DNS may still resolve to Cloudflare, which now returns an error / non-200 because no tunnel backs the host.

To bring `firstmate.agee.dev` back, both launchd agents have to return, or the tunnel would run with no server behind port 7860:

- Server: land the fleet-dashboard server (`bin/fm-fleet-dashboard.js`, which currently lives only on an unmerged branch) on `main`, then recreate and load its `dev.agee.firstmate-dashboard` launchd agent (that plist was deleted, not disabled).
- Tunnel: rename `dev.agee.cloudflared-firstmate.plist.disabled` back to `.plist` and load it (`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.agee.cloudflared-firstmate.plist`).

## Maintaining this file

Keep this file to current serving facts and the restart recipe.
Update the host map and the retired list when a host, port, label, tunnel config, or checkout changes.
Prefer a pointer to the authoritative plist or tunnel config over copying detail that will drift.
