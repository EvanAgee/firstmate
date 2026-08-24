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

```bash
# 1. Build the current main in the primary checkout.
cd ~/Sites/firstmate/projects/agee-dev-dashboard   # or projects/usage-tracker
git checkout main            # the checkout must be on main, not detached
npm run build

# 2. Restart the supervised service in place.
launchctl kickstart -k gui/$(id -u)/dev.agee.dashboard-app   # or dev.agee.usage-tracker
```

`launchctl kickstart -k` restarts the app without touching the Cloudflare tunnel, so the public host stays mapped through the few seconds of reboot.
Serving a production build is what makes the restart pick up the current `main` reliably; `next dev` can keep serving a stale in-memory build after the code under it changes.

To confirm `/fleet` is served on `agee.dev` after a restart:

```bash
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/fleet   # 200 confirms /fleet is served
```

A 200 confirms `/fleet` is served.
To confirm a specific code change is live, open the page in a browser.

## When a dashboard is unreachable

The tunnel is a separate failure point from the local app, so check both.
Curl the local port first: `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/` (use the host's own port).

If the local port does not answer, the app is down: rebuild and restart its server agent with the restart recipe above.

If the local port answers but the public host is unreachable, the tunnel is down: restart the tunnel agent with its label from the host map.

```bash
launchctl kickstart -k gui/$(id -u)/dev.agee.cloudflared-root   # or -subs, -aos-ci, -aos-review
```

This happened on 2026-08-24: the root tunnel (`dev.agee.cloudflared-root`) had crashed while the local `:3200` app was healthy and returning 200, so `agee.dev` was unreachable even though nothing was wrong with the app.
Restarting the tunnel agent, not the app, is the fix for that case.

## Retired hosts

`firstmate.agee.dev` (port 7860) was a standalone fleet dashboard that never landed on `main`.
It was retired on 2026-08-24: its launchd agent and its process were removed, because the fleet view already lives at `agee.dev/fleet`.
That server also answered `/api/snapshot`, which `agee.dev/fleet` fetched for its data, so retiring it moved the snapshot in-process into the dashboard app (`lib/fleet/snapshot.server.ts`) rather than dropping it.
Its tunnel (`dev.agee.cloudflared-firstmate`, config `~/.cloudflared/firstmate-config.yml`) was stopped on 2026-08-24 and its launchd plist disabled (renamed to `.disabled`), so the host no longer resolves.
To bring `firstmate.agee.dev` back, land the fleet-dashboard server on `main`, restore the plist, and start the tunnel again.

## Maintaining this file

Keep this file to current serving facts and the restart recipe.
Update the host map and the retired list when a host, port, label, tunnel config, or checkout changes.
Prefer a pointer to the authoritative plist or tunnel config over copying detail that will drift.
