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
//   { ok, decisions: [{ task, key, summary }] }
//   Parked decisions still open in this home. Empty home: decisions is [].
// GET /captain-holds
//   { ok, holds: [{ id, title, reason, repo, createdAt, blockedBy,
//   actionable, done, answerable }] }
//   The captain-kind decisions from tasks-axi, read in full and sorted
//   actionable-first. tasks-axi absent: holds is [].
// GET /blocked
//   { ok, blocked: [{ task, key, summary }] }
//   Blocked tasks still open in this home. Empty home: blocked is [].
// GET /rigs
//   { ok, note, rigs: [{ name, rungs: [{ harness, model, effort, enabled }],
//   pin }], defaultPin, crew, secondmate }
//   Dispatch pools, each rung's enabled state, the dispatch note, per-rig and
//   default pins, and the raw crew/secondmate pin lines. Missing config:
//   rigs is [] and the extras are empty.
// GET /events
//   Server-sent event stream of typed home changes. Event timing comes from
//   FM_API_EVENT_QUIET_MS, FM_API_EVENT_DEADLINE_MS, and FM_API_HEARTBEAT_MS;
//   docs/configuration.md owns the public stream contract.
// POST /captain-notes requires Authorization: Bearer <token> and queues a
// captain note for firstmate on the wake queue, encoded as operational input.
// Reads need no token. A captain note never closes a parked decision.

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
  enrichFleetTasks,
  rigsBody,
} from "./fm-api-reads.mjs";
import { taskDetailBody } from "./fm-api-task-detail.mjs";

export const API_VERSION = "1";
const BIN_DIR = path.dirname(fileURLToPath(import.meta.url));
const SNAPSHOT_SCRIPT = path.join(BIN_DIR, "fm-fleet-snapshot.sh");
const MAX_BODY_BYTES = 16384;
const MAX_NOTE_TEXT = 2000;
const NOTE_KIND = "away-supervisor";
const TASK_SLUG = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
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

function parseCaptainNote(raw) {
  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    const error = new Error("malformed json");
    error.status = 400;
    throw error;
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    const error = new Error("malformed json");
    error.status = 400;
    throw error;
  }
  const task = body.task;
  const text = body.text;
  if (typeof task !== "string" || !TASK_SLUG.test(task)) {
    const error = new Error("invalid task");
    error.status = 400;
    throw error;
  }
  if (typeof text !== "string" || !text.trim()) {
    const error = new Error("missing text");
    error.status = 400;
    throw error;
  }
  if (/[\r\n\u2028\u2029]/.test(text)) {
    const error = new Error("text must be one line");
    error.status = 400;
    throw error;
  }
  if (text.length > MAX_NOTE_TEXT) {
    const error = new Error("text too long");
    error.status = 400;
    throw error;
  }
  return { task, text };
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

function handleCaptainNote(req, res, home, options) {
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
  readBody(req, MAX_BODY_BYTES)
    .then((raw) => {
      const note = parseCaptainNote(raw);
      if (!taskExists(home, note.task)) {
        const error = new Error("not found");
        error.status = 404;
        throw error;
      }
      return queueCaptainNote(home, options.stateDir, note);
    })
    .then(() => {
      json(res, 200, { ok: true });
    })
    .catch((error) => {
      if (res.headersSent) {
        res.destroy();
        return;
      }
      const status = error && error.status ? error.status : 500;
      const message = status === 500 ? "failed" : error.message;
      json(res, status, { ok: false, error: message });
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

function handle(req, res, home, options, events) {
  const stateDir = options.stateDir || path.join(home, "state");
  let url;
  try {
    url = new URL(req.url || "/", "http://127.0.0.1");
  } catch {
    json(res, 400, { ok: false, error: "malformed url" });
    return;
  }
  const taskMatch = url.pathname.match(/^\/tasks\/([^/]+)$/);
  let task = null;
  if (taskMatch) {
    try {
      task = decodeURIComponent(taskMatch[1]);
    } catch {
      json(res, 400, { ok: false, error: "malformed url" });
      return;
    }
    if (!TASK_SLUG.test(task)) {
      json(res, 404, { ok: false, error: "task not found" });
      return;
    }
  }
  const read = url.pathname === "/health"
    || url.pathname === "/fleet"
    || url.pathname === "/captain-queue"
    || url.pathname === "/captain-holds"
    || url.pathname === "/blocked"
    || url.pathname === "/rigs"
    || task !== null;
  if (read && req.method !== "GET" && req.method !== "HEAD") {
    json(res, 405, { ok: false, error: "method not allowed" });
    return;
  }
  if (url.pathname === "/health") {
    sendGet(req, res, { ok: true, version: API_VERSION, home });
    return;
  }
  if (url.pathname === "/captain-queue") {
    sendGet(req, res, captainQueueBody(stateDir));
    return;
  }
  if (url.pathname === "/captain-holds") {
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
    return;
  }
  if (url.pathname === "/blocked") {
    sendGet(req, res, blockedListBody(stateDir));
    return;
  }
  if (url.pathname === "/rigs") {
    try {
      sendGet(req, res, rigsBody(home));
    } catch (error) {
      if (error && error.code === "INVALID_RIG_CONFIG") {
        json(res, 500, { ok: false, error: "invalid rig config" });
        return;
      }
      throw error;
    }
    return;
  }
  if (url.pathname === "/fleet") {
    // JSON contract: bin/fm-fleet-snapshot.sh --json (schema fm-fleet-snapshot.v1).
    sendFleetSnapshot(req, res, home);
    return;
  }
  if (task !== null) {
    handleTaskDetail(req, res, home, stateDir, task);
    return;
  }
  if (url.pathname === "/captain-notes") {
    handleCaptainNote(req, res, home, options);
    return;
  }
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

  if (relativePath === "data/backlog.md") return { type: "captain-queue" };
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
