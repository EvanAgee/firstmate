# Rule-by-rule check of bin/fm-pr-autoarm.sh sweep-one

Each row is one run of the real `sweep-one` entry point against a purpose-built
worktree, with a fake `gh` on PATH and a recording arm stub. "wake" is the
reason line the sweep emits; `<SILENT>` means it emitted nothing.

| scenario | wake emitted | forge hit | armed |
|---|---|---|---|
| kind=scout, 1 open PR | `<SILENT>` | no | none |
| kind=secondmate, 1 open PR | `<SILENT>` | no | none |
| detached HEAD | `<SILENT>` | no | none |
| no upstream, 0 open PRs | `<SILENT>` | yes | none |
| no upstream, 1 open PR | `<SILENT>` | yes | `different-task https://github.com/acme/widget/pull/41` |
| no upstream, 2 open PRs | `task=different-task has more than one open PR for branch actual-feature` | yes | none |
| no upstream, forge exits 1 | `<SILENT>` | yes | none |
| no upstream, malformed forge output | `<SILENT>` | yes | none |
| no upstream and no origin remote | `<SILENT>` | no | none |
| with upstream, 1 open PR | `<SILENT>` | yes | `different-task https://github.com/acme/widget/pull/41` |
| missing worktree | `task=different-task worktree is missing or unreadable` | no | none |
| existing `pr=` in metadata | `<SILENT>` | no | none (metadata untouched) |

Forge query for the no-upstream case confirms it looks up the exact local branch
name against origin:

    api --method GET repos/acme/widget/pulls -f state=open -f head=acme:actual-feature -f per_page=2 ...

## Same case, before vs after the fix

    === AFTER fix (target f4a833a) ===
    stdout: <silent>
    forge: api ... -f head=acme:actual-feature ...
    arm:   different-task https://github.com/acme/widget/pull/41

    === BEFORE fix (base 87890f7) ===
    stdout: task=different-task branch actual-feature has no upstream
    forge: <never contacted>
    arm:   <none>
