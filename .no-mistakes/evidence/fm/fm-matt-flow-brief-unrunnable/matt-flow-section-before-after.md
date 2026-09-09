### BEFORE (commit f349c90) - generated brief, Matt-flow section
# Matt-flow
This brief declares this task a Matt-flow task.
Enter at the project-installed `to-spec` skill, or `triage` for bug work.
Follow the flow's own instructions phase by phase through `tdd`, then stop the flow there.
The no-mistakes pipeline in the Definition of done owns review, so do not run a separate review skill, review sub-agent, or hand review pass before validation.
Leave each phase's natural artifact (spec file, tickets folder, and failing-test commit) and append one status line at every phase transition.


### AFTER (commit 220b9ec) - same command, same mode
# Matt-flow
This brief declares this task a Matt-flow task.
This brief is the spec, so the `to-spec`, `to-tickets`, `triage`, `implement`, and `grill-with-docs` phases are already done or are human-only and must not be invoked.
Enter at the installed `tdd` skill: write the failing test first, then make it pass.
If `tdd` is not installed in this worktree, append `blocked [key=matt-flow-tdd-missing]: tdd skill not installed in this worktree` and stop rather than improvising a flow.
Stop the flow after `tdd` and go straight to the validation in the Definition of done.
The no-mistakes pipeline in the Definition of done owns review, so do not run `code-review`, any other review skill, a review sub-agent, or a hand review pass before validation.
Leave the failing-test commit as the phase artifact and append one status line at the phase transition.

