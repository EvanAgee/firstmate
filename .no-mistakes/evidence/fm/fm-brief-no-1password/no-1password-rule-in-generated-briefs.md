# Evidence: generated worker briefs forbid the 1Password CLI

Every brief below was scaffolded by running the real `bin/fm-brief.sh` into a throwaway FM_HOME.
The text shown is the actual `brief.md` a crewmate/scout would open.

## ship-nomistakes

Rule line as rendered in `# Rules`:

```
71:12. Never run the 1Password CLI (`op run`, `op read`, `op item`, `op environment`, or any other `op` subcommand) for anything. Secrets come from this worktree's `.env.local` or the app's equivalent local env file. If a variable you need is missing there, append `blocked [key=missing-env-<NAME>]: <NAME> is missing from .env.local` and stop; never fetch it.
```

Definition of done --intent carry-forward sentence:

```
89:The no-1Password rule above is not scaffold boilerplate: the intent must carry the no-1Password rule verbatim so the pipeline's review, test, document, and CI-fix agents inherit it.
```

## ship-directpr

Rule line as rendered in `# Rules`:

```
70:12. Never run the 1Password CLI (`op run`, `op read`, `op item`, `op environment`, or any other `op` subcommand) for anything. Secrets come from this worktree's `.env.local` or the app's equivalent local env file. If a variable you need is missing there, append `blocked [key=missing-env-<NAME>]: <NAME> is missing from .env.local` and stop; never fetch it.
```

## ship-localonly

Rule line as rendered in `# Rules`:

```
70:12. Never run the 1Password CLI (`op run`, `op read`, `op item`, `op environment`, or any other `op` subcommand) for anything. Secrets come from this worktree's `.env.local` or the app's equivalent local env file. If a variable you need is missing there, append `blocked [key=missing-env-<NAME>]: <NAME> is missing from .env.local` and stop; never fetch it.
```

## ship-mattflow

Rule line as rendered in `# Rules`:

```
78:12. Never run the 1Password CLI (`op run`, `op read`, `op item`, `op environment`, or any other `op` subcommand) for anything. Secrets come from this worktree's `.env.local` or the app's equivalent local env file. If a variable you need is missing there, append `blocked [key=missing-env-<NAME>]: <NAME> is missing from .env.local` and stop; never fetch it.
```

Definition of done --intent carry-forward sentence:

```
96:The no-1Password rule above is not scaffold boilerplate: the intent must carry the no-1Password rule verbatim so the pipeline's review, test, document, and CI-fix agents inherit it.
```

## ship-herdrlab

Rule line as rendered in `# Rules`:

```
85:12. Never run the 1Password CLI (`op run`, `op read`, `op item`, `op environment`, or any other `op` subcommand) for anything. Secrets come from this worktree's `.env.local` or the app's equivalent local env file. If a variable you need is missing there, append `blocked [key=missing-env-<NAME>]: <NAME> is missing from .env.local` and stop; never fetch it.
```

Definition of done --intent carry-forward sentence:

```
103:The no-1Password rule above is not scaffold boilerplate: the intent must carry the no-1Password rule verbatim so the pipeline's review, test, document, and CI-fix agents inherit it.
```

## scout-brief

Rule line as rendered in `# Rules`:

```
57:9. Never run the 1Password CLI (`op run`, `op read`, `op item`, `op environment`, or any other `op` subcommand) for anything. Secrets come from this worktree's `.env.local` or the app's equivalent local env file. If a variable you need is missing there, append `blocked [key=missing-env-<NAME>]: <NAME> is missing from .env.local` and stop; never fetch it.
```

## secondmate-brief

No numbered Rules section / rule absent (expected for secondmate charter, which is out of scope).

## Rule shown in full context (no-mistakes ship brief)

```
   append `needs-decision [key=<slug>]: {summary of options}` and stop. Firstmate will apply the configured authority and reply with the decision.
   Every `needs-decision:` and `blocked:` line MUST carry `[key=<slug>]`, using a short slug you choose for that question.
   An unkeyed line lands under the shared key `default`, so a second unkeyed decision silently overwrites the first and only the last one is ever seen.
   A decision or blocker you opened stays open until a `resolved` line carrying its exact key lands; a later `done:` or `working:` line never closes it, even when the answer is what started that work.
   Recording a decision is not acting on it: a `resolved` line records the answer, and the work it unblocks still has to be done in the same turn.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append `resolved [key=<slug>]: {how it cleared}` yourself, reusing the exact key you opened it with, as you resume.
7. Never stop, restart, or update the shared `no-mistakes` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append `blocked [key=<slug>]: {the daemon error}` and stop; only firstmate manages the daemon.
8. After CI is green and before reporting any PR done, check its review comments and resolve every actionable review-bot finding (including CodeRabbit and Copilot) and human review thread by fixing it or replying with a concrete reason it is not valid.
9. Before reporting done for any PR with user-visible UI changes, upload viewport screenshots to Cloudflare and embed the returned public URLs in the PR body by running, from inside this task worktree, `node ~/Sites/agent-workflow-kit/scripts/upload-artifact.mjs --ref pr-<PR#> --pr <PR#> <screenshot-file>...` (credentials live once per machine at `~/.claude/cloudflare-r2.env`).
   The tool uploads each file, prints ready-to-paste markdown, writes the links into the PR body, and refuses a desktop or full-screen capture, so pass only viewport screenshots from your own lane's browser.
   Committed repo paths (for example `docs/reference/151/foo.png`) and local file paths do NOT render in a private-repo PR and do NOT count.
   The `pr-evidence` check only confirms that the PR body contains Markdown image syntax with an HTTPS URL; it does not fetch or inspect the image, so open the PR page and verify every image displays before reporting done instead of trusting the upload command's output.
   After embedding the URLs, push a commit (an empty one is fine) so push-triggered checks re-run against the current head; editing the PR body alone does not re-run them.
10. Run `npx unslop` on every changed file and fix all findings before any PR.
11. Do not spawn subagents, background agents, or sub-workers; do all work directly in your own session.
12. Never run the 1Password CLI (`op run`, `op read`, `op item`, `op environment`, or any other `op` subcommand) for anything. Secrets come from this worktree's `.env.local` or the app's equivalent local env file. If a variable you need is missing there, append `blocked [key=missing-env-<NAME>]: <NAME> is missing from .env.local` and stop; never fetch it.

# Project memory
```

## --help text names the rule

```
1Password CLI: secrets come from the worktree's .env.local or the app's
equivalent local env file, never `op`. The no-mistakes ship Definition of
done also requires `--intent` to carry that rule verbatim so the pipeline's
own review, test, document, and CI-fix agents inherit it.
Ship tasks include a project-memory section so durable project-intrinsic
```
