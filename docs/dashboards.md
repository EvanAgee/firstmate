# agee.dev dashboards

This is the single reference for how the captain's personal `*.agee.dev` dashboards are served on this machine.
Each public host is a Cloudflare tunnel that maps to a local port, and a launchd agent keeps the local app running.

## Standing rule

A dashboard runs on `main` in ONE checkout, never in a disposable treehouse worktree.
The one checkout is the primary clone under `~/Sites/firstmate/projects/<name>`.
A treehouse worktree is scratch space for a single task and gets pruned, so serving from one means the site dies when that task ends.
The captain set this serving rule on 2026-08-19.

## Host map

| Public host | Local port | launchd label | Tunnel config | Checkout | Command |
|---|---|---|---|---|---|
| agee.dev | 3200 | `dev.agee.dashboard-app` | `~/.cloudflared/agee-root-config.yml` | `~/Sites/firstmate/projects/agee-dev-dashboard` (on `main`) | `npm run start` (prod build) |
| subs.agee.dev | 3000 | `dev.agee.usage-tracker` | `~/.cloudflared/subs-config.yml` | `~/Sites/firstmate/projects/usage-tracker` (on `main`) | `npm run start` (prod build) |
| ci.agee.dev | 4200 | `dev.agee.cloudflared-aos-ci` | `~/.cloudflared/aos-ci-config.yml` | separate aos CI backend | out of scope here |
| aos.agee.dev | 4112 | `dev.agee.cloudflared-aos-review` | `~/.cloudflared/aos-review-config.yml` | separate aos review service | out of scope here |

`agee.dev` is one Next.js app that serves `/`, `/fleet`, and `/subs`.
`subs.agee.dev` is a different app (the usage tracker), not the `agee.dev/subs` page.

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

## Retired hosts

`firstmate.agee.dev` (port 7860) was a standalone fleet dashboard that never landed on `main`.
It was retired on 2026-08-24: its launchd agent and its zombie process were removed, because the fleet view already lives at `agee.dev/fleet`.
Its tunnel (`dev.agee.cloudflared-firstmate`, config `~/.cloudflared/firstmate-config.yml`) points at the now-dead port and can be stopped once the captain confirms the host is not wanted back.

## Maintaining this file

Keep this file to current serving facts and the restart recipe.
Update the host map and the retired list when a host, port, label, tunnel config, or checkout changes.
Prefer a pointer to the authoritative plist or tunnel config over copying detail that will drift.
