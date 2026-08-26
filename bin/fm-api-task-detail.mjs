// Assemble GET /tasks/<id> from one firstmate home's task records.
//
// A known task (meta, status, or brief present) returns:
//   { ok, task: { id, kind, project, harness, model, started_at, brief,
//     timeline, stage, activity } }
// An unknown id returns null so the server can send JSON 404.
// harness and model come from the task's meta record ("" when absent).
// started_at is the spawn_gen epoch from meta, else the status file's birth
// time, else null.
// Each timeline event carries observed_at (ISO) and time_approximate: true.
// The times pin to the watcher delivery log entries naming the status file
// when enough exist, and otherwise interpolate between the status file's
// birth and modification times, so a screen can show when each event was
// seen without reading firstmate's files itself.
// activity contains the task worktree and branch, commits since origin/main,
// diff totals and stat text, the uncommitted-file count, review/test/lint/ci
// pipeline steps, pull-request checks and review-thread counts, and the latest
// watcher-owned pane tail. Missing activity sources stay explicit in the JSON
// instead of turning a known task into a failed request.

import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const BIN_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.dirname(BIN_DIR);
const CREW_STATE = path.join(BIN_DIR, "fm-crew-state.sh");
const COMMAND_TIMEOUT_MS = 8000;
const MAX_COMMAND_BYTES = 4 * 1024 * 1024;
const PIPELINE_STEPS = ["review", "test", "lint", "ci"];
const GITHUB_PR = /^https:\/\/github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/pull\/([1-9][0-9]*)\/?$/;

function command(command, args, options = {}) {
  return new Promise((resolve) => {
    execFile(
      command,
      args,
      {
        cwd: options.cwd,
        env: options.env ? { ...process.env, ...options.env } : process.env,
        encoding: "utf8",
        timeout: options.timeoutMs || COMMAND_TIMEOUT_MS,
        maxBuffer: options.maxBuffer || MAX_COMMAND_BYTES,
      },
      (error, stdout) => {
        resolve({
          ok: !error,
          stdout: stdout || "",
        });
      },
    );
  });
}

function regularFile(file) {
  try {
    const stat = fs.lstatSync(file);
    return stat.isFile() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
}

function readRegularFile(file) {
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) return null;
    return fs.readFileSync(file, "utf8");
  } catch {
    return null;
  }
}

function metaFields(text) {
  const fields = {};
  for (const line of (text || "").split(/\r?\n/)) {
    const at = line.indexOf("=");
    if (at < 1) continue;
    fields[line.slice(0, at)] = line.slice(at + 1);
  }
  return fields;
}

function timelineFrom(text) {
  const timeline = [];
  for (const raw of (text || "").split(/\r?\n/)) {
    if (!raw.trim()) continue;
    const at = raw.indexOf(":");
    timeline.push({
      index: timeline.length + 1,
      raw,
      verb: at === -1 ? "" : raw.slice(0, at).trim(),
      note: at === -1 ? raw.trim() : raw.slice(at + 1).trim(),
    });
  }
  return timeline;
}

// --- timeline clock ---------------------------------------------------------
//
// The status file records no times, so each event's observed_at is
// reconstructed: delivery-log entries naming the status file pin real
// observation times, and the rest interpolates between the file's birth and
// modification times. Every reconstructed time is marked approximate.

const WATCH_DATE_PATTERN =
  /\b(?:Sun|Mon|Tue|Wed|Thu|Fri|Sat)\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4}\b/;

function parseWatchTimes(deliveryLog, statusPath) {
  return deliveryLog
    .split(/\r?\n/)
    .filter((line) => line.includes(statusPath))
    .flatMap((line) => {
      const dateText = line.match(WATCH_DATE_PATTERN)?.[0];
      const timestamp = dateText ? Date.parse(dateText) : Number.NaN;
      return Number.isFinite(timestamp) ? [timestamp] : [];
    });
}

function buildTimelineTimes(count, birthtimeMs, modifiedAtMs, watchTimes) {
  if (count === 0) return [];
  if (count === 1) return [watchTimes.at(-1) ?? modifiedAtMs];

  const observedTimes = [...new Set(watchTimes)]
    .filter(Number.isFinite)
    .sort((a, b) => a - b);
  if (observedTimes.length >= count) return observedTimes.slice(-count);
  if (observedTimes.length === count - 1 && Number.isFinite(birthtimeMs)) {
    return [birthtimeMs, ...observedTimes];
  }

  const start = Number.isFinite(birthtimeMs) ? birthtimeMs : modifiedAtMs;
  const end = Math.max(start, modifiedAtMs);
  return Array.from({ length: count }, (_, index) => {
    const progress = index / (count - 1);
    return Math.round(start + (end - start) * progress);
  });
}

function statusClock(statusFile, count, deliveryLog) {
  let birthtimeMs = Number.NaN;
  let modifiedAtMs = Date.now();
  try {
    const stats = fs.statSync(statusFile);
    birthtimeMs = stats.birthtimeMs > 0 ? stats.birthtimeMs : Number.NaN;
    modifiedAtMs = stats.mtimeMs;
  } catch {
    return {
      times: Array.from({ length: count }, () => Date.now()),
      birthtime: null,
    };
  }
  return {
    times: buildTimelineTimes(
      count,
      birthtimeMs,
      modifiedAtMs,
      parseWatchTimes(deliveryLog, statusFile),
    ),
    birthtime: Number.isFinite(birthtimeMs) ? new Date(birthtimeMs).toISOString() : null,
  };
}

function startedAtFromMeta(fields, fallback) {
  const match = (fields.spawn_gen || "").match(/^s?(\d{10,13})(?:\.|$)/);
  if (!match) return fallback;
  const rawTimestamp = Number(match[1]);
  const timestampMs = rawTimestamp < 1_000_000_000_000 ? rawTimestamp * 1_000 : rawTimestamp;
  return Number.isFinite(timestampMs) ? new Date(timestampMs).toISOString() : fallback;
}

function taskIsPresent(metaFile, statusFile, briefFile) {
  return regularFile(metaFile) || regularFile(statusFile) || regularFile(briefFile);
}

function parseStage(text) {
  const match = text.trim().match(/^state: ([^·]+?) · source: ([^·]+?)(?: · (.*))?$/);
  if (!match) return { state: "unknown", source: "none", detail: text.trim() };
  return {
    state: match[1].trim(),
    source: match[2].trim(),
    detail: (match[3] || "").trim(),
  };
}

function toonValue(text, field) {
  const escaped = field.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = text.match(new RegExp(`^\\s*${escaped}:\\s*(.*?)\\s*$`, "m"));
  if (!match) return null;
  const raw = match[1];
  if (raw === "null") return null;
  if (raw.startsWith('"')) {
    try {
      return JSON.parse(raw);
    } catch {
      return raw.slice(1, -1);
    }
  }
  return raw;
}

function parseCommits(text) {
  const fields = text.split("\0");
  if (fields[fields.length - 1] === "") fields.pop();
  const items = [];
  for (let i = 0; i + 2 < fields.length; i += 3) {
    items.push({ sha: fields[i], time: fields[i + 1], message: fields[i + 2] });
  }
  return items;
}

function parseNumstat(text) {
  const tokens = text.split("\0");
  let filesChanged = 0;
  let additions = 0;
  let deletions = 0;
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (!token) continue;
    const fields = token.split("\t");
    if (fields.length < 3) continue;
    filesChanged += 1;
    if (/^[0-9]+$/.test(fields[0])) additions += Number(fields[0]);
    if (/^[0-9]+$/.test(fields[1])) deletions += Number(fields[1]);
    if (!fields[2]) i += 2;
  }
  return { filesChanged, additions, deletions };
}

function countPorcelainRecords(text) {
  const tokens = text.split("\0");
  let count = 0;
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (!token) continue;
    count += 1;
    const status = token.slice(0, 2);
    if (status.includes("R") || status.includes("C")) i += 1;
  }
  return count;
}

async function gitActivity(worktree) {
  const unavailable = {
    worktree: { path: worktree || null, branch: null, available: false },
    commits: { base: "origin/main", count: 0, items: [], available: false },
    diff: {
      base: "origin/main",
      files_changed: null,
      additions: null,
      deletions: null,
      stat: "",
      available: false,
    },
    uncommitted_file_count: null,
  };
  if (!worktree || !fs.existsSync(worktree)) return unavailable;

  const [root, branch, head, commits, numstat, stat, status] = await Promise.all([
    command("git", ["rev-parse", "--show-toplevel"], { cwd: worktree }),
    command("git", ["symbolic-ref", "--quiet", "--short", "HEAD"], { cwd: worktree }),
    command("git", ["rev-parse", "HEAD"], { cwd: worktree }),
    command("git", ["log", "-z", "--format=%H%x00%cI%x00%s", "origin/main..HEAD"], { cwd: worktree }),
    command("git", ["diff", "--numstat", "-z", "origin/main..HEAD"], { cwd: worktree }),
    command("git", ["diff", "--stat", "origin/main..HEAD"], { cwd: worktree }),
    command("git", ["status", "--porcelain=v1", "-z"], { cwd: worktree }),
  ]);
  if (!root.ok) return unavailable;

  const diffTotals = numstat.ok ? parseNumstat(numstat.stdout) : null;
  const items = commits.ok ? parseCommits(commits.stdout) : [];
  return {
    worktree: {
      path: root.stdout.trim() || worktree,
      branch: branch.ok ? branch.stdout.trim() || null : null,
      head: head.ok ? head.stdout.trim() || null : null,
      available: true,
    },
    commits: {
      base: "origin/main",
      count: items.length,
      items,
      available: commits.ok,
    },
    diff: {
      base: "origin/main",
      files_changed: diffTotals ? diffTotals.filesChanged : null,
      additions: diffTotals ? diffTotals.additions : null,
      deletions: diffTotals ? diffTotals.deletions : null,
      stat: stat.ok ? stat.stdout.replace(/\n+$/, "") : "",
      available: Boolean(diffTotals && stat.ok),
    },
    uncommitted_file_count: status.ok ? countPorcelainRecords(status.stdout) : null,
  };
}

function parseNoMistakesSteps(text) {
  const steps = {};
  let inSteps = false;
  for (const line of text.split(/\r?\n/)) {
    if (/^\s*steps\[[0-9]+\]/.test(line)) {
      inSteps = true;
      continue;
    }
    if (!inSteps) continue;
    if (/^[^ \t]/.test(line)) break;
    const fields = line.trim().split(",");
    if (fields.length < 2) continue;
    const step = fields[0].replace(/^"|"$/g, "");
    if (!PIPELINE_STEPS.includes(step)) continue;
    steps[step] = fields[1].replace(/^"|"$/g, "");
  }
  return steps;
}

function normalizeStep(raw) {
  switch (raw) {
    case "completed":
    case "passed":
    case "pass":
    case "green":
    case "checks-passed":
      return "passed";
    case "failed":
    case "fail":
    case "cancelled":
    case "fix_review":
      return "failed";
    case "running":
    case "fixing":
    case "ci":
      return "running";
    case "pending":
    case "awaiting_approval":
      return "pending";
    default:
      return "unknown";
  }
}

function parsePipelineAttestation(body) {
  const match = (body || "").match(
    /<!--\s*no-mistakes-pipeline-attestation:v1\s+({[^\n]*})\s*-->/,
  );
  if (!match) return null;
  try {
    const value = JSON.parse(match[1]);
    return value && typeof value === "object" ? value : null;
  } catch {
    return null;
  }
}

function timelineStepEvidence(timeline) {
  const evidence = {};
  for (const event of timeline) {
    const text = `${event.verb} ${event.note}`.toLowerCase();
    for (const rawClause of text.split(";")) {
      const clause = rawClause.replace(/https?:\/\/\S+/g, " ");
      for (const step of PIPELINE_STEPS) {
        const namesStep = new RegExp(`\\b${step}\\b`).test(clause);
        if (!namesStep && !(step === "ci" && clause.includes("checks green"))) continue;
        if (/\b(fail|failed|red)\b/.test(clause)) evidence[step] = "failed";
        else if (/\b(pass|passed|green|completed|checks green)\b/.test(clause)) evidence[step] = "passed";
        else if (/\b(run|running|working|validating)\b/.test(clause)) evidence[step] = "running";
      }
    }
  }
  return evidence;
}

function stepTracker(timeline, attestation, liveSteps, ci) {
  const tracker = {};
  for (const step of PIPELINE_STEPS) {
    tracker[step] = { status: "unknown", raw: null, source: "none" };
  }
  for (const [step, raw] of Object.entries(timelineStepEvidence(timeline))) {
    tracker[step] = { status: normalizeStep(raw), raw, source: "status-timeline" };
  }
  if (attestation && Array.isArray(attestation.steps)) {
    for (const row of attestation.steps) {
      if (!row || !PIPELINE_STEPS.includes(row.step)) continue;
      tracker[row.step] = {
        status: normalizeStep(row.status),
        raw: row.status || null,
        source: "pr-attestation",
      };
    }
  }
  for (const [step, raw] of Object.entries(liveSteps)) {
    tracker[step] = { status: normalizeStep(raw), raw, source: "no-mistakes" };
  }
  if (ci.status !== "unknown") {
    tracker.ci = { status: ci.status, raw: ci.summary || ci.status, source: "github-checks" };
  }
  return tracker;
}

function parseChecks(text) {
  const checks = [];
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\s{2,}(.+),(pass|fail|pending|cancelled|skipping|skip|neutral)$/);
    if (!match) continue;
    let name = match[1];
    if (name.startsWith('"')) {
      try {
        name = JSON.parse(name);
      } catch {
        name = name.slice(1, -1);
      }
    }
    checks.push({ name, status: match[2] });
  }
  const summary = toonValue(text, "summary") || "";
  let status = "unknown";
  if (checks.some((row) => row.status === "fail" || row.status === "cancelled")) status = "failed";
  else if (checks.some((row) => row.status === "pending")) status = "pending";
  else if (checks.length > 0) status = "passed";
  return { status, summary, checks, available: checks.length > 0 || Boolean(summary) };
}

function prUrlFrom(fields, statusText) {
  if (fields.pr) return fields.pr;
  const match = (statusText || "").match(/https:\/\/[^\s)]+\/(?:pull|merge_requests)\/[0-9]+/);
  return match ? match[0] : null;
}

async function discoverPr(worktree, branch) {
  if (!worktree || !branch) return null;
  const result = await command(
    "gh-axi",
    ["pr", "list", "--state", "all", "--head", branch, "--fields", "url", "--limit", "1"],
    { cwd: worktree },
  );
  if (!result.ok) return null;
  const match = result.stdout.match(/https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*/);
  return match ? match[0] : null;
}

async function reviewThreadCounts(owner, repo, number) {
  let open = 0;
  let resolved = 0;
  let cursor = null;
  for (let page = 0; page < 20; page += 1) {
    const after = cursor ? `,after:${JSON.stringify(cursor)}` : "";
    const query = `{repository(owner:${JSON.stringify(owner)},name:${JSON.stringify(repo)}){pullRequest(number:${number}){reviewThreads(first:100${after}){nodes{isResolved}pageInfo{hasNextPage endCursor}}}}}`;
    const result = await command("gh-axi", ["api", "POST", "/graphql", "--field", `query=${query}`]);
    if (!result.ok || /(^|\n)errors(?:\[|:)/.test(result.stdout)) {
      return { open: null, resolved: null, total: null, available: false };
    }
    const values = [...result.stdout.matchAll(/^\s+(true|false)\s*$/gm)].map((match) => match[1]);
    for (const value of values) {
      if (value === "true") resolved += 1;
      else open += 1;
    }
    if (toonValue(result.stdout, "hasNextPage") !== "true") {
      return { open, resolved, total: open + resolved, available: true };
    }
    cursor = toonValue(result.stdout, "endCursor");
    if (!cursor) return { open: null, resolved: null, total: null, available: false };
  }
  return { open: null, resolved: null, total: null, available: false };
}

async function pullRequestActivity(url, worktree) {
  const absent = {
    url: url || null,
    state: null,
    ci: { status: "unknown", summary: "", checks: [], available: false },
    review_threads: { open: null, resolved: null, total: null, available: false },
    attestation: null,
    available: false,
  };
  const parsed = (url || "").match(GITHUB_PR);
  if (!parsed) return absent;
  const [, owner, repo, numberText] = parsed;
  const number = Number(numberText);
  const repository = `${owner}/${repo}`;
  const [view, checks, threads] = await Promise.all([
    command("gh-axi", ["pr", "view", numberText, "-R", repository, "--full"], { cwd: worktree }),
    command("gh-axi", ["pr", "checks", numberText, "-R", repository], { cwd: worktree }),
    reviewThreadCounts(owner, repo, number),
  ]);
  const body = view.ok ? toonValue(view.stdout, "body") || "" : "";
  return {
    url,
    state: view.ok ? toonValue(view.stdout, "state") : null,
    ci: checks.ok ? parseChecks(checks.stdout) : absent.ci,
    review_threads: threads,
    attestation: parsePipelineAttestation(body),
    available: view.ok || checks.ok || threads.available,
  };
}

async function livePipeline(worktree, branch, head) {
  if (!worktree || !branch || !head) return { run: null, steps: {}, available: false };
  const result = await command("no-mistakes", ["axi", "status"], { cwd: worktree });
  if (!result.ok) return { run: null, steps: {}, available: false };
  const runBranch = toonValue(result.stdout, "branch");
  const runHead = toonValue(result.stdout, "head");
  const headMatches = runHead && (head.startsWith(runHead) || runHead.startsWith(head));
  if (runBranch !== branch || !headMatches) return { run: null, steps: {}, available: false };
  return {
    run: {
      id: toonValue(result.stdout, "id"),
      branch: runBranch,
      head: runHead,
      status: toonValue(result.stdout, "status"),
      outcome: toonValue(result.stdout, "outcome"),
    },
    steps: parseNoMistakesSteps(result.stdout),
    available: true,
  };
}

function paneTail(file) {
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error("not a regular file");
    const text = fs.readFileSync(file, "utf8");
    return { text: text.replace(/\n+$/, ""), captured_at: stat.mtime.toISOString(), available: true };
  } catch {
    return { text: "", captured_at: null, available: false };
  }
}

function taskEnv(home, stateDir) {
  return {
    FM_ROOT_OVERRIDE: ROOT,
    FM_HOME: home,
    FM_STATE_OVERRIDE: stateDir,
    FM_DATA_OVERRIDE: path.join(home, "data"),
    FM_CONFIG_OVERRIDE: path.join(home, "config"),
    FM_PROJECTS_OVERRIDE: path.join(home, "projects"),
    FM_CREW_STATE_NM_TIMEOUT: "6",
  };
}

export async function taskDetailBody(home, id, options = {}) {
  const stateDir = options.stateDir || path.join(home, "state");
  const metaFile = path.join(stateDir, `${id}.meta`);
  const statusFile = path.join(stateDir, `${id}.status`);
  const briefFile = path.join(home, "data", id, "brief.md");
  if (!taskIsPresent(metaFile, statusFile, briefFile)) return null;

  const metaText = readRegularFile(metaFile) || "";
  const statusText = readRegularFile(statusFile) || "";
  const brief = readRegularFile(briefFile) || "";
  const fields = metaFields(metaText);
  const timeline = timelineFrom(statusText);
  const deliveryLog = readRegularFile(path.join(stateDir, ".watch-deliveries.log")) || "";
  const clock = statusClock(statusFile, timeline.length, deliveryLog);
  for (let i = 0; i < timeline.length; i += 1) {
    timeline[i].observed_at = new Date(clock.times[i]).toISOString();
    timeline[i].time_approximate = true;
  }
  const git = await gitActivity(fields.worktree || "");
  const branch = git.worktree.branch;
  const head = git.worktree.head;

  const [stageResult, pipeline] = await Promise.all([
    command(CREW_STATE, [id], { env: taskEnv(home, stateDir), timeoutMs: 10000 }),
    livePipeline(fields.worktree || "", branch, head),
  ]);
  const stage = stageResult.ok
    ? parseStage(stageResult.stdout.split(/\r?\n/)[0] || "")
    : { state: "unknown", source: "none", detail: "current stage unavailable" };

  let prUrl = prUrlFrom(fields, statusText);
  if (!prUrl) prUrl = await discoverPr(fields.worktree || "", branch);
  const pullRequest = await pullRequestActivity(
    prUrl,
    git.worktree.available ? git.worktree.path : ROOT,
  );
  const steps = stepTracker(timeline, pullRequest.attestation, pipeline.steps, pullRequest.ci);
  const pipelineAvailable = Object.values(steps).some((step) => step.source !== "none");

  return {
    ok: true,
    task: {
      id,
      kind: fields.kind || "ship",
      project: fields.project || "",
      harness: fields.harness || "",
      model: fields.model || "",
      started_at: startedAtFromMeta(fields, clock.birthtime),
      brief,
      timeline,
      stage,
      activity: {
        worktree: git.worktree,
        commits: git.commits,
        diff: git.diff,
        uncommitted_file_count: git.uncommitted_file_count,
        pipeline: {
          steps,
          run: pipeline.run,
          attestation: pullRequest.attestation,
          available: pipelineAvailable,
        },
        pull_request: {
          url: pullRequest.url,
          state: pullRequest.state,
          ci: pullRequest.ci,
          review_threads: pullRequest.review_threads,
          available: pullRequest.available,
        },
        pane_tail: paneTail(path.join(stateDir, `${id}.pane-tail`)),
      },
    },
  };
}
