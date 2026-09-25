#!/usr/bin/env node
// Ask openzoo without putting the question on any process command line.
//
// openzoo 0.51.31 `ask` (package bin/openzoo.js) reads the question only from
// process.argv[3]. There is no stdin form, no `-`, and no `--stdin`. Passing
// a file path would ask the model that path. This helper reads a JSON payload
// from its own stdin and calls the same PayClient path the CLI uses, in this
// process, so the prompt never becomes a child argv.

import { execFileSync } from "node:child_process";
import { closeSync, existsSync, openSync, readFileSync, readSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export function isOpenzooRoot(dir) {
  return existsSync(join(dir, "lib", "pay.js")) && existsSync(join(dir, "lib", "config.js"));
}

export function rootFromJs(jsPath) {
  try {
    const resolved = realpathSync(jsPath);
    const root = dirname(dirname(resolved));
    if (isOpenzooRoot(root)) return root;
  } catch {
    /* not a readable openzoo.js */
  }
  return "";
}

function commandPath(name) {
  const entries = String(process.env.PATH || "").split(":");
  for (let i = 0; i < entries.length; i++) {
    const dir = entries[i];
    if (!dir) continue;
    const candidate = join(dir, name);
    if (existsSync(candidate)) return candidate;
  }
  return "";
}

function readHead(path, limit) {
  let fd = -1;
  try {
    fd = openSync(path, "r");
    const buf = Buffer.alloc(limit);
    const n = readSync(fd, buf, 0, limit, 0);
    return buf.subarray(0, n).toString("utf8");
  } catch {
    return "";
  } finally {
    if (fd >= 0) closeSync(fd);
  }
}

function rootsMentioned(text) {
  const found = [];
  const re = /\/[^\s"'\\]+openzoo\.js/g;
  let match = re.exec(text);
  while (match) {
    const root = rootFromJs(match[0]);
    if (root && found.indexOf(root) === -1) found.push(root);
    match = re.exec(text);
  }
  return found;
}

export function findOpenzooRoot() {
  const bin = commandPath("openzoo");
  if (bin) {
    const direct = rootFromJs(bin);
    if (direct) return direct;
    const mentioned = rootsMentioned(readHead(bin, 262144));
    if (mentioned.length > 0) return mentioned[0];
  }
  try {
    const which = execFileSync("mise", ["which", "openzoo"], { encoding: "utf8" }).trim();
    const root = which ? rootFromJs(which) : "";
    if (root) return root;
  } catch {
    /* mise is optional */
  }
  try {
    const globalRoot = execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim();
    if (globalRoot && isOpenzooRoot(join(globalRoot, "openzoo"))) return join(globalRoot, "openzoo");
  } catch {
    /* npm is optional */
  }
  throw new Error("openzoo CLI not on PATH — try: mise use -g npm:openzoo@latest");
}

export function readPayload(text) {
  let input;
  try {
    input = JSON.parse(text);
  } catch {
    throw new Error("ask payload was not valid JSON");
  }
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new Error("ask payload was not valid JSON");
  }
  return input;
}

export async function runAsk(input) {
  const question = String(input.question ?? "");
  if (!question.trim()) throw new Error("empty question");
  let system = String(input.system ?? "");
  const model = String(input.model ?? "").trim()
    || process.env.OPENZOO_DEFAULT_MODEL
    || "anthropic/claude-opus-5";
  const root = findOpenzooRoot();
  if (input.web === true) {
    const webUrl = pathToFileURL(join(root, "lib", "websearch.js")).href;
    const { webSearch, formatWebResults } = await import(webUrl);
    const hits = await webSearch(question, 5).catch((err) => {
      const message = err && err.message ? err.message : String(err);
      process.stderr.write(`web search failed: ${message}\n`);
      return [];
    });
    if (hits.length) system = (system ? system + "\n\n" : "") + formatWebResults(question, hits);
  }
  const { PayClient } = await import(pathToFileURL(join(root, "lib", "pay.js")).href);
  const { config } = await import(pathToFileURL(join(root, "lib", "config.js")).href);
  const client = new PayClient();
  const { response, receipt } = await client.fetch(`${config.apiBase}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model,
      messages: system
        ? [{ role: "system", content: system }, { role: "user", content: question }]
        : [{ role: "user", content: question }],
      max_tokens: Number(process.env.OPENZOO_ASK_MAX_TOKENS || 1024),
    }),
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`zoo returned HTTP ${response.status}: ${String(text).slice(0, 300)}`);
  }
  const data = await response.json();
  process.stdout.write(`${data.choices?.[0]?.message?.content ?? "(no content)"}\n`);
  if (receipt && receipt.line) process.stderr.write(`\n${receipt.line}\n`);
}

function isDirectRun() {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

function fail(err) {
  const message = err && err.message ? err.message : String(err);
  process.stderr.write(`openzoo: ${message}\n`);
  process.exit(1);
}

if (isDirectRun()) {
  let payload;
  try {
    payload = readPayload(readFileSync(0, "utf8"));
  } catch (err) {
    fail(err);
  }
  runAsk(payload).catch(fail);
}
