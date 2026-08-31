// Assemble the localhost API read windows from firstmate files.
//
// bin/fm-api-server.mjs owns the HTTP routes and JSON contracts.
// This module reads one home and returns the bodies those routes send.
// GET /captain-queue reads data/captain-queue.json cards firstmate wrote for
// the captain. It does not scan worker status files. An ordinary
// needs-decision is firstmate's to handle and never appears here.
// This file is also the one owner of captain-card option rules: every card
// that ships must offer real named plain-English choices, recommended first.
// Blocked tasks come from fm-classify-lib.sh's scan_open_decisions fold so
// the API cannot disagree with firstmate.
// Rigs come from config/crew-dispatch.json, plus the dispatch note, per-rig
// and default pins, and the crew and secondmate pin lines from
// config/crew-harness and config/secondmate-harness. Consumers parse
// presentation out of those raw strings; this module never interprets them.

import { execFile, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const BIN_DIR = path.dirname(fileURLToPath(import.meta.url));
const SCAN_TIMEOUT_MS = 5000;
const TASKS_AXI_TIMEOUT_MS = 10000;
export const DEFAULT_RIG_CLASS = "__default__";

function classifyEnv() {
  const env = { ...process.env };
  delete env.FM_CLASSIFY_RESOLVE_VERB;
  delete env.FM_CLASSIFY_CAPTAIN_HELD_VERB;
  delete env.FM_CLASSIFY_RESERVED_KEY_PREFIXES;
  return env;
}

function parseScanLine(line) {
  const parts = line.split("\t");
  if (parts.length < 3) return null;
  const task = parts[0];
  const key = parts[1];
  const verb = parts[2];
  if (!task || !key || !verb) return null;
  return { task, key, verb, summary: parts.slice(3).join("\t") };
}

export function scanOpenDecisions(stateDir) {
  const result = spawnSync(
    "bash",
    [
      "-c",
      '. "$1/fm-classify-lib.sh"\nscan_open_decisions "$2"',
      "fm-api-reads",
      BIN_DIR,
      stateDir,
    ],
    { encoding: "utf8", timeout: SCAN_TIMEOUT_MS, env: classifyEnv() }
  );
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || "scan_open_decisions failed").trim();
    throw new Error(detail);
  }
  const rows = [];
  for (const line of (result.stdout || "").split("\n")) {
    if (!line) continue;
    const row = parseScanLine(line);
    if (row) rows.push(row);
  }
  return rows;
}

function asItem(row) {
  return { task: row.task, key: row.key, summary: row.summary };
}

// --- captain-card options ---------------------------------------------------
//
// One owner of the board-card options contract. A writer of
// data/captain-queue.json and GET /captain-queue both use these helpers so a
// card cannot ship with empty, generic-letter, or jargon options.
// Each option is a short plain-English label naming the real choice.
// The recommended option is marked and comes first. A plain "Something else"
// may follow last. Generic "A" / "B" / "Option C" labels are refused.

const GENERIC_LETTER = /^(option\s+)?[A-Z]$/i;
const GENERIC_LETTER_PREFIX = /^(option\s+)?[A-Z]\s*[-.:)]\s*/i;
const JARGON = /\[key=|\bbin\/|\bneeds-decision\b|\.status\b|\.sh\b|\.mjs\b/i;
const SOMETHING_ELSE = /^something else$/i;
const RECOMMENDED_MARK = /\(\s*recommended\s*\)/i;

function textField(value) {
  return typeof value === "string" ? value.trim() : "";
}

function normalizedCaptainCardOptionLabels(options) {
  return (Array.isArray(options) ? options : [])
    .filter((raw) => typeof raw === "string")
    .map((raw) => raw.trim())
    .filter(Boolean);
}

export function normalizeCaptainCardOptions(options) {
  const labels = normalizedCaptainCardOptionLabels(options);
  const markedAt = labels.findIndex((label) => RECOMMENDED_MARK.test(label));
  if (markedAt > 0) {
    const [marked] = labels.splice(markedAt, 1);
    labels.unshift(marked);
  }
  const elseAt = labels.findIndex((label) => SOMETHING_ELSE.test(label));
  if (elseAt >= 0 && elseAt !== labels.length - 1) {
    const [escape] = labels.splice(elseAt, 1);
    labels.push(escape);
  }
  return labels;
}

export function captainCardOptionsError(options) {
  if (!Array.isArray(options) || options.length < 2) {
    return "card options must be at least two named choices";
  }
  const labels = [];
  for (const raw of options) {
    if (typeof raw !== "string") return "card options must be plain-English strings";
    const label = raw.trim();
    if (!label) return "card options cannot be empty";
    if (GENERIC_LETTER.test(label) || GENERIC_LETTER_PREFIX.test(label)) {
      return "card options cannot be generic letters";
    }
    if (JARGON.test(label)) return "card options cannot contain worker jargon";
    labels.push(label);
  }
  const named = labels.filter((label) => !SOMETHING_ELSE.test(label));
  if (named.length === 0) return "card options need a real named choice";
  if (SOMETHING_ELSE.test(labels[0])) return "Something else cannot be the recommended option";
  const marked = labels.filter((label) => RECOMMENDED_MARK.test(label));
  if (marked.length === 0) return "one option must be marked recommended";
  if (marked.length > 1) return "only one option can be marked recommended";
  if (!RECOMMENDED_MARK.test(labels[0])) {
    return "the recommended option must come first";
  }
  const elseAt = labels.findIndex((label) => SOMETHING_ELSE.test(label));
  if (elseAt >= 0 && elseAt !== labels.length - 1) {
    return "Something else must be last";
  }
  return null;
}

function captainQueueRecords(data) {
  const states = new Set(["open", "parked", "resolved"]);
  const normalize = (raw, fallbackState = "") => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
    const state = (textField(raw.state) || textField(raw.status) || fallbackState).toLowerCase();
    if (!states.has(state)) return null;
    return { ...raw, state };
  };
  if (Array.isArray(data.records)) {
    return data.records.map((row) => normalize(row)).filter((row) => row !== null);
  }
  return [
    ...(Array.isArray(data.items) ? data.items.map((row) => normalize(row, "open")) : []),
    ...(Array.isArray(data.parked) ? data.parked.map((row) => normalize(row, "parked")) : []),
    ...(Array.isArray(data.resolved) ? data.resolved.map((row) => normalize(row, "resolved")) : []),
  ].filter((row) => row !== null);
}

function asCaptainCard(raw, expectedState = "open") {
  if (!raw || typeof raw !== "object") return null;
  const id = textField(raw.id);
  const question = textField(raw.question);
  if (!id || !question) return null;
  const state = textField(raw.state).toLowerCase();
  if (state !== expectedState) return null;
  const options =
    expectedState === "open"
      ? normalizeCaptainCardOptions(raw.options)
      : Array.isArray(raw.options)
        ? [...raw.options]
        : [];
  const recommended =
    options.find((label) => typeof label === "string" && RECOMMENDED_MARK.test(label)) || "";
  if (expectedState === "open" && captainCardOptionsError(options)) return null;
  const num = typeof raw.num === "number" && Number.isFinite(raw.num) ? raw.num : 0;
  const generation =
    typeof raw.generation === "number" && Number.isInteger(raw.generation) && raw.generation > 0
      ? raw.generation
      : 1;
  const askedAt = textField(raw.asked_at) || textField(raw.askedAt);
  const commands = Array.isArray(raw.commands)
    ? raw.commands
        .filter((command) => typeof command === "string" && command.trim())
        .map((command) => command.trim())
    : [];
  const card = {
    id,
    num,
    generation,
    question,
    context: typeof raw.context === "string" ? raw.context : "",
    commands,
    options,
    recommended,
    askedAt,
    status: expectedState,
    project: textField(raw.project),
  };
  if (expectedState === "parked") {
    return {
      ...card,
      parkedAt: textField(raw.parked_at) || textField(raw.parkedAt),
      parkedReason: textField(raw.parked_reason) || textField(raw.parkedReason),
      parkedNote: textField(raw.parked_note) || textField(raw.parkedNote),
    };
  }
  return card;
}

function emptyCaptainQueue() {
  return { ok: true, updatedAt: "", items: [], parked: [] };
}

function captainQueueData(home) {
  const file = path.join(home, "data", "captain-queue.json");
  try {
    if (fs.lstatSync(file).isSymbolicLink()) return null;
  } catch (error) {
    if (error && error.code === "ENOENT") return null;
    throw error;
  }
  let raw;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch (error) {
    if (error && error.code === "ENOENT") return null;
    throw error;
  }
  try {
    const data = JSON.parse(raw);
    return data && typeof data === "object" && !Array.isArray(data) ? data : null;
  } catch {
    return null;
  }
}

export function captainQueueReplyTarget(home, id) {
  const data = captainQueueData(home);
  if (!data) return null;
  let target = null;
  for (const record of captainQueueRecords(data)) {
    if (textField(record.id) !== id) continue;
    const generation =
      typeof record.generation === "number" &&
      Number.isInteger(record.generation) &&
      record.generation > 0
        ? record.generation
        : 1;
    const stateRank = record.state === "resolved" ? 0 : 1;
    if (
      !target ||
      generation > target.generation ||
      (generation === target.generation && stateRank > target.stateRank)
    ) {
      target = {
        state: record.state,
        stateRank,
        generation,
        answer: typeof record.answer === "string" ? record.answer : "",
      };
    }
  }
  if (!target) return null;
  return { state: target.state, generation: target.generation, answer: target.answer };
}

export function captainQueueBody(home) {
  const data = captainQueueData(home);
  if (!data) return emptyCaptainQueue();
  const records = captainQueueRecords(data);
  const items = records
    .map((row) => asCaptainCard(row))
    .filter((card) => card !== null)
    .sort((a, b) => a.num - b.num || a.id.localeCompare(b.id));
  const parked = records
    .map((row) => asCaptainCard(row, "parked"))
    .filter((card) => card !== null)
    .sort((a, b) => a.num - b.num || a.id.localeCompare(b.id));
  return {
    ok: true,
    updatedAt: textField(data.updated_at) || textField(data.updatedAt),
    items,
    parked,
  };
}

export function blockedListBody(stateDir) {
  const blocked = scanOpenDecisions(stateDir)
    .filter((row) => row.verb === "blocked")
    .map(asItem);
  return { ok: true, blocked };
}

function asRungs(value) {
  const list = Array.isArray(value) ? value : value && typeof value === "object" ? [value] : [];
  const rungs = [];
  for (const raw of list) {
    if (!raw || typeof raw !== "object") continue;
    if (typeof raw.harness !== "string" || !raw.harness) continue;
    rungs.push({
      harness: raw.harness,
      model: typeof raw.model === "string" ? raw.model : "",
      effort: typeof raw.effort === "string" ? raw.effort : "",
      enabled: raw.enabled !== false,
    });
  }
  return rungs;
}

function asPin(value) {
  const pins = asRungs(value);
  return pins.length > 0 ? pins[0] : null;
}

export function assembleRigs(data) {
  const rigs = [];
  if (!data || typeof data !== "object") return rigs;
  const rules = Array.isArray(data.rules) ? data.rules : [];
  for (const rule of rules) {
    if (!rule || typeof rule !== "object") continue;
    const name = typeof rule.when === "string" ? rule.when : "";
    const dispatchClass = typeof rule.class === "string" ? rule.class : "";
    const rungs = asRungs(rule.use);
    if (!name && rungs.length === 0) continue;
    rigs.push({ name, class: dispatchClass, rungs, pin: asPin(rule.pin) });
  }
  const fallback = asRungs(data.default);
  if (fallback.length > 0) {
    rigs.push({ name: "default", class: DEFAULT_RIG_CLASS, rungs: fallback, pin: null });
  }
  return rigs;
}

// First non-empty non-comment line of a config file. Absent, unreadable, or
// symlinked files read as "".
function pinLine(file) {
  try {
    if (fs.lstatSync(file).isSymbolicLink()) return "";
  } catch {
    return "";
  }
  let raw;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch {
    return "";
  }
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    return trimmed;
  }
  return "";
}

export function rigsBody(home) {
  const config = path.join(home, "config");
  const file = path.join(config, "crew-dispatch.json");
  const crew = pinLine(path.join(config, "crew-harness"));
  const secondmate = pinLine(path.join(config, "secondmate-harness"));
  const empty = { ok: true, note: "", rigs: [], defaultPin: null, crew, secondmate };
  // A symlinked config is refused, not followed, the same posture as pinLine
  // and the brief reads. A missing file is the same empty answer.
  try {
    if (fs.lstatSync(file).isSymbolicLink()) return empty;
  } catch (error) {
    if (error && error.code === "ENOENT") return empty;
    throw error;
  }
  let raw;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch (error) {
    if (error && error.code === "ENOENT") return empty;
    throw error;
  }
  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    const err = new Error("invalid rig config");
    err.code = "INVALID_RIG_CONFIG";
    throw err;
  }
  return {
    ok: true,
    note: typeof data?.note === "string" ? data.note : "",
    rigs: assembleRigs(data),
    defaultPin: asPin(data?.defaultPin),
    crew,
    secondmate,
  };
}

// --- fleet enrich -----------------------------------------------------------
//
// GET /fleet serves fm-fleet-snapshot.sh --json plus one API-owned addition:
// task.enrich = { title, first_prompt, model, started_at, last_activity_at }.
// title falls back from the backlog record to the brief heading, first_prompt
// is the brief's "# Task" section capped at PROMPT_CAP, model is the task's
// meta model field, and the times come from the task's meta and status file
// stamps. The snapshot already carries each task's harness; model is not on
// the task row, so a board card reads it from here. Absent sources leave nulls.

const PROMPT_CAP = 6000;

// The `key=value` model line from a task's meta file, or "" when absent.
function metaModel(metaPath) {
  if (!metaPath) return "";
  let raw;
  try {
    const stat = fs.lstatSync(metaPath);
    if (!stat.isFile() || stat.isSymbolicLink()) return "";
    raw = fs.readFileSync(metaPath, "utf8");
  } catch {
    return "";
  }
  for (const line of raw.split(/\r?\n/)) {
    const at = line.indexOf("=");
    if (at > 0 && line.slice(0, at) === "model") return line.slice(at + 1).trim();
  }
  return "";
}

// Everything after the "# Task" heading up to the next top-level heading.
// Falls back to the whole file minus a leading top-level heading when there
// is no "# Task" section.
function briefTaskSection(raw) {
  const lines = raw.split("\n");
  const start = lines.findIndex((line) => /^#\s+Task\b/i.test(line));
  if (start >= 0) {
    let end = lines.length;
    for (let i = start + 1; i < lines.length; i += 1) {
      if (/^#\s/.test(lines[i])) {
        end = i;
        break;
      }
    }
    return lines.slice(start + 1, end).join("\n").trim();
  }
  return raw.replace(/^#\s+[^\n]*\n+/, "").trim();
}

function statTime(filePath, field) {
  try {
    const stats = fs.statSync(filePath);
    const time =
      field === "birth" && stats.birthtimeMs > 0 ? stats.birthtime : stats.mtime;
    return time.toISOString();
  } catch {
    return null;
  }
}

function enrichOneTask(task, dataRoot) {
  const enrich = {
    title: task?.backlog?.title ?? null,
    first_prompt: null,
    model: metaModel(task?.paths?.meta?.path),
    started_at: null,
    last_activity_at: null,
  };

  if (task?.id) {
    // Same posture as /tasks/<id>: a symlinked brief is refused, not followed.
    // A task id carrying ".." could point the brief path outside dataRoot, so
    // the resolved path is confirmed to stay inside it before any read.
    const briefFile = path.join(dataRoot, task.id, "brief.md");
    const rootPrefix = path.resolve(dataRoot) + path.sep;
    let raw = null;
    if (path.resolve(briefFile).startsWith(rootPrefix)) {
      try {
        const stat = fs.lstatSync(briefFile);
        raw = stat.isFile() && !stat.isSymbolicLink() ? fs.readFileSync(briefFile, "utf8") : null;
      } catch {
        raw = null;
      }
    }
    if (raw !== null) {
      const prompt = briefTaskSection(raw);
      if (prompt) {
        enrich.first_prompt =
          prompt.length > PROMPT_CAP ? `${prompt.slice(0, PROMPT_CAP)}\n…` : prompt;
      }
      if (!enrich.title) {
        const heading = raw.match(/^#\s+(.+)$/m);
        const headingText =
          heading && !/^task$/i.test(heading[1].trim()) ? heading[1].trim() : null;
        enrich.title = (headingText || prompt.split("\n")[0].replace(/^#+\s*/, "")).slice(0, 140);
      }
    }
  }

  const metaPath = task?.paths?.meta?.path;
  const statusPath = task?.paths?.status_log?.path;
  if (metaPath) enrich.started_at = statTime(metaPath, "birth");
  const activity = [
    statusPath ? statTime(statusPath, "mtime") : null,
    metaPath ? statTime(metaPath, "mtime") : null,
  ]
    .filter((value) => value !== null)
    .sort();
  if (activity.length) enrich.last_activity_at = activity[activity.length - 1];

  return enrich;
}

export function enrichFleetTasks(home, snapshot) {
  if (!snapshot || !Array.isArray(snapshot.tasks)) return snapshot;
  const dataRoot =
    (snapshot.roots && typeof snapshot.roots.data === "string" && snapshot.roots.data) ||
    path.join(home, "data");
  for (const task of snapshot.tasks) {
    if (task && typeof task === "object") task.enrich = enrichOneTask(task, dataRoot);
  }
  return snapshot;
}

// --- captain holds ----------------------------------------------------------
//
// GET /captain-holds serves the open captain-decision records, including the
// deferred records returned by `tasks-axi list --kind captain`. It reads each
// with `tasks-axi show <id> --full`. This is the one holds query the dashboard
// used to run itself; the API runs it now so no consumer parses tasks-axi
// output. bin/fm-api-server.mjs owns the response contract. Answer options are
// a consumer concern and stay out of that contract.

function tasksAxiEnv(home) {
  const env = {
    ...process.env,
    FM_HOME: home,
    FM_STATE_OVERRIDE: path.join(home, "state"),
    FM_DATA_OVERRIDE: path.join(home, "data"),
    FM_CONFIG_OVERRIDE: path.join(home, "config"),
    FM_PROJECTS_OVERRIDE: path.join(home, "projects"),
  };
  delete env.TASKS_AXI_FILE;
  return env;
}

function runTasksAxi(home, args) {
  return new Promise((resolve, reject) => {
    execFile(
      "tasks-axi",
      [...args, "--file", path.join(home, "data", "backlog.md")],
      { cwd: home, env: tasksAxiEnv(home), encoding: "utf8", timeout: TASKS_AXI_TIMEOUT_MS, maxBuffer: 8 * 1024 * 1024 },
      (error, stdout) => {
        if (error) reject(error);
        else resolve(String(stdout));
      },
    );
  });
}

// Ids from `tasks-axi list`, whose rows are two-space indented CSV.
function parseCaptainIdList(output) {
  const ids = [];
  for (const line of output.split("\n")) {
    const match = /^ {2}([a-z0-9][a-z0-9._-]*),/.exec(line);
    if (match) ids.push(match[1]);
  }
  return ids;
}

// One `key: value` line from `tasks-axi show --full`, quotes stripped, with the
// dash and "none" placeholders normalized to "".
function parseHoldField(line) {
  const match = /^\s*([a-z_]+):\s*(.*)$/.exec(line);
  if (!match) return null;
  let value = match[2].trim();
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    value = value.slice(1, -1);
  }
  return [match[1], value === "-" || value === "none" ? "" : value];
}

function parseHoldRecord(output) {
  const fields = new Map();
  for (const line of output.split("\n")) {
    const field = parseHoldField(line);
    if (field) fields.set(field[0], field[1]);
  }
  const id = fields.get("id");
  const title = fields.get("title");
  if (!id || !title) return null;

  const blockedBy = (fields.get("blocked_by") || "")
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
  const holdKind = fields.get("hold_kind") || "";
  const parked = holdKind === "parked" || holdKind === "future";

  return {
    id,
    title,
    reason: fields.get("hold_reason") || "",
    repo: fields.get("repo") || "",
    createdAt: fields.get("created") || "",
    blockedBy,
    hold_kind: holdKind,
    actionable: !parked && fields.get("blocked") !== "yes" && blockedBy.length === 0,
    parked,
    done: fields.get("state") === "done",
    answerable: !parked && id.includes("-decision-"),
  };
}

export async function captainHoldsBody(home) {
  let listing;
  try {
    listing = await runTasksAxi(home, ["list", "--kind", "captain"]);
  } catch {
    // tasks-axi absent or firstmate not set up: no holds, not an error, the
    // same posture the dashboard's own loader took.
    return { ok: true, holds: [] };
  }

  const ids = parseCaptainIdList(listing);
  const records = await Promise.all(
    ids.map(async (id) => {
      try {
        return parseHoldRecord(await runTasksAxi(home, ["show", id, "--full"]));
      } catch {
        return null;
      }
    }),
  );

  const holds = records
    .filter((hold) => hold !== null)
    // firstmate keeps resolved decisions in the captain listing; answering one
    // is refused, so a done hold is dropped rather than shown as open.
    .filter((hold) => !hold.done)
    .sort((a, b) => {
      if (a.actionable !== b.actionable) return a.actionable ? -1 : 1;
      return a.createdAt.localeCompare(b.createdAt);
    });
  return { ok: true, holds };
}
