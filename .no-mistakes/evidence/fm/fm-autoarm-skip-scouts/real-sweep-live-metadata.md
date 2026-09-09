# Real sweep: bin/fm-pr-autoarm.sh against live task metadata

All 14 real `.meta` files were copied from `/Users/evanagee/Sites/firstmate/state/`
into an isolated scratch state dir. Every wake-queue write, cursor write, and arm
call landed in scratch. Live state was verified untouched afterwards.
`fm-pr-check.sh` was replaced by a recording stub, so no real PR watch was armed.
The GitHub lookups were real (`gh`, authenticated from its own keyring; the
1Password CLI was never invoked).

## Live lane shape

| task | kind | pr= | branch | upstream |
|---|---|---|---|---|
| aos-2223-full-safety-track | ship | no | (detached) | none |
| aos-3430-writer-capture | scout | no | (detached) | none |
| aos-3527-sandbox-symlink-bounce | ship | no | fm/aos-3527-sandbox-symlink-bounce | none |
| aos-3601-desktop-home-scout | scout | no | (detached) | none |
| aos-3628-chat-knows-it-is-aos | ship | yes | manual-aos-3628-... | none |
| aos-3629-no-workspace-tools-hosted | ship | yes | manual-aos-3629-... | origin/... |
| aos-changelog-durable-publishing | ship | yes | work-3622-... | origin/... |
| aos-no-1password-local-dev | ship | no | manual-aos-no-1password-local-dev | none |
| aos-triage-standing | scout | no | (detached) | none |
| fm-autoarm-skip-scouts | ship | no | fm/fm-autoarm-skip-scouts | none |
| fm-brief-no-1password | ship | no | fm/fm-brief-no-1password | none |
| fm-relaunch-after-restart | ship | no | fm/fm-relaunch-after-restart | none |
| platform-61-invite-only-staff-pools | ship | yes | fm/platform-61-... | none |
| sdi-715-qbo-live-foundation | ship | no | fm/sdi-715-qbo-live-foundation | none |

## BEFORE the fix (base 87890f7) — 10 wake events queued, 0 PRs found

Sweep stdout:

    pr-autoarm: task=aos-2223-full-safety-track has no resolvable branch
    pr-autoarm: task=aos-3430-writer-capture has no resolvable branch
    pr-autoarm: task=aos-3527-sandbox-symlink-bounce branch fm/aos-3527-sandbox-symlink-bounce has no upstream
    pr-autoarm: task=aos-3601-desktop-home-scout has no resolvable branch
    pr-autoarm: task=aos-no-1password-local-dev branch manual-aos-no-1password-local-dev has no upstream
    pr-autoarm: task=aos-triage-standing has no resolvable branch
    pr-autoarm: task=fm-autoarm-skip-scouts branch fm/fm-autoarm-skip-scouts has no upstream
    pr-autoarm: task=fm-brief-no-1password branch fm/fm-brief-no-1password has no upstream
    pr-autoarm: task=fm-relaunch-after-restart branch fm/fm-relaunch-after-restart has no upstream
    pr-autoarm: task=sdi-715-qbo-live-foundation branch fm/sdi-715-qbo-live-foundation has no upstream

Durable wake queue written (`state/.wake-queue`), 10 rows:

    1788975737	1	check	pr-autoarm:aos-2223-full-safety-track	check: pr-autoarm: task=aos-2223-full-safety-track has no resolvable branch
    1788975738	2	check	pr-autoarm:aos-3430-writer-capture	check: pr-autoarm: task=aos-3430-writer-capture has no resolvable branch
    1788975739	3	check	pr-autoarm:aos-3527-sandbox-symlink-bounce	check: pr-autoarm: task=aos-3527-sandbox-symlink-bounce branch fm/aos-3527-sandbox-symlink-bounce has no upstream
    1788975739	4	check	pr-autoarm:aos-3601-desktop-home-scout	check: pr-autoarm: task=aos-3601-desktop-home-scout has no resolvable branch
    1788975741	5	check	pr-autoarm:aos-no-1password-local-dev	check: pr-autoarm: task=aos-no-1password-local-dev branch manual-aos-no-1password-local-dev has no upstream
    1788975741	6	check	pr-autoarm:aos-triage-standing	check: pr-autoarm: task=aos-triage-standing has no resolvable branch
    1788975742	7	check	pr-autoarm:fm-autoarm-skip-scouts	check: pr-autoarm: task=fm-autoarm-skip-scouts branch fm/fm-autoarm-skip-scouts has no upstream
    1788975743	8	check	pr-autoarm:fm-brief-no-1password	check: pr-autoarm: task=fm-brief-no-1password branch fm/fm-brief-no-1password has no upstream
    1788975744	9	check	pr-autoarm:fm-relaunch-after-restart	check: pr-autoarm: task=fm-relaunch-after-restart branch fm/fm-relaunch-after-restart has no upstream
    1788975745	10	check	pr-autoarm:sdi-715-qbo-live-foundation	check: pr-autoarm: task=sdi-715-qbo-live-foundation branch fm/sdi-715-qbo-live-foundation has no upstream

Arm log: `<none>` — no PR was found for any lane.

## AFTER the fix (target f4a833a) — 0 wake events, 1 real PR armed

Sweep stdout: completely silent (no output at all).

Wake queue: `state/.wake-queue` was never created. Zero wakes queued.

Arm log:

    WOULD-ARM task=fm-brief-no-1password url=https://github.com/EvanAgee/firstmate/pull/108

That PR is real and open, and its head branch matches the local branch exactly:

    $ gh api repos/EvanAgee/firstmate/pulls/108 --jq '...'
    PR #108 | state=open | head=fm/fm-brief-no-1password | title=feat(bin): forbid the 1Password CLI in every generated worker brief

## Isolation check

Live metadata unchanged after both sweeps:

    $ git -C /Users/evanagee/Sites/firstmate status --porcelain state/
    (no output)
