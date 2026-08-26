#!/usr/bin/env node
// Localhost HTTP server for one firstmate home.
//
// Bind 127.0.0.1 only. Port, home, and state directory come from argv; this
// file has no default filesystem paths. bin/fm-api.sh owns process lifecycle.
// GET /health reports the API version and the home this process serves.

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const API_VERSION = "1";

function parseArguments(argv) {
  const result = { home: "", port: "", state: "", sessionPid: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--home" || name === "--port" || name === "--state" || name === "--session-pid") {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      const key = name === "--session-pid" ? "sessionPid" : name.slice(2);
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

function json(res, status, body) {
  const payload = `${JSON.stringify(body)}\n`;
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

function handle(req, res, home) {
  let url;
  try {
    url = new URL(req.url || "/", "http://127.0.0.1");
  } catch {
    json(res, 400, { ok: false, error: "malformed url" });
    return;
  }
  if (url.pathname === "/health") {
    if (req.method !== "GET" && req.method !== "HEAD") {
      json(res, 405, { ok: false, error: "method not allowed" });
      return;
    }
    if (req.method === "HEAD") {
      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
      res.end();
      return;
    }
    json(res, 200, { ok: true, version: API_VERSION, home });
    return;
  }
  json(res, 404, { ok: false, error: "not found" });
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

export function createApiServer(home) {
  return http.createServer((req, res) => {
    try {
      handle(req, res, home);
    } catch {
      if (res.headersSent) {
        res.destroy();
        return;
      }
      json(res, 400, { ok: false, error: "malformed url" });
    }
  });
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
  const server = createApiServer(home);
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
