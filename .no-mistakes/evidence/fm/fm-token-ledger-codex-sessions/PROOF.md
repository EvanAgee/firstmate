# Codex token ledger - live proof

## 1+4. Same frozen copy of real ~/.claude, ~/.pi, ~/.codex logs, both versions

### BEFORE (base 1e625e86)
by harness
  claude: sessions=222 turns=15857 input=100,837 cache_write=62,266,226 cache_read=3,687,664,604 output=7,370,724 thinking=768,046 cost_usd=2565.93
  pi: sessions=30 turns=2163 input=50,104,287 cache_write=0 cache_read=270,312,852 output=1,372,256 thinking=143,284 cost_usd=79.77

### AFTER (19599101)
by harness
  claude: sessions=222 turns=15857 input=100,837 cache_write=62,266,226 cache_read=3,687,664,604 output=7,370,724 thinking=768,046 cost_usd=2565.93
  codex: sessions=111 turns=1731 input=11,411,624 cache_write=0 cache_read=154,536,704 output=553,408 thinking=108,659 cost_usd=0.00
  pi: sessions=30 turns=2163 input=50,104,287 cache_write=0 cache_read=270,312,852 output=1,372,256 thinking=143,284 cost_usd=79.77

claude and pi lines are byte-for-byte identical. codex is new: 111 sessions, 1731 turns.

## 3. Absent Codex logs, real run
by harness
  claude: sessions=222 turns=15857 input=100,837 cache_write=62,266,226 cache_read=3,687,664,604 output=7,370,724 thinking=768,046 cost_usd=2565.93
  pi: sessions=30 turns=2163 input=50,104,287 cache_write=0 cache_read=270,312,852 output=1,372,256 thinking=143,284 cost_usd=79.77

Exit 0. No codex line invented.

## Privacy probe: rollout carrying a secret marker in message/reasoning/api_key
exit: 0
--- full ledger output ---
task	kind	harness	worktree	branch	model	start	end	turns	input	cache_write	cache_read	output	thinking	cost_usd	session
-	-	codex	/tmp/privacy-probe	-	gpt-6-astra	2026-09-18T12:00:00Z	2026-09-18T12:00:00Z	1	70	10	20	50	5	0.0000	rollout-privacy

all: sessions=1 turns=1 input=70 cache_write=10 cache_read=20 output=50 thinking=5 cost_usd=0.00

by harness
  codex: sessions=1 turns=1 input=70 cache_write=10 cache_read=20 output=50 thinking=5 cost_usd=0.00

by kind
  unattributed: sessions=1 turns=1 input=70 cache_write=10 cache_read=20 output=50 thinking=5 cost_usd=0.00
--- secret marker present in output? ---
NOT PRESENT (no conversation or credential text in the ledger)

## 5. Red-first
New Codex tests against the base script (no reader):
not ok - a Codex session inside the spawn window was not attributed to its task
The straddle regression test against the pre-fix commit 1f9fbf22:
not ok - the in-window copy of a straddling Codex duplicate was not counted
Both pass on 19599101; full ledger suite green (36 checks).
