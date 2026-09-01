#!/usr/bin/env node
// Firstmate-owned chrome-devtools-mcp launcher for chrome-devtools-axi.
// Usage: node bin/fm-chrome-devtools-mcp.js [chrome-devtools-mcp args...]
//        node bin/fm-chrome-devtools-mcp.js --fm-print-spec
//
// chrome-devtools-axi through 0.1.30 omits pageId on page-scoped MCP calls.
// Chrome DevTools MCP 1.8.0 requires pageId when --pageIdRouting is on, which
// is the default. AXI 0.1.31 and newer sends pageId itself. This file is the
// CHROME_DEVTOOLS_AXI_MCP_PATH target: axi runs `node <this> <mcp-args>`, and
// we replace the floating @latest spawn with a pinned package. The launcher
// adds --no-page-id-routing only for AXI versions through 0.1.30. Do not write
// to stdout except for --fm-print-spec; axi speaks MCP over this process's
// stdio.
"use strict";

const { execFileSync, spawn } = require("node:child_process");
const { existsSync, readFileSync } = require("node:fs");
const { join } = require("node:path");

const PINNED_PACKAGE = "chrome-devtools-mcp";
const PINNED_VERSION = "1.8.0";
const ROUTING_FLAG = "--no-page-id-routing";
const AXI_PAGE_ID_MIN_VERSION = [0, 1, 31];

function printSpec() {
  process.stdout.write(`package=${PINNED_PACKAGE}@${PINNED_VERSION}\n`);
  process.stdout.write(`flag=${ROUTING_FLAG}\n`);
  process.stdout.write(`axi-page-id-min=${AXI_PAGE_ID_MIN_VERSION.join(".")}\n`);
}

function installedAxiVersion() {
  try {
    const output = execFileSync("chrome-devtools-axi", ["--version"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const match = output.match(/(?:^|\D)(\d+)\.(\d+)\.(\d+)(?:\D|$)/);
    return match ? match.slice(1).map(Number) : null;
  } catch {
    return null;
  }
}

function versionAtLeast(actual, minimum) {
  for (let index = 0; index < minimum.length; index += 1) {
    if (actual[index] > minimum[index]) return true;
    if (actual[index] < minimum[index]) return false;
  }
  return true;
}

function forwardedArgs(argv, axiVersion) {
  const forwarded = argv.filter((arg) => arg !== "--fm-print-spec");
  if (
    !versionAtLeast(axiVersion, AXI_PAGE_ID_MIN_VERSION) &&
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
    prefix = execFileSync("npm", ["prefix", "-g"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
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
  const axiVersion = installedAxiVersion();
  if (!axiVersion) {
    process.stderr.write(
      "fm-chrome-devtools-mcp: cannot read chrome-devtools-axi version\n",
    );
    return 1;
  }
  const invocation = resolveInvocation(forwardedArgs(argv, axiVersion));
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

const status = main(process.argv.slice(2));
if (status !== undefined) process.exitCode = status;
