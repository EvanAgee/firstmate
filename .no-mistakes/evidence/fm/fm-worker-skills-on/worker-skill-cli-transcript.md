# Worker-skill CLI transcript

Captured on 2026-09-04 from target commit `01f05828b4edd30102f0c545890aec92c1811d42`.

## Installed harness capability checks

```text
$ claude --version
2.1.260 (Claude Code)
$ claude --help | rg -- '--append-system-prompt(-file)?'
--append-system-prompt <prompt>
--append-system-prompt[-file]

$ pi --version
0.84.3
$ pi --help | rg -- '--skill([ =]|$)'
--skill <path>  Load a skill file or directory (can be used multiple times)

$ omp --version
omp/18.1.6
$ omp --help | rg -- '--append-system-prompt([ =]|$)'
--append-system-prompt=<value>  Append text or file contents to the system prompt
$ bin/fm-omp-capabilities.sh --print-worker-skill-mode
append-system-prompt

$ codex --version
codex-cli 0.152.1
$ codex --help | rg -i -- 'skill|system|prompt|rule'
Usage: codex [OPTIONS] [PROMPT]
[PROMPT]  Optional user prompt to start the session

$ opencode --version
1.18.4
$ opencode --help | rg -i -- 'skill|system|prompt|rule'
--prompt  prompt to use

$ grok --version
grok 1.0.5 (5115b46bc909) [stable]
$ grok --help | rg -i -- 'skill|system|prompt|rule'
--rules <RULES>  Extra rules to append to the system prompt
--prompt-file <PATH>  Single-turn prompt from a file

$ kimi --version
kimi, version 1.5
$ kimi --help | rg -i -- 'skill|system|prompt|rule'
--skills-dir DIRECTORY  Path to the skills directory

$ command -v cursor cursor-agent muse pi-signed
cursor=absent
cursor-agent=absent
muse=absent
pi-signed=absent
```

## Controlled `fm-spawn.sh` launch capture

The existing behavioral fixture drove the real `fm-spawn.sh` executable through an isolated git worktree and captured the literal command sent to its fake tmux pane.

```text
=== Claude structured launch ===
spawned <id> harness=claude kind=ship mode=no-mistakes yolo=off
launch: ... claude --dangerously-skip-permissions --append-system-prompt-file '/tmp/fm-<id>/worker-skills.<random>' ...
delivered prompt first line: Active skill levels: caveman: full, ponytail: full
delivered skill bodies: CAVEMAN_FIXTURE_BODY,PONYTAIL_FIXTURE_BODY

=== Pi structured launch ===
spawned <id> harness=pi kind=ship mode=no-mistakes yolo=off
launch: ... pi ... --skill '<resolved-home>/.agents/skills/caveman' --skill '<resolved-home>/.agents/skills/ponytail' ...

=== Missing ponytail fallback ===
SKILLS: unavailable worker skill file(s): <resolved-home>/.agents/skills/ponytail/SKILL.md; continuing without the unavailable skill(s)
spawned <id> harness=pi kind=ship mode=no-mistakes yolo=off
launch: ... pi ... --skill '<resolved-home>/.agents/skills/caveman' ...

=== Raw launch escape hatch ===
SKILLS: raw launches get no skill injection
spawned <id> harness=custom-agent kind=ship mode=no-mistakes yolo=off
launch: custom-agent --flag
```

## Generated scout brief

```text
# Session skills
Every structured launch delivers caveman (`full`) and ponytail (`full`) when their installed skill files are available.
On a raw launch, load caveman and ponytail yourself before starting.
caveman keeps chat terse; every durable output stays normal prose, for example commits, PRs, issues, docs, scout reports, review comments, and plans.
The examples are not an exhaustive list.
Ponytail means building the simplest thing that works without dropping required validation, error handling, security, accessibility, or brief-required tests.
This brief's test requirements win over ponytail's test rule.
The skill files own the details: `~/.agents/skills/caveman/SKILL.md` and `~/.agents/skills/ponytail/SKILL.md`.
For delivered skills, the skill-defined off phrases `stop caveman` and `stop ponytail` are available.
```

## Live process attempt

An isolated Claude spawn was attempted with its home, project, git worktree, and tmux socket inside the assigned worktree. The executable refused before endpoint creation because this is a no-mistakes gate process:

```text
error: no-mistakes gate agent must not drive the fleet (NO_MISTAKES_GATE set)
```

The gate environment was not bypassed. The acceptance-required real Claude and Pi worker launches therefore remain unverified in this phase.
