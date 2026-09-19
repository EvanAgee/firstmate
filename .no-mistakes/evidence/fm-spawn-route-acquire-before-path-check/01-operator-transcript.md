# Live bug reproduction: a typo disabled a healthy provider forever

Scenario is the observed 2026-09-16 failure: a spawn given a bare project
name ('aos') instead of a path. The spawn can never reach a harness process.
Same scenario, same fixtures, run against both code versions.

## BEFORE the fix (base commit 2b36faaf)
```
FIRSTMATE ROUTE STORE, BEFORE ANYTHING RUNS
  Both providers are healthy and pickable.
    route codex: state=eligible  reason=ok
    route pi-grok: state=eligible  reason=ok
    (no assignment records)
------------------------------------------------------------

STEP 1. Operator makes a typo: bare project name instead of a path.
  $ fm-spawn.sh demo-aos-barename-t61441-22185 aos --class builder --mode no-mistakes

  | dispatch: class=builder harness=codex model=gpt-5 effort=high reason=pin
  | /tmp/fmbase/bin/fm-spawn.sh: line 2417: cd: aos-not-a-real-path-t61441-22185: No such file or directory
  exit status: 1 (spawn refused, as it should be)

  ROUTE STORE AFTER THE REFUSED SPAWN:
    route codex: state=launch-failed  reason=finish recorded launch-failed
    route pi-grok: state=eligible  reason=ok
    task demo-aos-barename-t61441-22185: status=closed route=codex outcome=launch-failed
  >> VERDICT: BUG - the healthy codex provider was DISABLED by a typo.
  >> VERDICT: BUG - a closed record is stuck on this task id.
------------------------------------------------------------

STEP 2. Operator fixes the typo and retries the SAME task id.
  $ fm-spawn.sh demo-aos-barename-t61441-22185 <correct/path> --class builder --mode no-mistakes

  | error: assignment 'demo-aos-barename-t61441-22185' is already closed; a new attempt needs a new assignment id, not a spent record
  exit status: 1

  ROUTE STORE AFTER THE RETRY:
    route codex: state=launch-failed  reason=finish recorded launch-failed
    route pi-grok: state=eligible  reason=ok
    task demo-aos-barename-t61441-22185: status=closed route=codex outcome=launch-failed
  >> VERDICT: BUG - the retry was refused. The task is stuck until someone hand-edits state/route.json.
------------------------------------------------------------
```

## AFTER the fix (target commit 51ec7b0b)
```
FIRSTMATE ROUTE STORE, BEFORE ANYTHING RUNS
  Both providers are healthy and pickable.
    route codex: state=eligible  reason=ok
    route pi-grok: state=eligible  reason=ok
    (no assignment records)
------------------------------------------------------------

STEP 1. Operator makes a typo: bare project name instead of a path.
  $ fm-spawn.sh demo-aos-barename-t66085-1861 aos --class builder --mode no-mistakes

  | /Users/evanagee/.no-mistakes/worktrees/b99440365b40/01M2XKEQZTMQG5Z7ZXJQCH3MB5/bin/fm-spawn.sh: line 1371: cd: aos-not-a-real-path-t66085-1861: No such file or directory
  exit status: 1 (spawn refused, as it should be)

  ROUTE STORE AFTER THE REFUSED SPAWN:
    route codex: state=eligible  reason=ok
    route pi-grok: state=eligible  reason=ok
    (no assignment records)
  >> VERDICT: the healthy codex provider is STILL ELIGIBLE. Good.
  >> VERDICT: no assignment record left behind, so the task id is free. Good.
------------------------------------------------------------

STEP 2. Operator fixes the typo and retries the SAME task id.
  $ fm-spawn.sh demo-aos-barename-t66085-1861 <correct/path> --class builder --mode no-mistakes

  | warning: /var/folders/k4/bmrhcryx7ld7c_w81zly9mh40000gn/T//fm-spawn-route-admission.tQLEvl/demo-aos-barename/home/data/demo-aos-barename-t66085-1861/brief.md records no delivery contract line (scaffolded before ship briefs recorded one); launching on the explicit --mode no-mistakes - confirm its definition of done matches
  | dispatch: class=builder harness=codex model=gpt-5 effort=high reason=pin
  | SKILLS: unavailable worker skill file(s): /var/folders/k4/bmrhcryx7ld7c_w81zly9mh40000gn/T//fm-spawn-route-admission.tQLEvl/demo-aos-barename/../worker-home/.agents/skills/caveman/SKILL.md, /var/folders/k4/bmrhcryx7ld7c_w81zly9mh40000gn/T//fm-spawn-route-admission.tQLEvl/demo-aos-barename/../worker-home/.agents/skills/ponytail/SKILL.md; continuing without the unavailable skill(s)
  | spawned demo-aos-barename-t66085-1861 harness=codex kind=ship mode=no-mistakes yolo=off window=firstmate:fm-demo-aos-barename-t66085-1861 worktree=/var/folders/k4/bmrhcryx7ld7c_w81zly9mh40000gn/T//fm-spawn-route-admission.tQLEvl/demo-aos-barename/wt
  exit status: 0

  ROUTE STORE AFTER THE RETRY:
    route codex: state=eligible  reason=ok
    route pi-grok: state=eligible  reason=ok
    task demo-aos-barename-t66085-1861: status=closed route=codex outcome=success
  >> VERDICT: the corrected retry LAUNCHED on the same task id. Good.
------------------------------------------------------------
```

## What changed for the operator

Before: one typo marked the healthy codex provider launch-failed, which excludes
it from every later spawn, and closed the task id. The corrected retry was refused
with 'already closed'. Only a hand edit of state/route.json could recover either.

After: the typo fails before any route is claimed. Both providers stay eligible,
no assignment record is left behind, and the corrected retry launches on the same
task id and records outcome=success.
