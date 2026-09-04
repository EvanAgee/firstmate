#!/usr/bin/env bash
# fm-token-ledger.sh - read-only token and cost ledger for the fleet's agent sessions.
#
# Answers "what did this cost?" for every worker, scout, pipeline run, and
# firstmate session, and lets one snapshot be compared against another so a
# change to briefs, models, or effort can be judged by what it actually spent.
# Read-only over the harness session logs; it never reads or writes a project.
#
# Usage:
#   fm-token-ledger.sh snapshot [--since <iso>] [--label <name>] [--stdout]
#   fm-token-ledger.sh compare <a.tsv> <b.tsv>
#   fm-token-ledger.sh task <id>
#   fm-token-ledger.sh -h | --help
#
# snapshot writes data/token-ledger/<label-or-YYYY-MM-DD>.tsv and prints totals
# by harness and by kind. --stdout prints the rows instead of writing a file.
# --since defaults to midnight local time today; a bare date (2026-09-04) or a
# full ISO-8601 timestamp are both accepted. Sessions with no turn at or after
# --since are dropped entirely.
#
# compare prints the two files' totals side by side with percent change, then
# every task id present in both with its own before/after. Rows in only one file
# are listed by id so a disappearance is never silent.
#
# task prints one task's sessions and its totals, in the same column order, for
# quoting in a teardown report.
#
# SOURCES
#   Claude Code  ~/.claude/projects/<cwd-slug>/<session>.jsonl
#     Assistant records carry message.usage (input_tokens,
#     cache_creation_input_tokens, cache_read_input_tokens, output_tokens, and
#     output_tokens_details.thinking_tokens), plus message.model, cwd,
#     gitBranch, and timestamp. Claude logs record no cost, so cost is 0.
#   Pi           ~/.pi/agent/sessions/<cwd-slug>/<session>.jsonl
#     A session record carries cwd; model_change records carry provider and
#     modelId; assistant records carry message.usage (input, output, cacheRead,
#     cacheWrite, reasoning) and message.usage.cost.total.
#   Both roots are overridable for tests: FM_CLAUDE_SESSIONS_ROOT and
#   FM_PI_SESSIONS_ROOT.
#
# ROW FIELDS (tab separated, one row per session, header line first)
#   task        attributed task id, pipeline run id, "firstmate", or "-"
#   kind        worker | scout | secondmate | pipeline | firstmate | -
#   harness     claude | pi
#   worktree    the session's own cwd
#   branch      gitBranch for Claude, "-" for Pi (Pi logs record no branch)
#   model       last model the session used
#   start,end   first and last counted turn, ISO-8601 local, second precision
#   turns       counted assistant turns
#   input, cache_write, cache_read, output, thinking   token totals
#   cost_usd    Pi's own recorded cost; 0 for Claude
#   session     the session file's basename without .jsonl
#
# ATTRIBUTION
#   A session is attributed only on evidence, never on proximity.
#
#   worker/scout  state/<id>.meta names a worktree= and a spawn_gen=
#     s<epoch>.<pid>.<rand>. A session in that worktree is that task's only when
#     its first turn falls inside the task's spawn window. That test reads the
#     session's true first turn, the earliest turn in the whole log, so --since
#     changes only which turns are counted and never who a session belongs to.
#     A window runs from its own spawn epoch to the next spawn epoch recorded
#     for that same worktree, and to now for the newest one. The meta's kind=
#     chooses scout or secondmate; everything else, a ship spawn included, is a
#     worker.
#
#     Treehouse and Orca reuse a worktree slot across tasks, so a slot's path is
#     not an identity. A session that started before the current occupant's
#     spawn - a torn-down task whose meta is gone - stays unattributed and keeps
#     its worktree, rather than being charged to whoever holds the slot now.
#     Unattributed is the correct answer here; a guess would silently move real
#     spend onto the wrong task.
#
#   pipeline      a no-mistakes agent session, identified by a manager/<run-id>
#     branch or by a cwd under the no-mistakes worktrees root. The run id is the
#     branch suffix, else the last path segment of the cwd.
#
#   firstmate     a session whose cwd is this home's own primary checkout.
#
# EXIT STATUS
#   0 on success, 2 on a usage error, 1 on an unreadable input file.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() {
  sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  '')
    usage >&2
    exit 2
    ;;
esac

FM_LEDGER_ROOT=$FM_ROOT \
FM_LEDGER_HOME=$FM_HOME \
FM_LEDGER_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}" \
FM_LEDGER_DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}" \
  exec python3 - "$@" <<'PY'
from __future__ import annotations

import glob
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(os.environ["FM_LEDGER_ROOT"])
STATE = Path(os.environ["FM_LEDGER_STATE"])
DATA = Path(os.environ["FM_LEDGER_DATA"])
LEDGER_DIR = DATA / "token-ledger"

CLAUDE_ROOT = Path(
    os.environ.get("FM_CLAUDE_SESSIONS_ROOT") or Path.home() / ".claude" / "projects"
)
PI_ROOT = Path(
    os.environ.get("FM_PI_SESSIONS_ROOT") or Path.home() / ".pi" / "agent" / "sessions"
)
NO_MISTAKES_WORKTREES = Path(
    os.environ.get("FM_NO_MISTAKES_WORKTREES") or Path.home() / ".no-mistakes" / "worktrees"
)

COLUMNS = [
    "task",
    "kind",
    "harness",
    "worktree",
    "branch",
    "model",
    "start",
    "end",
    "turns",
    "input",
    "cache_write",
    "cache_read",
    "output",
    "thinking",
    "cost_usd",
    "session",
]
TOKEN_COLUMNS = ["input", "cache_write", "cache_read", "output", "thinking"]
MANAGER_BRANCH = re.compile(r"^manager/(.+)$")
# state/<id>.meta kind= to a ledger kind. A ship spawn is a worker, and so is
# anything else that holds a worktree and a spawn generation.
META_KIND = {"scout": "scout", "secondmate": "secondmate"}
SPAWN_GEN = re.compile(r"^s(\d+)\.")
INTEGER_CELL = re.compile(r"^-?\d+$")
NUMBER_CELL = re.compile(r"^-?\d+(\.\d+)?$")


class LedgerError(Exception):
    """One fatal ledger failure, reported without a traceback."""


def die(message: str, code: int = 1) -> None:
    raise LedgerError(f"{message}|{code}")


def parse_since(text: str | None) -> datetime:
    if not text:
        now = datetime.now().astimezone()
        return now.replace(hour=0, minute=0, second=0, microsecond=0)
    raw = text.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        die(f"error: --since is not an ISO-8601 date or timestamp: {text}", 2)
    if parsed.tzinfo is None:
        parsed = parsed.astimezone()
    return parsed


def parse_stamp(text: str) -> datetime | None:
    """One log timestamp as an aware datetime, or None when unusable."""
    if not isinstance(text, str) or not text:
        return None
    raw = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def show_stamp(moment: datetime | None) -> str:
    if moment is None:
        return "-"
    return moment.astimezone().strftime("%Y-%m-%dT%H:%M:%S")


def read_records(path: Path):
    """Every JSON object in one .jsonl file; unparseable lines are skipped."""
    try:
        handle = path.open(encoding="utf-8", errors="replace")
    except OSError as err:
        die(f"error: cannot read {path}: {err}")
    with handle:
        for line in handle:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(record, dict):
                yield record


def as_int(value) -> int:
    return value if isinstance(value, int) else 0


def mark_turn(row: dict, moment: datetime, since: datetime) -> bool:
    """Fold one turn's timestamp into the row; True when it is inside --since.

    first_turn spans the whole log so attribution never moves with the cutoff,
    while start and end span only the counted turns. All three track time
    rather than the order records happen to be written in.
    """
    if row["first_turn"] is None or moment < row["first_turn"]:
        row["first_turn"] = moment
    if moment < since:
        return False
    if row["start"] is None or moment < row["start"]:
        row["start"] = moment
    if row["end"] is None or moment > row["end"]:
        row["end"] = moment
    row["turns"] += 1
    return True


def blank_session(harness: str, path: Path) -> dict:
    return {
        "harness": harness,
        "session": path.stem,
        "worktree": "",
        "branch": "-",
        "model": "-",
        "start": None,
        "end": None,
        "first_turn": None,
        "turns": 0,
        "cost_usd": 0.0,
        "tokens": Counter(),
    }


def read_claude_session(path: Path, since: datetime) -> dict | None:
    row = blank_session("claude", path)
    for record in read_records(path):
        row["worktree"] = record.get("cwd") or row["worktree"]
        branch = record.get("gitBranch")
        if branch:
            row["branch"] = branch
        message = record.get("message")
        usage = message.get("usage") if isinstance(message, dict) else None
        if not isinstance(usage, dict):
            continue
        moment = parse_stamp(record.get("timestamp"))
        if moment is None:
            continue
        if not mark_turn(row, moment, since):
            continue
        row["model"] = message.get("model") or row["model"]
        details = usage.get("output_tokens_details")
        tokens = row["tokens"]
        tokens["input"] += as_int(usage.get("input_tokens"))
        tokens["cache_write"] += as_int(usage.get("cache_creation_input_tokens"))
        tokens["cache_read"] += as_int(usage.get("cache_read_input_tokens"))
        tokens["output"] += as_int(usage.get("output_tokens"))
        if isinstance(details, dict):
            tokens["thinking"] += as_int(details.get("thinking_tokens"))
    return row if row["turns"] else None


def read_pi_session(path: Path, since: datetime) -> dict | None:
    row = blank_session("pi", path)
    for record in read_records(path):
        if record.get("type") == "session":
            row["worktree"] = record.get("cwd") or row["worktree"]
        if record.get("type") == "model_change":
            provider = record.get("provider") or "?"
            model = record.get("modelId")
            if model:
                row["model"] = f"{provider}/{model}"
        message = record.get("message")
        usage = message.get("usage") if isinstance(message, dict) else None
        if not isinstance(usage, dict) or "totalTokens" not in usage:
            continue
        moment = parse_stamp(record.get("timestamp") or message.get("timestamp"))
        if moment is None:
            continue
        if not mark_turn(row, moment, since):
            continue
        tokens = row["tokens"]
        tokens["input"] += as_int(usage.get("input"))
        tokens["cache_write"] += as_int(usage.get("cacheWrite"))
        tokens["cache_read"] += as_int(usage.get("cacheRead"))
        tokens["output"] += as_int(usage.get("output"))
        tokens["thinking"] += as_int(usage.get("reasoning"))
        cost = usage.get("cost")
        if isinstance(cost, dict) and isinstance(cost.get("total"), (int, float)):
            row["cost_usd"] += float(cost["total"])
    return row if row["turns"] else None


def read_sessions(since: datetime) -> list[dict]:
    rows = []
    for pattern, reader in (
        (CLAUDE_ROOT / "*" / "*.jsonl", read_claude_session),
        (PI_ROOT / "*" / "*.jsonl", read_pi_session),
    ):
        for name in sorted(glob.glob(str(pattern))):
            row = reader(Path(name), since)
            if row:
                rows.append(row)
    return rows


def read_meta(path: Path) -> dict:
    fields = {}
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return fields
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            fields[key.strip()] = value.strip()
    return fields


def resolve(path: str | Path) -> Path:
    """One path with symlinks followed, so two spellings of a home compare equal."""
    try:
        return Path(path).resolve()
    except OSError:
        return Path(path)


def spawn_windows() -> dict[str, list[tuple[datetime, datetime | None, str, str]]]:
    """Per worktree, each task's [spawn, next spawn) window, oldest first.

    A slot is reused across tasks, so the window - not the path - is what makes
    an attribution safe. Only the newest window per worktree stays open.
    """
    by_worktree: dict[str, list] = {}
    for meta_path in sorted(STATE.glob("*.meta")):
        fields = read_meta(meta_path)
        worktree = fields.get("worktree")
        match = SPAWN_GEN.match(fields.get("spawn_gen", ""))
        if not worktree or not match:
            continue
        kind = META_KIND.get(fields.get("kind", ""), "worker")
        spawned = datetime.fromtimestamp(int(match.group(1)), tz=timezone.utc)
        by_worktree.setdefault(str(resolve(worktree)), []).append(
            (spawned, meta_path.stem, kind)
        )
    windows = {}
    for worktree, entries in by_worktree.items():
        entries.sort()
        bounded = []
        for index, (spawned, task, kind) in enumerate(entries):
            ends = entries[index + 1][0] if index + 1 < len(entries) else None
            bounded.append((spawned, ends, task, kind))
        windows[worktree] = bounded
    return windows


def attribute(row: dict, windows: dict) -> tuple[str, str]:
    """One session's (task, kind); ("-", "-") when nothing proves an owner."""
    branch = MANAGER_BRANCH.match(row["branch"] or "")
    if branch:
        return branch.group(1), "pipeline"
    worktree = row["worktree"] or ""
    if worktree:
        resolved = resolve(worktree)
        if resolved.is_relative_to(resolve(NO_MISTAKES_WORKTREES)):
            return resolved.name, "pipeline"
        if resolved == resolve(ROOT):
            return "firstmate", "firstmate"
        first_turn = row["first_turn"]
        if first_turn is not None:
            for spawned, ends, task, kind in windows.get(str(resolved), []):
                if first_turn >= spawned and (ends is None or first_turn < ends):
                    return task, kind
    return "-", "-"


def build_rows(since: datetime) -> list[dict]:
    windows = spawn_windows()
    rows = []
    for row in read_sessions(since):
        task, kind = attribute(row, windows)
        tokens = row["tokens"]
        rows.append(
            {
                "task": task,
                "kind": kind,
                "harness": row["harness"],
                "worktree": row["worktree"] or "-",
                "branch": row["branch"],
                "model": row["model"],
                "start": show_stamp(row["start"]),
                "end": show_stamp(row["end"]),
                "turns": str(row["turns"]),
                "input": str(tokens["input"]),
                "cache_write": str(tokens["cache_write"]),
                "cache_read": str(tokens["cache_read"]),
                "output": str(tokens["output"]),
                "thinking": str(tokens["thinking"]),
                "cost_usd": f"{row['cost_usd']:.4f}",
                "session": row["session"],
            }
        )
    rows.sort(key=lambda item: (item["start"], item["session"]))
    return rows


def totals(rows: list[dict]) -> Counter:
    summed = Counter()
    for row in rows:
        for column in TOKEN_COLUMNS:
            summed[column] += int(row[column])
        summed["turns"] += int(row["turns"])
        summed["sessions"] += 1
    return summed


def cost_of(rows: list[dict]) -> float:
    return sum(float(row["cost_usd"]) for row in rows)


def group_by(rows: list[dict], column: str) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = {}
    for row in rows:
        grouped.setdefault(row[column], []).append(row)
    return grouped


def totals_line(label: str, rows: list[dict]) -> str:
    summed = totals(rows)
    return (
        f"{label}: sessions={summed['sessions']} turns={summed['turns']} "
        f"input={summed['input']:,} cache_write={summed['cache_write']:,} "
        f"cache_read={summed['cache_read']:,} output={summed['output']:,} "
        f"thinking={summed['thinking']:,} cost_usd={cost_of(rows):.2f}"
    )


def write_tsv(path: Path, rows: list[dict]) -> None:
    lines = ["\t".join(COLUMNS)]
    lines += ["\t".join(row[column] for column in COLUMNS) for row in rows]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def read_tsv(path: Path) -> list[dict]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as err:
        die(f"error: cannot read {path}: {err}")
    lines = [line for line in text.splitlines() if line.strip()]
    if not lines:
        die(f"error: {path} is empty")
    header = lines[0].split("\t")
    missing = [column for column in COLUMNS if column not in header]
    if missing:
        die(f"error: {path} is missing column(s): {', '.join(missing)}")
    rows = []
    for line in lines[1:]:
        values = line.split("\t")
        if len(values) != len(header):
            die(f"error: {path} has a row with {len(values)} fields, expected {len(header)}")
        row = dict(zip(header, values))
        for column in ["turns"] + TOKEN_COLUMNS:
            if not INTEGER_CELL.match(row[column]):
                die(f"error: {path} has a non-numeric {column}: {row[column]!r}")
        if not NUMBER_CELL.match(row["cost_usd"]):
            die(f"error: {path} has a non-numeric cost_usd: {row['cost_usd']!r}")
        rows.append(row)
    return rows


def percent_change(before: float, after: float) -> str:
    if before == 0:
        return "n/a" if after == 0 else "new"
    return f"{(after - before) / before * 100:+.1f}%"


def print_rows(rows: list[dict]) -> None:
    print("\t".join(COLUMNS))
    for row in rows:
        print("\t".join(row[column] for column in COLUMNS))


def cmd_snapshot(args: list[str]) -> int:
    since_text = None
    label = None
    to_stdout = False
    while args:
        flag = args.pop(0)
        if flag == "--since":
            if not args:
                die("error: --since requires an ISO-8601 date or timestamp", 2)
            since_text = args.pop(0)
        elif flag == "--label":
            if not args:
                die("error: --label requires a name", 2)
            label = args.pop(0)
        elif flag == "--stdout":
            to_stdout = True
        else:
            die(f"error: unknown snapshot option: {flag}", 2)
    if label is not None and (not label or re.search(r"[^A-Za-z0-9._-]|^[.-]", label)):
        die(f"error: --label must be a plain file name: {label}", 2)

    since = parse_since(since_text)
    rows = build_rows(since)
    if to_stdout:
        print_rows(rows)
    else:
        name = label or f"{datetime.now().astimezone():%Y-%m-%d}"
        out = LEDGER_DIR / f"{name}.tsv"
        write_tsv(out, rows)
        print(f"wrote {out} ({len(rows)} sessions since {show_stamp(since)})")

    print()
    print(totals_line("all", rows))
    print()
    print("by harness")
    for name, group in sorted(group_by(rows, "harness").items()):
        print(f"  {totals_line(name, group)}")
    print()
    print("by kind")
    for name, group in sorted(group_by(rows, "kind").items()):
        print(f"  {totals_line(name if name != '-' else 'unattributed', group)}")
    return 0


def cmd_compare(args: list[str]) -> int:
    if len(args) != 2:
        die("error: compare takes exactly two .tsv paths", 2)
    before_rows = read_tsv(Path(args[0]))
    after_rows = read_tsv(Path(args[1]))
    before = totals(before_rows)
    after = totals(after_rows)

    print(f"a: {args[0]}")
    print(f"b: {args[1]}")
    print()
    print(f"{'metric':<12}{'a':>16}{'b':>16}{'change':>12}")
    for column in ["sessions", "turns"] + TOKEN_COLUMNS:
        print(
            f"{column:<12}{before[column]:>16,}{after[column]:>16,}"
            f"{percent_change(before[column], after[column]):>12}"
        )
    before_cost = cost_of(before_rows)
    after_cost = cost_of(after_rows)
    print(
        f"{'cost_usd':<12}{before_cost:>16.2f}{after_cost:>16.2f}"
        f"{percent_change(before_cost, after_cost):>12}"
    )

    before_tasks = {name: rows for name, rows in group_by(before_rows, "task").items() if name != "-"}
    after_tasks = {name: rows for name, rows in group_by(after_rows, "task").items() if name != "-"}
    shared = sorted(set(before_tasks) & set(after_tasks))
    print()
    print(f"tasks in both ({len(shared)})")
    for name in shared:
        first = totals(before_tasks[name])
        second = totals(after_tasks[name])
        total_a = sum(first[column] for column in TOKEN_COLUMNS)
        total_b = sum(second[column] for column in TOKEN_COLUMNS)
        print(
            f"  {name}: tokens {total_a:,} -> {total_b:,} "
            f"({percent_change(total_a, total_b)}), "
            f"cost {cost_of(before_tasks[name]):.2f} -> {cost_of(after_tasks[name]):.2f}"
        )
    only_a = sorted(set(before_tasks) - set(after_tasks))
    only_b = sorted(set(after_tasks) - set(before_tasks))
    print(f"only in a ({len(only_a)}): {', '.join(only_a) if only_a else '-'}")
    print(f"only in b ({len(only_b)}): {', '.join(only_b) if only_b else '-'}")
    return 0


def cmd_task(args: list[str]) -> int:
    if len(args) != 1 or not args[0]:
        die("error: task takes exactly one task id", 2)
    wanted = args[0]
    rows = [row for row in build_rows(parse_since("1970-01-01")) if row["task"] == wanted]
    if not rows:
        print(f"no sessions attributed to {wanted}")
        return 0
    print_rows(rows)
    print()
    print(totals_line(wanted, rows))
    return 0


def main(argv: list[str]) -> int:
    command, args = argv[0], argv[1:]
    handlers = {"snapshot": cmd_snapshot, "compare": cmd_compare, "task": cmd_task}
    if command not in handlers:
        die(f"error: unknown command: {command} (expected snapshot, compare, or task)", 2)
    return handlers[command](args)


try:
    sys.exit(main(sys.argv[1:]))
except LedgerError as error:
    message, _, code = str(error).rpartition("|")
    print(message, file=sys.stderr)
    sys.exit(int(code))
except BrokenPipeError:
    sys.exit(0)
PY
