# Generated Matt-flow brief sections

Command shape:

```sh
FM_HOME=<temporary-home> bin/fm-brief.sh <id> sample-project --mode <mode> --matt-flow
```

## no-mistakes

```markdown
# Matt-flow
This brief declares this task a Matt-flow task.
Enter at the project-installed `to-spec` skill, or `triage` for bug work.
Follow the flow's own instructions phase by phase through `tdd`, then stop the flow there.
The no-mistakes pipeline in the Definition of done owns review, so do not run a separate review skill, review sub-agent, or hand review pass before validation.
Leave each phase's natural artifact (spec file, tickets folder, and failing-test commit) and append one status line at every phase transition.
```

## direct-PR

```markdown
# Matt-flow
This brief declares this task a Matt-flow task.
Enter at the project-installed `to-spec` skill, or `triage` for bug work.
Follow the flow's own instructions phase by phase through `code-review`, without skipping phases.
Leave each phase's natural artifact (spec file, tickets folder, failing-test commit, and review notes) and append one status line at every phase transition.
```

## local-only

```markdown
# Matt-flow
This brief declares this task a Matt-flow task.
Enter at the project-installed `to-spec` skill, or `triage` for bug work.
Follow the flow's own instructions phase by phase through `code-review`, without skipping phases.
Leave each phase's natural artifact (spec file, tickets folder, failing-test commit, and review notes) and append one status line at every phase transition.
```

## Ordinary no-mistakes brief

Generated without `--matt-flow`. The brief contains no `# Matt-flow` section.
