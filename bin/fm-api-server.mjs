#!/usr/bin/env node
// Localhost HTTP server for one firstmate home.
//
// Bind 127.0.0.1 only. Port, home, state directory, and write-token file come
// from argv; this file has no default filesystem paths. bin/fm-api.sh owns
// process lifecycle and writes config/api-token on first start when absent.
// bin/fm-api-reads.mjs assembles the read windows from firstmate files.
// GET /fleet runs bin/fm-fleet-snapshot.sh --json from this file's directory.
//
// GET /health
//   { ok, version, home }
// GET /fleet
//   fm-fleet-snapshot.v1 JSON from bin/fm-fleet-snapshot.sh --json, plus one
//   API-owned addition per task: enrich (bin/fm-api-reads.mjs owns its shape).
//   Empty home: empty fleet, not an error. The script's header owns the rest.
// GET /tasks/<id>
//   One task's brief, status timeline (with observed times), current stage,
//   meta runtime, and worker activity.
//   Unknown id: JSON 404 { ok: false, error: "task not found" }.
//   bin/fm-api-task-detail.mjs owns the exact success JSON contract.
// GET /captain-queue
//   { ok, updatedAt, items: [{ id, num, question, context, commands,
//   options, recommended, askedAt, status, project }] }
//   Captain-queue.json cards firstmate escalated to the captain, open only,
//   with named options already validated. A worker needs-decision is not a
//   source. Empty home or missing file: items is [].
// GET /captain-holds
//   { ok, holds: [{ id, title, reason, repo, createdAt, blockedBy,
//   hold_kind, actionable, parked, done, answerable }] }
//   The captain-kind decisions from tasks-axi, read in full and sorted
//   actionable-first. Parked and future rows remain present with parked true
//   and actionable and answerable false. tasks-axi absent: holds is [].
// GET /blocked
//   { ok, blocked: [{ task, key, summary }] }
//   Blocked tasks still open in this home. Empty home: blocked is [].
// GET /rigs
//   { ok, note, rigs: [{ name, class, rungs: [{ harness, model, effort,
//   enabled }], pin }], defaultPin, crew, secondmate }
//   Dispatch pools, each rung's enabled state, the dispatch note, per-rig and
//   default pins, and the raw crew/secondmate pin lines. Missing config:
//   rigs is [] and the extras are empty.
// GET /events
//   Server-sent event stream of typed home changes. Event timing comes from
//   FM_API_EVENT_QUIET_MS, FM_API_EVENT_DEADLINE_MS, and FM_API_HEARTBEAT_MS;
//   docs/configuration.md owns the public stream contract.
// POST /captain-notes requires Authorization: Bearer <token> and queues a
// captain note for firstmate on the wake queue, encoded as operational input.
// The task may be live or may exist only in the backlog. Reads need no token.
// A captain note never closes a durable captain decision.
// POST /workers/relay requires the token; body { task, text }. Queues a steer
//   for firstmate to pass to the worker word for word on its next turn. Use it
//   for a worker that is not parked on a decision; a keyed answer that closes a
//   decision uses /decisions/answer. Unknown task: 404. Bad body: 400.
// POST /decisions/answer requires the token; body { task, key, text }. Queues
//   an answer for firstmate on the same relay, which runs
//   bin/fm-send.sh <task> --resolve-key <key> '<text>' on its next turn to
//   close the active durable decision. Unknown task: 404. Bad body: 400.
// POST /rigs/rung requires the token; body { rig, rung, enabled }. Sets a
//   rung's enabled state in config/crew-dispatch.json, where rig is the rule's
//   `class` or "__default__" and rung is its index. A change that would turn
//   off a ladder's last enabled rung is refused 400. Unknown rig/rung: 404.
// GET /rigs/config returns the exact dispatch config file as { ok, config }, so
//   the routing editor edits the whole file and loses no field GET /rigs drops
//   (like each rule's `why`). Missing or symlinked file: config is null. No token.
// POST /rigs/config requires the token; body is a whole dispatch config object.
//   Writes it to config/crew-dispatch.json (creating the file if absent), after
//   checking every present ladder keeps at least one enabled rung. Default is
//   optional; when the key is absent it is not required. Bad body or a broken
//   ladder is refused 400. This is the routing editor's save door.

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFile, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  blockedListBody,
  captainHoldsBody,
  captainQueueBody,
  DEFAULT_RIG_CLASS,
  enrichFleetTasks,
  rigsBody,
} from "./fm-api-reads.mjs";
import { taskDetailBody } from "./fm-api-task-detail.mjs";

export const API_VERSION = "1";
const BIN_DIR = path.dirname(fileURLToPath(import.meta.url));
const SNAPSHOT_SCRIPT = path.join(BIN_DIR, "fm-fleet-snapshot.sh");
const MAX_BODY_BYTES = 16384;
// A whole dispatch config can be larger than a one-line write body.
const MAX_CONFIG_BYTES = 65536;
const MAX_NOTE_TEXT = 2000;
const NOTE_KIND = "away-supervisor";
const TASK_SLUG = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
// The same key charset fm-send.sh accepts for --resolve-key.
const DECISION_KEY = /^[A-Za-z0-9._-]{1,128}$/;
const ENDED_VERBS = new Set(["done", "closed", "cancelled"]);

const EVENT_QUIET_MS = 100;
const EVENT_DEADLINE_MS = 1000;
const HEARTBEAT_MS = 15000;

function parseArguments(argv) {
  const result = { home: "", port: "", state: "", sessionPid: "", tokenFile: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (
      name === "--home" ||
      name === "--port" ||
      name === "--state" ||
      name === "--session-pid" ||
      name === "--token-file"
    ) {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      const key =
        name === "--session-pid" ? "sessionPid" : name === "--token-file" ? "tokenFile" : name.slice(2);
      result[key] = argv[i + 1];
      i += 1;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function parsePort(value) {
  if (!/^[0-9]+$/.test(value)) throw new Error(`port must be an integer: ${value}`);
  const port = Number(value);
  if (port < 0 || port > 65535) throw new Error(`port out of range: ${value}`);
  return port;
}

function parseSessionPid(value) {
  if (!value) return 0;
  if (!/^[1-9][0-9]*$/.test(value)) throw new Error(`session pid must be a positive integer: ${value}`);
  return Number(value);
}

function durationFromEnvironment(name, fallback) {
  const value = process.env[name];
  if (value === undefined || value === "") return fallback;
  if (!/^[1-9][0-9]*$/.test(value)) throw new Error(`${name} must be a positive integer`);
  return Number(value);
}

function json(res, status, body) {
  const payload = `${JSON.stringify(body)}\n`;
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

function sendGet(req, res, body) {
  if (req.method === "HEAD") {
    res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
    res.end();
    return;
  }
  json(res, 200, body);
}

function snapshotEnv(home) {
  return {
    ...process.env,
    FM_HOME: home,
    FM_STATE_OVERRIDE: path.join(home, "state"),
    FM_DATA_OVERRIDE: path.join(home, "data"),
    FM_CONFIG_OVERRIDE: path.join(home, "config"),
    FM_PROJECTS_OVERRIDE: path.join(home, "projects"),
  };
}

function sendFleetSnapshot(req, res, home) {
  execFile(
    SNAPSHOT_SCRIPT,
    ["--json"],
    { env: snapshotEnv(home), maxBuffer: 8 * 1024 * 1024 },
    (error, stdout) => {
      if (res.headersSent) return;
      if (error) {
        process.stderr.write(`fleet snapshot failed: ${error.message}\n`);
        json(res, 500, { ok: false, error: "fleet snapshot failed" });
        return;
      }
      let snapshot;
      try {
        snapshot = JSON.parse(String(stdout));
      } catch {
        process.stderr.write("fleet snapshot failed: invalid json\n");
        json(res, 500, { ok: false, error: "fleet snapshot failed" });
        return;
      }
      const payload = Buffer.from(`${JSON.stringify(enrichFleetTasks(home, snapshot))}\n`);
      res.writeHead(200, {
        "Content-Type": "application/json; charset=utf-8",
        "Content-Length": payload.length,
      });
      res.end(req.method === "HEAD" ? undefined : payload);
    },
  );
}

function readTokenFile(tokenFile) {
  try {
    if (fs.lstatSync(tokenFile).isSymbolicLink()) return "";
    return fs.readFileSync(tokenFile, "utf8");
  } catch {
    return "";
  }
}

function readWriteToken(tokenFile) {
  if (!tokenFile) return "";
  return (
    readTokenFile(tokenFile)
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find((line) => line && !line.startsWith("#")) || ""
  );
}

function bearerToken(req) {
  const header = req.headers.authorization;
  if (typeof header !== "string") return "";
  const match = header.match(/^Bearer[ \t]+(\S+)\s*$/i);
  return match ? match[1] : "";
}

function tokensEqual(left, right) {
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  if (a.length === 0 || a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

function writeAuthorized(req, tokenFile) {
  const expected = readWriteToken(tokenFile);
  const provided = bearerToken(req);
  return expected.length > 0 && tokensEqual(expected, provided);
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        req.destroy();
        const error = new Error("body too large");
        error.status = 400;
        reject(error);
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function taskExists(home, task) {
  const status = path.join(home, "state", `${task}.status`);
  const meta = path.join(home, "state", `${task}.meta`);
  const brief = path.join(home, "data", task, "brief.md");
  return fs.existsSync(status) || fs.existsSync(meta) || fs.existsSync(brief);
}

// Whether the task is a record in the captain backlog, even if it has no live
// state/meta/brief files. A parked captain task (a hold with no running worker)
// lives only as a backlog line, so a captain note about it must still be
// accepted. Matches a "- [ ] <id> - " or "- [x] <id> - " record line.
function taskInBacklog(home, task) {
  const backlog = path.join(home, "data", "backlog.md");
  let text;
  try {
    text = fs.readFileSync(backlog, "utf8");
  } catch {
    return false;
  }
  const escaped = task.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`^- \\[[ xX]\\] ${escaped} - `, "m").test(text);
}

function latestStatusVerb(home, task) {
  const dest = path.join(home, "state", `${task}.status`);
  let text;
  try {
    text = fs.readFileSync(dest, "utf8");
  } catch {
    return "";
  }
  const lines = text.split(/\n/).map((line) => line.trim()).filter(Boolean);
  if (!lines.length) return "";
  return lines[lines.length - 1].split(":")[0].trim();
}

function noteState(verb) {
  if (verb === "failed") return "failed";
  if (ENDED_VERBS.has(verb)) return "finished";
  return "running";
}

function httpError(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}

function withHttpError(action, status, message) {
  try {
    return action();
  } catch {
    throw httpError(status, message);
  }
}

function parseJson(raw, malformedError) {
  try {
    return JSON.parse(raw);
  } catch {
    throw malformedError();
  }
}

function parseJsonObject(raw) {
  const body = parseJson(raw, () => httpError(400, "malformed json"));
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw httpError(400, "malformed json");
  }
  return body;
}

function taskTextFields(body) {
  const { task, text } = body;
  if (typeof task !== "string" || !TASK_SLUG.test(task)) {
    throw httpError(400, "invalid task");
  }
  if (typeof text !== "string" || !text.trim()) {
    throw httpError(400, "missing text");
  }
  if (/[\r\n\u2028\u2029]/.test(text)) {
    throw httpError(400, "text must be one line");
  }
  if (text.length > MAX_NOTE_TEXT) {
    throw httpError(400, "text too long");
  }
  return { task, text };
}

// Parse a { task, text } write body: a valid task slug and one line of text
// within the length cap. Shared by the captain-note and worker-relay writes.
function parseTaskText(raw) {
  return taskTextFields(parseJsonObject(raw));
}

function runCommand(command, args, options = {}) {
  const { stdin, env, timeoutMs = 10000 } = options;
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      env: env ? { ...process.env, ...env } : process.env,
    });
    const out = [];
    const err = [];
    let settled = false;
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
    }, timeoutMs);
    child.stdout.on("data", (chunk) => out.push(chunk));
    child.stderr.on("data", (chunk) => err.push(chunk));
    child.on("error", (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({
        code: code ?? 1,
        stdout: Buffer.concat(out).toString("utf8"),
        stderr: Buffer.concat(err).toString("utf8"),
      });
    });
    if (stdin == null) child.stdin.end();
    else child.stdin.end(stdin);
  });
}

async function encodeOperationalInput(body) {
  const result = await runCommand(path.join(BIN_DIR, "fm-operational-input.sh"), ["encode", NOTE_KIND], {
    stdin: body,
  });
  const encoded = result.stdout.replace(/\n+$/, "");
  if (result.code !== 0 || !encoded) {
    throw new Error("encode failed");
  }
  return encoded;
}

async function enqueueCheckWake(home, stateDir, key, payload) {
  const state = stateDir || path.join(home, "state");
  const script = 'set -eu\n. "$1"\nfm_wake_append check "$WAKE_KEY" "$WAKE_PAYLOAD"\n';
  const result = await runCommand("bash", ["-c", script, "wake-append", path.join(BIN_DIR, "fm-wake-lib.sh")], {
    env: {
      FM_HOME: home,
      FM_STATE_OVERRIDE: state,
      FM_WAKE_QUEUE: path.join(state, ".wake-queue"),
      FM_WAKE_QUEUE_LOCK: path.join(state, ".wake-queue.lock"),
      WAKE_KEY: key,
      WAKE_PAYLOAD: payload,
    },
  });
  if (result.code !== 0) throw new Error("wake append failed");
}

async function queueCaptainNote(home, stateDir, note) {
  const state = noteState(latestStatusVerb(home, note.task));
  const body = `captain-note on ${state} task ${note.task}: ${note.text}`;
  const encoded = await encodeOperationalInput(body);
  const key = `captain-note:${note.task}:${crypto.randomBytes(8).toString("hex")}`;
  await enqueueCheckWake(home, stateDir, key, `check: captain-note: ${encoded}`);
}

function handleAuthorizedPost(req, res, options, maxBytes, action) {
  if (req.method !== "POST") {
    req.resume();
    json(res, 405, { ok: false, error: "method not allowed" });
    return;
  }
  if (!writeAuthorized(req, options.tokenFile)) {
    req.resume();
    json(res, 401, { ok: false, error: "unauthorized" });
    return;
  }
  readBody(req, maxBytes)
    .then(action)
    .then((body) => json(res, 200, body || { ok: true }))
    .catch((error) => {
      if (res.headersSent) {
        res.destroy();
        return;
      }
      const status = error && error.status ? error.status : 500;
      json(res, status, { ok: false, error: status === 500 ? "failed" : error.message });
    });
}

function handleCaptainNote(req, res, home, options) {
  handleAuthorizedPost(req, res, options, MAX_BODY_BYTES, async (raw) => {
    const note = parseTaskText(raw);
    // A note may be about a live task or a parked captain hold that lives only
    // in the backlog, so accept either. The relay and answer writes stay
    // strict: they need a live task or an open decision.
    if (!taskExists(home, note.task) && !taskInBacklog(home, note.task)) {
      throw httpError(404, "not found");
    }
    await queueCaptainNote(home, options.stateDir, note);
  });
}

// A worker relay rides the same relay as a captain note, but its body tells
// firstmate to pass the text through to the worker word for word, rather than
// read it as a note to itself. This is the plain steer for a worker that is
// not parked on a decision; a keyed answer uses POST /decisions/answer.
async function queueWorkerRelay(home, stateDir, relay) {
  const body = `captain-relay to worker ${relay.task}: ${relay.text}`;
  const encoded = await encodeOperationalInput(body);
  const key = `worker-relay:${relay.task}:${crypto.randomBytes(8).toString("hex")}`;
  await enqueueCheckWake(home, stateDir, key, `check: worker-relay: ${encoded}`);
}

function handleWorkerRelay(req, res, home, options) {
  handleAuthorizedPost(req, res, options, MAX_BODY_BYTES, async (raw) => {
    const relay = parseTaskText(raw);
    if (!taskExists(home, relay.task)) throw httpError(404, "not found");
    await queueWorkerRelay(home, options.stateDir, relay);
  });
}

function parseDecisionAnswer(raw) {
  const body = parseJsonObject(raw);
  const { task, text } = taskTextFields(body);
  const key = body.key;
  if (typeof key !== "string" || !DECISION_KEY.test(key)) {
    throw httpError(400, "invalid key");
  }
  return { task, key, text };
}

// An answer rides the same operational-input relay as a captain note: this
// server never types into a crewmate pane (it does not know the pane id).
// Firstmate reads the queued line on its next supervision turn and runs
// bin/fm-send.sh <task> --resolve-key <key> '<answer>' itself, which is the
// close command fm-wake-drain prints for every open decision.
async function queueDecisionAnswer(home, stateDir, answer) {
  const body = `answer decision [key=${answer.key}] on task ${answer.task} with: ${answer.text}`;
  const encoded = await encodeOperationalInput(body);
  const key = `decision-answer:${answer.task}:${crypto.randomBytes(8).toString("hex")}`;
  await enqueueCheckWake(home, stateDir, key, `check: decision-answer: ${encoded}`);
}

function handleDecisionAnswer(req, res, home, options) {
  handleAuthorizedPost(req, res, options, MAX_BODY_BYTES, async (raw) => {
    const answer = parseDecisionAnswer(raw);
    if (!taskExists(home, answer.task)) throw httpError(404, "not found");
    await queueDecisionAnswer(home, options.stateDir, answer);
  });
}

function parseRungToggle(raw) {
  const body = parseJsonObject(raw);
  const rig = body.rig;
  const rung = body.rung;
  const enabled = body.enabled;
  if (typeof rig !== "string" || !rig) {
    throw httpError(400, "invalid rig");
  }
  if (typeof rung !== "number" || !Number.isInteger(rung) || rung < 0) {
    throw httpError(400, "invalid rung");
  }
  if (typeof enabled !== "boolean") {
    throw httpError(400, "invalid enabled");
  }
  return { rig, rung, enabled };
}

// The list of rung objects for one ladder: the fallback ("__default__") is the
// top-level `default`, every other rig is the `use` of the rule whose `class`
// matches. A single-object `use` counts as a one-rung list. Returns null when
// the named rig is not in the config.
function ladderList(config, rig) {
  if (rig === DEFAULT_RIG_CLASS) {
    if (Array.isArray(config.default)) return config.default;
    if (config.default && typeof config.default === "object") return [config.default];
    return null;
  }
  if (!Array.isArray(config.rules)) return null;
  for (const rule of config.rules) {
    if (!rule || typeof rule !== "object") continue;
    if (rule.class !== rig) continue;
    if (Array.isArray(rule.use)) return rule.use;
    if (rule.use && typeof rule.use === "object") return [rule.use];
    return [];
  }
  return null;
}

function rungEnabled(rung) {
  return Boolean(rung) && typeof rung === "object" && rung.enabled !== false;
}

// Set enabled on the rung at `index` in `list`, refusing a change that would
// leave the ladder with no enabled rung. Returns { error } or the new list.
function setRungEnabled(list, index, enabled) {
  if (index >= list.length) return { error: "rung not found" };
  const target = list[index];
  if (!target || typeof target !== "object") return { error: "rung not found" };
  const next = list.map((rung, i) => {
    if (i !== index) return rung;
    const copy = { ...rung };
    if (enabled) delete copy.enabled;
    else copy.enabled = false;
    return copy;
  });
  if (!next.some(rungEnabled)) {
    return { error: "can't turn off the last enabled rung" };
  }
  return { list: next };
}

// Apply a rung toggle to the parsed crew-dispatch config, returning the new
// config or { error }. Ported from the dashboard's applyRungEnabled so the
// config owner enforces the same last-rung-on rule.
function applyRungToggle(config, toggle) {
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    return { error: "dispatch file is not valid json" };
  }
  const list = ladderList(config, toggle.rig);
  if (list === null) return { error: "rig not found" };
  const next = setRungEnabled(list, toggle.rung, toggle.enabled);
  if ("error" in next) return next;
  if (toggle.rig === DEFAULT_RIG_CLASS) {
    return { config: { ...config, default: next.list } };
  }
  const rules = config.rules.map((rule) => {
    if (!rule || typeof rule !== "object" || rule.class !== toggle.rig) return rule;
    return { ...rule, use: next.list };
  });
  return { config: { ...config, rules } };
}

function readDispatchConfig(home) {
  const file = path.join(home, "config", "crew-dispatch.json");
  const state = dispatchFileState(file);
  if (state === "missing") throw httpError(404, "rig not found");
  if (state === "symlink") throw httpError(400, "dispatch file is a symlink");
  const raw = readFileOrNull(file);
  if (raw === null) throw httpError(404, "rig not found");
  const config = parseJson(raw, () => httpError(400, "dispatch file is not valid json"));
  return { file, config };
}

function writeDispatchConfig(file, config) {
  const payload = `${JSON.stringify(config, null, 2)}\n`;
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, payload);
  fs.renameSync(tmp, file);
}

function handleRungToggle(req, res, home, options) {
  handleAuthorizedPost(req, res, options, MAX_BODY_BYTES, (raw) => {
    const toggle = parseRungToggle(raw);
    const { file, config } = readDispatchConfig(home);
    const next = applyRungToggle(config, toggle);
    if ("error" in next) {
      const notFound = next.error === "rig not found" || next.error === "rung not found";
      throw httpError(notFound ? 404 : 400, next.error);
    }
    writeDispatchConfig(file, next.config);
    return { ok: true, rig: toggle.rig, rung: toggle.rung, enabled: toggle.enabled };
  });
}

// Every present ladder in a dispatch config (each rule's `use`, and `default`
// when that key is an array or object) must keep at least one enabled rung,
// and must name at least one. A config with only rules and no default is legal.
// This mirrors the invariant the single-rung toggle enforces, applied to a
// whole config the dashboard's routing editor sends at once.
function validateDispatchConfig(config) {
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    return { error: "config must be a json object" };
  }
  // A present but wrong-typed rules or default would be silently skipped below
  // and then written, so reject it rather than persist a config off-schema.
  if ("rules" in config && !Array.isArray(config.rules)) {
    return { error: "rules must be an array" };
  }
  if (
    "default" in config &&
    !Array.isArray(config.default) &&
    !(config.default && typeof config.default === "object")
  ) {
    return { error: "default must be an array or object" };
  }
  const ladders = [];
  if (Array.isArray(config.rules)) {
    for (const rule of config.rules) {
      if (!rule || typeof rule !== "object") return { error: "a routing rule is not an object" };
      if (typeof rule.when !== "string" || !rule.when.trim()) {
        return { error: "a routing rule is missing its when line" };
      }
      ladders.push({ label: rule.when, list: asList(rule.use) });
    }
  }
  if (Array.isArray(config.default) || (config.default && typeof config.default === "object")) {
    ladders.push({ label: "default", list: asList(config.default) });
  }
  for (const ladder of ladders) {
    if (ladder.list.length === 0) return { error: `${ladder.label} needs at least one rung` };
    if (!ladder.list.some(rungEnabled)) {
      return { error: `${ladder.label} needs at least one enabled rung` };
    }
  }
  return { ok: true };
}

function asList(value) {
  if (Array.isArray(value)) return value;
  if (value && typeof value === "object") return [value];
  return [];
}

function parseDispatchConfig(raw) {
  const body = parseJsonObject(raw);
  const check = validateDispatchConfig(body);
  if ("error" in check) throw httpError(400, check.error);
  return body;
}

// Refuse a symlinked dispatch file the same way readDispatchConfig does, but
// allow a missing file: saving a whole config may create it.
function dispatchFileForWrite(home) {
  const file = path.join(home, "config", "crew-dispatch.json");
  if (dispatchFileState(file) === "symlink") throw httpError(400, "dispatch file is a symlink");
  return file;
}

function dispatchFileState(file) {
  try {
    return fs.lstatSync(file).isSymbolicLink() ? "symlink" : "file";
  } catch (error) {
    if (error && error.code === "ENOENT") return "missing";
    throw error;
  }
}

function readFileOrNull(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch (error) {
    if (error && error.code === "ENOENT") return null;
    throw error;
  }
}

function invalidRigConfigError() {
  const error = new Error("invalid rig config");
  error.code = "INVALID_RIG_CONFIG";
  return error;
}

// The exact dispatch config, so the routing editor can read the whole file
// (every field, including each rule's `why`), edit it, and save it back through
// POST /rigs/config without losing keys that GET /rigs does not carry. Missing
// or symlinked file answers { ok: true, config: null }, the same refusal
// posture as the reads. Needs no token; the read is open like GET /rigs.
function rawDispatchBody(home) {
  const file = path.join(home, "config", "crew-dispatch.json");
  if (dispatchFileState(file) !== "file") return { ok: true, config: null };
  const raw = readFileOrNull(file);
  if (raw === null) return { ok: true, config: null };
  return { ok: true, config: parseJson(raw, invalidRigConfigError) };
}

function sendRawDispatch(req, res, home) {
  try {
    sendGet(req, res, rawDispatchBody(home));
  } catch (error) {
    if (error && error.code === "INVALID_RIG_CONFIG") {
      json(res, 500, { ok: false, error: "invalid rig config" });
      return;
    }
    throw error;
  }
}

function handleRigConfig(req, res, home, options) {
  if (req.method === "GET" || req.method === "HEAD") {
    sendRawDispatch(req, res, home);
    return;
  }
  handleAuthorizedPost(req, res, options, MAX_CONFIG_BYTES, (raw) => {
    const config = parseDispatchConfig(raw);
    const file = dispatchFileForWrite(home);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    writeDispatchConfig(file, config);
  });
}

function handleTaskDetail(req, res, home, stateDir, task) {
  taskDetailBody(home, task, { stateDir })
    .then((body) => {
      if (!body) {
        json(res, 404, { ok: false, error: "task not found" });
        return;
      }
      sendGet(req, res, body);
    })
    .catch((error) => {
      process.stderr.write(`task detail failed for ${task}: ${error.message}\n`);
      if (!res.headersSent) json(res, 500, { ok: false, error: "task detail failed" });
    });
}

const READ_PATHS = new Set([
  "/health",
  "/fleet",
  "/captain-queue",
  "/captain-holds",
  "/blocked",
  "/rigs",
]);

function requestTarget(req) {
  const url = withHttpError(
    () => new URL(req.url || "/", "http://127.0.0.1"),
    400,
    "malformed url",
  );
  const match = url.pathname.match(/^\/tasks\/([^/]+)$/);
  if (!match) return { url, task: null };
  const task = withHttpError(() => decodeURIComponent(match[1]), 400, "malformed url");
  if (!TASK_SLUG.test(task)) throw httpError(404, "task not found");
  return { url, task };
}

function sendCaptainHolds(req, res, home) {
  if (req.method === "HEAD") {
    sendGet(req, res, { ok: true, holds: [] });
    return;
  }
  captainHoldsBody(home)
    .then((body) => json(res, 200, body))
    .catch((error) => {
      process.stderr.write(`captain holds failed: ${error.message}\n`);
      if (!res.headersSent) json(res, 500, { ok: false, error: "captain holds failed" });
    });
}

function sendRigs(req, res, home) {
  try {
    sendGet(req, res, rigsBody(home));
  } catch (error) {
    if (error && error.code === "INVALID_RIG_CONFIG") {
      json(res, 500, { ok: false, error: "invalid rig config" });
      return;
    }
    throw error;
  }
}

function handleReadRoute(req, res, home, stateDir, pathname, task) {
  const routes = {
    "/health": () => sendGet(req, res, { ok: true, version: API_VERSION, home }),
    "/captain-queue": () => sendGet(req, res, captainQueueBody(home)),
    "/captain-holds": () => sendCaptainHolds(req, res, home),
    "/blocked": () => sendGet(req, res, blockedListBody(stateDir)),
    "/rigs": () => sendRigs(req, res, home),
    "/fleet": () => sendFleetSnapshot(req, res, home),
  };
  const route = routes[pathname];
  if (route) {
    route();
    return true;
  }
  if (task === null) return false;
  handleTaskDetail(req, res, home, stateDir, task);
  return true;
}

function handleWriteRoute(req, res, home, options, pathname) {
  const routes = {
    "/captain-notes": () => handleCaptainNote(req, res, home, options),
    "/workers/relay": () => handleWorkerRelay(req, res, home, options),
    "/decisions/answer": () => handleDecisionAnswer(req, res, home, options),
    "/rigs/rung": () => handleRungToggle(req, res, home, options),
    "/rigs/config": () => handleRigConfig(req, res, home, options),
  };
  const route = routes[pathname];
  if (!route) return false;
  route();
  return true;
}

function handle(req, res, home, options, events) {
  const stateDir = options.stateDir || path.join(home, "state");
  let target;
  try {
    target = requestTarget(req);
  } catch (error) {
    json(res, error.status || 500, { ok: false, error: error.status ? error.message : "failed" });
    return;
  }
  const { url, task } = target;
  if ((READ_PATHS.has(url.pathname) || task !== null) && req.method !== "GET" && req.method !== "HEAD") {
    json(res, 405, { ok: false, error: "method not allowed" });
    return;
  }
  if (handleReadRoute(req, res, home, stateDir, url.pathname, task)) return;
  if (handleWriteRoute(req, res, home, options, url.pathname)) return;
  if (url.pathname === "/events") {
    if (req.method !== "GET") {
      json(res, 405, { ok: false, error: "method not allowed" });
      return;
    }
    events.subscribe(req, res);
    return;
  }
  json(res, 404, { ok: false, error: "not found" });
}

function eventForPath(relativePath) {
  const parts = relativePath.split("/");
  if (parts.some((part) => part.startsWith("."))) return null;

  let match = relativePath.match(/^state\/([^/]+)\.status$/);
  if (match) return { type: "task-status", task: match[1] };

  match = relativePath.match(/^state\/([^/]+)\.meta$/);
  if (match) return { type: "task-created", task: match[1] };

  if (relativePath === "data/backlog.md" || relativePath === "data/captain-queue.json") {
    return { type: "captain-queue" };
  }
  if (relativePath === "config/crew-dispatch.json") return { type: "rig-config" };
  return { type: "changed" };
}

function createEventClients(heartbeatMs, onEmpty) {
  const clients = new Set();
  let heartbeatTimer;

  function removeClient(res) {
    if (!clients.delete(res) || clients.size > 0) return;
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    heartbeatTimer = undefined;
    onEmpty();
  }

  function write(frame) {
    for (const res of clients) {
      if (res.destroyed || res.writableEnded) {
        removeClient(res);
        continue;
      }
      try {
        res.write(frame);
      } catch {
        removeClient(res);
      }
    }
  }

  function subscribe(req, res) {
    res.writeHead(200, {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
    });
    if (typeof res.flushHeaders === "function") res.flushHeaders();
    res.write(": connected\n\n");
    req.socket.setKeepAlive(true);
    clients.add(res);

    const disconnect = () => removeClient(res);
    req.once("close", disconnect);
    res.once("close", disconnect);
    res.once("error", disconnect);

    if (heartbeatTimer) return;
    heartbeatTimer = setInterval(() => {
      if (clients.size === 0) return;
      write(`: heartbeat ${new Date().toISOString()}\n\n`);
    }, heartbeatMs);
    heartbeatTimer.unref();
  }

  function close() {
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    heartbeatTimer = undefined;
    for (const res of clients) res.end();
    clients.clear();
  }

  return {
    get size() {
      return clients.size;
    },
    subscribe,
    write,
    close,
  };
}

function eventFrame(change) {
  const body = {
    type: change.type,
    ...(change.task ? { task: change.task } : {}),
    timestamp: change.timestamp,
  };
  return `event: ${change.type}\ndata: ${JSON.stringify(body)}\n\n`;
}

function createEventBatch(quietMs, deadlineMs, emit) {
  const pending = new Map();
  let quietTimer;
  let deadlineTimer;

  function clearTimers() {
    if (quietTimer) clearTimeout(quietTimer);
    if (deadlineTimer) clearTimeout(deadlineTimer);
    quietTimer = undefined;
    deadlineTimer = undefined;
  }

  function clear() {
    clearTimers();
    pending.clear();
  }

  function flush() {
    clearTimers();
    const changes = [...pending.values()];
    pending.clear();
    for (const change of changes) emit(eventFrame(change));
  }

  function record(change) {
    const key = `${change.type}\0${change.task || ""}`;
    pending.set(key, { ...change, timestamp: new Date().toISOString() });
    if (quietTimer) clearTimeout(quietTimer);
    quietTimer = setTimeout(flush, quietMs);
    quietTimer.unref();
    if (!deadlineTimer) {
      deadlineTimer = setTimeout(flush, deadlineMs);
      deadlineTimer.unref();
    }
  }

  return { clear, record };
}

function watchHome(home, record) {
  const watchers = [];

  function watchDirectory(name) {
    const directory = path.join(home, name);
    fs.mkdirSync(directory, { recursive: true });
    const watcher = fs.watch(directory, { recursive: true, encoding: "utf8" }, (_eventType, filename) => {
      if (!filename) return;
      const absolute = path.resolve(directory, filename);
      const relative = path.relative(home, absolute);
      if (relative.startsWith("..") || path.isAbsolute(relative)) return;
      record(relative.split(path.sep).join("/"));
    });
    watcher.on("error", (error) => {
      process.stderr.write(`event watcher ${name}: ${error.message}\n`);
    });
    watchers.push(watcher);
  }

  for (const name of ["state", "data", "config"]) watchDirectory(name);
  return watchers;
}

function createEventStream(home) {
  const quietMs = durationFromEnvironment("FM_API_EVENT_QUIET_MS", EVENT_QUIET_MS);
  const deadlineMs = durationFromEnvironment("FM_API_EVENT_DEADLINE_MS", EVENT_DEADLINE_MS);
  const heartbeatMs = durationFromEnvironment("FM_API_HEARTBEAT_MS", HEARTBEAT_MS);
  if (deadlineMs < quietMs) {
    throw new Error("FM_API_EVENT_DEADLINE_MS must be at least FM_API_EVENT_QUIET_MS");
  }

  let batch;
  const clients = createEventClients(heartbeatMs, () => batch.clear());
  batch = createEventBatch(quietMs, deadlineMs, (frame) => clients.write(frame));
  let closed = false;
  const watchers = watchHome(home, (relativePath) => {
    if (closed || clients.size === 0) return;
    const change = eventForPath(relativePath);
    if (change) batch.record(change);
  });

  return {
    subscribe(req, res) {
      if (closed) {
        res.destroy();
        return;
      }
      clients.subscribe(req, res);
    },
    close() {
      if (closed) return;
      closed = true;
      batch.clear();
      for (const watcher of watchers) watcher.close();
      clients.close();
    },
  };
}

function writePortFile(stateDir, port) {
  if (!stateDir) return;
  fs.mkdirSync(stateDir, { recursive: true });
  const dest = path.join(stateDir, ".api.port");
  const tmp = `${dest}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${port}\n`);
  fs.renameSync(tmp, dest);
}

function removePortFile(stateDir) {
  if (!stateDir) return;
  try {
    fs.unlinkSync(path.join(stateDir, ".api.port"));
  } catch (error) {
    if (error && error.code !== "ENOENT") throw error;
  }
}

function sessionPidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function lockHolderAlive(stateDir) {
  if (!stateDir) return false;
  try {
    const raw = fs.readFileSync(path.join(stateDir, ".lock"), "utf8").trim();
    if (!/^[1-9][0-9]*$/.test(raw)) return false;
    return sessionPidAlive(Number(raw));
  } catch {
    return false;
  }
}

export function createApiServer(home, options = {}) {
  const stateDir = options.stateDir || path.join(home, "state");
  const resolved = { ...options, stateDir };
  const events = createEventStream(home);
  const server = http.createServer((req, res) => {
    try {
      handle(req, res, home, resolved, events);
    } catch {
      if (res.headersSent) {
        res.destroy();
        return;
      }
      json(res, 500, { ok: false, error: "internal error" });
    }
  });
  const close = server.close.bind(server);
  server.close = (callback) => {
    events.close();
    return close(callback);
  };
  server.once("close", () => events.close());
  return server;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return fs.realpathSync(entry) === fs.realpathSync(self);
  } catch {
    return entry === self;
  }
}

function main() {
  const args = parseArguments(process.argv.slice(2));
  if (!args.home) throw new Error("--home is required");
  if (!args.port) throw new Error("--port is required");
  const home = path.resolve(args.home);
  const port = parsePort(args.port);
  const sessionPid = parseSessionPid(args.sessionPid);
  const stateDir = args.state ? path.resolve(args.state) : "";
  const tokenFile = args.tokenFile ? path.resolve(args.tokenFile) : "";
  const server = createApiServer(home, { tokenFile, stateDir });
  let closing = false;

  function shutdown() {
    if (closing) return;
    closing = true;
    removePortFile(stateDir);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1000).unref();
  }

  if (sessionPid && !sessionPidAlive(sessionPid)) {
    throw new Error(`session pid is not alive: ${sessionPid}`);
  }
  if (sessionPid && !stateDir) {
    throw new Error("--state is required with --session-pid");
  }

  server.listen({ host: "127.0.0.1", port }, () => {
    const address = server.address();
    const bound = typeof address === "object" && address ? address.port : port;
    writePortFile(stateDir, bound);
    process.stdout.write(`listening 127.0.0.1:${bound} home=${home} version=${API_VERSION}\n`);
  });
  server.on("error", (error) => {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  });

  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);

  if (sessionPid) {
    const timer = setInterval(() => {
      if (!lockHolderAlive(stateDir)) shutdown();
    }, 2000);
    timer.unref();
  }
}

if (invokedDirectly()) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  }
}
