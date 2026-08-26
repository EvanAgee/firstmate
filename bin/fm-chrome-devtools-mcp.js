#!/usr/bin/env node
// Firstmate-owned chrome-devtools-mcp launcher for chrome-devtools-axi.
// Usage: node bin/fm-chrome-devtools-mcp.js [chrome-devtools-mcp args...]
//        node bin/fm-chrome-devtools-mcp.js --fm-print-spec
//
// chrome-devtools-axi 0.1.29 and 0.1.30 spawn `npx -y chrome-devtools-mcp@latest`
// and omit pageId on page-scoped MCP calls. Chrome DevTools MCP 1.8.0 requires
// pageId when --pageIdRouting is on, which is the default. This file is the
// CHROME_DEVTOOLS_AXI_MCP_PATH target: axi runs `node <this> <mcp-args>`, and
// we replace the floating @latest spawn with a pinned package plus
// --no-page-id-routing. Do not write to stdout except for --fm-print-spec;
// axi speaks MCP over this process's stdio.
"use strict";

const { spawn } = require("node:child_process");
const { existsSync, readFileSync } = require("node:fs");
const { join } = require("node:path");

const PINNED_PACKAGE = "chrome-devtools-mcp";
const PINNED_VERSION = "1.8.0";
const ROUTING_FLAG = "--no-page-id-routing";

function printSpec() {
  process.stdout.write(`package=${PINNED_PACKAGE}@${PINNED_VERSION}\n`);
  process.stdout.write(`flag=${ROUTING_FLAG}\n`);
}

function forwardedArgs(argv) {
  const forwarded = argv.filter((arg) => arg !== "--fm-print-spec");
  if (
    !forwarded.includes(ROUTING_FLAG) &&
    !forwarded.includes("--pageIdRouting=false")
  ) {
    forwarded.push(ROUTING_FLAG);
  }
  return forwarded;
}

function globalMcpPath() {
  let prefix = "";
  try {
    prefix = require("node:child_process")
      .execFileSync("npm", ["prefix", "-g"], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      })
      .trim();
  } catch {
    return "";
  }
  if (!prefix) return "";
  const pkgDir = join(prefix, "lib", "node_modules", PINNED_PACKAGE);
  const pkgJson = join(pkgDir, "package.json");
  const bin = join(pkgDir, "build", "src", "bin", "chrome-devtools-mcp.js");
  if (!existsSync(pkgJson) || !existsSync(bin)) return "";
  try {
    const pkg = JSON.parse(readFileSync(pkgJson, "utf8"));
    if (pkg && pkg.version === PINNED_VERSION) return bin;
  } catch {
    return "";
  }
  return "";
}

function resolveInvocation(mcpArgs) {
  const globalBin = globalMcpPath();
  if (globalBin) {
    return { command: process.execPath, args: [globalBin, ...mcpArgs] };
  }
  return {
    command: "npx",
    args: ["-y", `${PINNED_PACKAGE}@${PINNED_VERSION}`, ...mcpArgs],
  };
}

function main(argv) {
  if (argv.includes("--fm-print-spec")) {
    printSpec();
    return 0;
  }
  const invocation = resolveInvocation(forwardedArgs(argv));
  const child = spawn(invocation.command, invocation.args, {
    stdio: "inherit",
  });
  const shutdown = (signal) => {
    if (!child.killed) child.kill(signal);
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  child.on("error", (err) => {
    process.stderr.write(`fm-chrome-devtools-mcp: ${err.message}\n`);
    process.exit(1);
  });
  child.on("exit", (code, signal) => {
    if (signal) {
      process.kill(process.pid, signal);
      return;
    }
    process.exit(code == null ? 1 : code);
  });
  return undefined;
}

main(process.argv.slice(2));
