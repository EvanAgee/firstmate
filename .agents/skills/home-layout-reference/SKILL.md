---
name: home-layout-reference
description: >-
  Agent-only inventory of the Firstmate home layout that AGENTS.md section 2 summarizes.
  Use before reading, writing, or interpreting a specific tracked path, config key, data record, or state artifact in a Firstmate home.
user-invocable: false
metadata:
  internal: true
---

# home-layout-reference

This is the full layout inventory that `AGENTS.md` section 2 summarizes, moved word for word.
In the inventory, "this file" means `AGENTS.md`, and section numbers refer to `AGENTS.md`.
An entry marked "never touch" or "written only by" a script is owned by that script; never hand-edit it.

`docs/configuration.md` is the single owner of the top-level operational-home layout and configuration schemas; each producing script's header and help own exact child fields and mutation mechanics.

```
AGENTS.md            this file (CLAUDE.md is a real @AGENTS.md pointer to it)
CONTRIBUTING.md      contributor workflow and repo conventions
README.md            public overview and development notes
CONTEXT.md           project glossary (captain, crewmate, task, and related API words)
.github/workflows/   shared CI and PR enforcement, committed
.tasks.toml          tracked tasks-axi markdown backend config for the default backlog backend (section 10)
.agents/skills/      firstmate-loaded skills, committed; firstmate-owned ones carry metadata.internal=true, vendored ones stay verbatim (README "Two-tier skill layout")
.claude/skills       symlink to .agents/skills for claude compatibility
skills/              standalone public installer-facing skills, committed; not loaded by firstmate
skills-lock.json     lock file for vendored skills under .agents/skills/; do not edit those hashed files
bin/                 helper scripts, committed; read each script's header before first use
.env                 optional Relay pairing token; LOCAL, gitignored; presence-gates section 14
config/crew-harness  crewmate harness override; LOCAL, gitignored; absent or "default" = same as firstmate. Inherited as the literal file: a concrete primary adapter value also controls a secondmate home's own crewmates (section 4)
config/crew-dispatch.json  optional crewmate dispatch class pools; LOCAL, gitignored; firstmate-maintained but human-editable configuration resolved by `bin/fm-dispatch-resolve.sh` (section 4). Inherited by secondmate homes
config/secondmate-harness  harness the PRIMARY uses to launch SECONDMATE agents, optionally followed by a model and effort token on the same line ("<harness> [<model>] [<effort>]"; section 4); LOCAL, gitignored; absent or "default" harness falls back to config/crew-harness then firstmate's own. The primary's own setting; NOT inherited into secondmate homes (secondmates do not spawn secondmates)
config/backlog-backend  backlog backend override; LOCAL, gitignored; absent or "tasks-axi" = default tasks-axi backend, "manual" = force routine backlog updates to hand-editing; inherited by secondmate homes (section 10)
config/backend  runtime session-provider backend override for new tasks; LOCAL, gitignored; absent = falls through to runtime auto-detection (the runtime firstmate itself is executing inside), then tmux; tmux is the verified reference backend (docs/tmux-backend.md), while herdr, zellij, orca, and cmux are experimental spawn backends (docs/herdr-backend.md, docs/zellij-backend.md, docs/orca-backend.md, docs/cmux-backend.md) - herdr and cmux can also be selected by runtime auto-detection, zellij and orca never are (always explicit), and codex-app is not accepted; see docs/codex-app-backend.md; inherited by secondmate homes under the primary-authoritative contract in secondmate-provisioning
config/calm     Pi Calm presentation preference; LOCAL, gitignored, and not inherited; see docs/configuration.md "Pi Calm preference"
config/startup-memory-budget     primary-authoritative per-home startup-memory budget; LOCAL, gitignored, materialized as 7,500 estimated tokens by locked primary bootstrap and inherited into secondmate homes; see docs/configuration.md "Startup memory budget"
config/herdr-presentation-spaces  optional "off" opt-out from, or "on" opt-in to, Herdr's default-on disposable single-task visual projection, which is unconfigured-default-on only at or above a Herdr version floor; LOCAL, gitignored; inherited by secondmate homes; see docs/herdr-backend.md "Presentation spaces"
config/trace-context  optional presence flag enabling default-off native W3C trace-context propagation to spawned agents; LOCAL, gitignored; inherited by secondmate homes; see docs/configuration.md "Trace context propagation" and docs/trace-context.md
config/cmux-socket-password  optional cmux control-socket password; LOCAL, gitignored; read fresh on every cmux CLI call and passed through without ever overriding an operator's own ambient CMUX_SOCKET_PASSWORD when absent (docs/cmux-backend.md "Setup")
config/wedge-alarm  optional active-alert channel directives for the away-mode wedge alarm and the watcher-beat alert; LOCAL, gitignored; absent means auto (macOS Notification Center when available); see docs/wedge-alarm.md
config/session-odometer  optional session-age and handled-wake thresholds for heartbeat ANCHOR restart advice; LOCAL, gitignored; absent uses 21600s/200 wakes; see docs/configuration.md "Session odometer"
config/supervision.env  optional supervision knob file the watcher, the guard, and the watcher-beat alert all read, so every harness and scheduler resolves one value per home; LOCAL, gitignored; real env wins; see docs/configuration.md "Supervision knobs"
config/x-mode.env    generated Relay watcher cadence; LOCAL, gitignored; source before arming watcher when present
config/api-port  localhost API bind port; LOCAL, gitignored, not inherited; FM_API_PORT overrides; absent uses 18787; session start brings the API up on the primary home only; see docs/configuration.md "Local API"
config/api-token  localhost API write token; LOCAL, gitignored, not inherited; generated on first API start if absent; later starts keep it; writes require it as a bearer header; reads and the event stream do not; see docs/configuration.md "Local API"
data/                personal fleet records; LOCAL, gitignored as a whole
  backlog.md         task queue, dependencies, history
  captain-queue.json fleet-board captain cards; written only by bin/fm-captain-queue.sh
  captain.md         this home's domain-local captain preferences and working style; LOCAL, gitignored, canonical even if harness memory mirrors it, and updated with inspect-then-update
  captain-shared.md  main-authoritative shared captain preferences propagated read-only to secondmate homes; LOCAL, gitignored, owned by secondmate-provisioning
  learnings.md       fleet-local operational facts and gotchas; LOCAL, gitignored; dated, evidence-backed, curated, and updated with inspect-then-update - rewrite and prune rather than append forever, the same contract as captain.md; created lazily, absent until this home has a learning to store
  projects.md        thin fleet navigation registry recording each project's standing delivery posture; firstmate-private, parsed for mechanical sync and seeding by fm-project-mode.sh (section 6)
  secondmates.md      local and remote secondmate routing table; firstmate-private, maintained by the secondmate seed helpers (section 6)
  token-ledger/      token and cost snapshots written by bin/fm-token-ledger.sh; LOCAL, gitignored (docs/configuration.md "Token ledger")
  <id>/brief.md      per-task crewmate brief, or per-secondmate charter brief when kind=secondmate
  <id>/report.md     scout task deliverable, written by the crewmate; survives teardown
projects/            cloned repos; gitignored; read-only except under hard rule 1's concrete captain-approved project operation exception
state/               runtime records and signals; gitignored
  <id>.status        appended by crewmates: "<state>: <note>" wake-event lines, not current-state truth
  <id>.turn-ended    touched by turn-end hooks
  <id>.turn-continue  watcher-owned continuation count and signal signatures; removed by teardown
  <id>.grok-turnend-token   firstmate-owned grok hook registry token for the task; removed by teardown
  <id>.kimi-turnend-token   firstmate-owned Kimi hook registry token for the task; removed by teardown
  <id>.muse-session  muse busy-source binding (sessions root plus task worktree) written by fm-spawn; removed by teardown
  <id>.cursor-session  cursor busy-source binding (projects root, task worktree, prior conversations) written by fm-spawn; removed by teardown
  <id>.pane-tail    bounded live worker-pane snapshot written by fm-watch for the task-detail API; removed by spawn and teardown
  <id>.omp-ext.ts <id>.omp-ready <id>.omp-started   firstmate-generated OMP task extension plus its session-start and first-turn acknowledgement markers; removed by teardown
  <id>.meta          task metadata; each producer script's header owns its exact fields and mutation contract, with docs/configuration.md routing operator-facing backend and trace-context details
  <id>.herdr-presentation  quarantinable attempt and restart-binding journal for Herdr's optional visual projection; never task or endpoint authority; see docs/herdr-backend.md "Presentation spaces"
  <id>.check.sh      authenticated slow poll; the watcher dispatches validated PR data and the byte-identified Relay shim through trusted repository scripts, runs registered custom checks from hash-validated private snapshots, and rejects every other state check without execution
  <id>.check-trust   private content binding created by fm-check-register.sh for an intentional custom check
  <id>.pr-poll       private validated data sidecar for the byte-static PR merge poll
  <id>.pr-poll-registration  private transactional provenance record binding the task, canonical metadata identity, sidecar, and static poll publication
  <id>.pr-poll-retirement  private identity-bound crash-recovery receipt for one exact validated merged result; removed after its poll artifacts retire
  <id>.pr-review-chase  private per-head reviewer retry and escalation state; owned by bin/fm-pr-review-chase.sh
  .pr-check-quarantine/  private non-runnable storage for checks neutralized by the non-executing migration
  .pr-check-migration.log  private per-task outcomes distinguishing rebuilt or canonically registered replacement polls, quarantined unarmed polls, and incomplete migrations
  .pr-check-migration-scan-v1  private marker proving the non-executing scan disabled every unsafe legacy check; .pr-check-migration-v1 separately records completed private repairs
  x-watch.check.sh   generated Relay poll shim; present only when opted in (section 14)
  captain-replies.jsonl captain-replies.cursor .captain-queue.lock  dashboard answers to fleet-board cards, reconcile cursor, and add/park/reconcile lock; bin/fm-captain-queue.sh
  pending-replies/   parent-owned secondmate pending-reply records (correlation id, delivery vs reply, recovery, escalation); fm-pending-reply-lib.sh
  procevent/         registered process-to-event sources, one private record per canonical source id; written only by bin/fm-procevent.sh, and their presence alone keeps supervision required (section 13)
  procevent-inbox/   private captured results and their durable handled-acknowledgement markers; source output lives here and never in an event line
  decision-bindings/ private bindings from a captured-answer source id to the captain-hold origin its keyed answers close; written only by bin/fm-decision-hold.sh bind, dropped by unbind and by source retirement (section 13; docs/decision-hold-lifecycle.md)
  outage-landings/   per-project reconciliation ledgers recording each local landing done while GitHub was unreachable; written by bin/fm-merge-local.sh, one entry cleared per landing by bin/fm-outage-sync.sh on return (section 13's outage-local-landing)
  when/              private condition->action watch specs, their trust bindings, and single-fire markers; written only by bin/fm-procevent-when.sh (section 13's process-event-sources trigger)
  x-inbox/           generated Relay pending mention payloads; fmx-respond drains it (section 14)
  x-context/         generated Relay durable per-request reply context and one-wake offer markers, keyed by request_id; survives inbox cleanup and expires within seven days (section 14; bin/fm-x-lib.sh)
  x-outbox/          generated Relay dry-run reply and dismiss previews; inspect it when FMX_DRY_RUN is set (section 14)
  public-followup/   generated private transport for promised public replies: commitment registrations, typed terminal-result inbox, accepted/rejected ledgers (section 14; bin/fm-public-followup.sh)
  x-poll.error x-poll.claim-error  generated Relay and offer-claim diagnostic dedupe markers
  .startup-network.*  status, report, per-step elapsed timings, inline-print claim, and lock for the deferred network stage session start runs off its blocking path; bin/fm-startup-network.sh
  .github-down       durable GitHub-unreachable flag holding a first-seen timestamp; set by bin/fm-github-health.sh on confirmed unreachability and cleared on recovery, its presence alone permits an outage local landing (section 13's outage-local-landing)
  .wake-queue        durable queued wakes retained until post-handling acknowledgement: epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload
  .watcher-down      private generation-bound recovery state coupling watcher downtime, durable wake presentation, and post-handling acknowledgement; never touch
  .omp-primary-extension-loaded  this home's OMP primary adapter identity marker; published by the adapter, validated by fm-session-start.sh, never hand-edited (docs/configuration.md "Harness support")
  .<id>.open-decisions-cursor  per-task byte cursor and folded open-decision set bounding the OPEN DECISIONS scan's cost to new status-log appends; written only by fm-classify-lib.sh's status_open_decisions_incremental, removed by teardown, safe to delete (forces one full re-fold)
  .status-presentation-cursor .status-presentation-lock  fleet-wide per-task status identity/byte-offset manifest and serialization lock preventing already-presented status lines from being replayed as new; owned by fm-classify-lib.sh, with each task's row retired by teardown
  .afk               durable away-mode flag; present = sub-supervisor may inject escalations (set by /afk, cleared on user return)
  .watch.lock .wake-queue.lock watcher singleton and queue serialization locks
  .claude-autoarm.lock .claude-autoarm-epoch .claude-autoarm-failure-notified .claude-autoarm-failure-alarmed .claude-coordinator.lock .claude-coordinator-generation .claude-ready-to-notify .claude-notifier-surfaced-seq .turnend-claude-blocks .turnend-claude-blocks.lock   Claude Stop notifier/coordinator single-flight, epoch, failure-episode, ready-to-notify, attended-alarm, guard-budget, and budget-lock records; never touch
  .cursor-park-owner .cursor-park-owner.lock .turnend-cursor-blocks   Cursor stop-hook owner record, publication and commit lock, and bounded repair-nag budget; never touch
  .hash-* .count-* .stale-* .stale-since-* .paused-* .wedge-escalations-* .seen-* .hb-surfaced-* .last-* .heartbeat-streak   watcher internals; never touch
  .watch-triage.log  watcher's absorbed-wake debug log (size-capped); never relied on, safe to delete
  .last-watcher-beat watcher liveness beacon, touched every poll (including while absorbing benign wakes); guard scripts read it
  .session-odometer   private per-session age and handled-wake counters for a long-lived session's restart advice; written only by bin/fm-anchor-lib.sh via bin/fm-wake-drain.sh, reset whenever the session-lock holder changes
  .last-anchor       mtime of the last printed heartbeat ANCHOR; attended no-change heartbeats present when this is missing or older than FM_ANCHOR_INTERVAL (default HEARTBEAT_MAX); touched only by bin/fm-anchor-lib.sh via the drain
  .beat-alarm-fired .beat-alarm.log .beat-alarm.launchd.log   session-independent watcher-beat alert episode marker and its logs; written only by bin/fm-watcher-beat-alarm.sh
  .subsuper-* .supervise-daemon.*   sub-supervisor internals; never touch
  .api.pid .api.pid-identity .api.port .api.session-pid .api.log .api.lock  localhost API process records; bin/fm-api.sh
.no-mistakes/        local validation state and evidence; gitignored
```

A `state/<id>.status` line is a wake event, not current-state truth; `bin/fm-crew-state.sh` owns current-state reconciliation.
