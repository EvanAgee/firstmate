// Assemble the localhost API read windows from firstmate files.
//
// bin/fm-api-server.mjs owns the HTTP routes and JSON contracts.
// This module reads one home and returns the bodies those routes send.
// Parked decisions and blocked tasks come from fm-classify-lib.sh's
// scan_open_decisions fold so the API cannot disagree with firstmate.
// Rigs come from config/crew-dispatch.json.

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const BIN_DIR = path.dirname(fileURLToPath(import.meta.url));
const SCAN_TIMEOUT_MS = 5000;

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

export function captainQueueBody(stateDir) {
  const decisions = scanOpenDecisions(stateDir)
    .filter((row) => row.verb === "needs-decision")
    .map(asItem);
  return { ok: true, decisions };
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

export function assembleRigs(data) {
  const rigs = [];
  if (!data || typeof data !== "object") return rigs;
  const rules = Array.isArray(data.rules) ? data.rules : [];
  for (const rule of rules) {
    if (!rule || typeof rule !== "object") continue;
    const name = typeof rule.when === "string" ? rule.when : "";
    const rungs = asRungs(rule.use);
    if (!name && rungs.length === 0) continue;
    rigs.push({ name, rungs });
  }
  const fallback = asRungs(data.default);
  if (fallback.length > 0) {
    rigs.push({ name: "default", rungs: fallback });
  }
  return rigs;
}

export function rigsBody(home) {
  const file = path.join(home, "config", "crew-dispatch.json");
  let raw;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch (error) {
    if (error && error.code === "ENOENT") return { ok: true, rigs: [] };
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
  return { ok: true, rigs: assembleRigs(data) };
}
