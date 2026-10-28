// TruthfulAI-research fork (see FORK.md): tests for CODEX_COMPANION_THREAD_CONFIG.
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";

import { buildEnv, installFakeCodex } from "./fake-codex-fixture.mjs";
import { initGitRepo, makeTempDir, run } from "./helpers.mjs";
import { loadBrokerSession } from "../plugins/codex/scripts/lib/broker-lifecycle.mjs";
import {
  THREAD_CONFIG_ENV,
  applyThreadConfig,
  checkPermissionProfile,
  threadConfigFor
} from "../plugins/codex/scripts/lib/fork-thread-config.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SCRIPT = path.join(ROOT, "plugins", "codex", "scripts", "codex-companion.mjs");

const READ = { default_permissions: "research-read", approval_policy: "never" };
const WRITE = { default_permissions: "research-write" };
const CONFIG = JSON.stringify({ "read-only": READ, "workspace-write": WRITE });
const UPSTREAM = { cwd: "/repo", model: null, approvalPolicy: "never", sandbox: "read-only", ephemeral: true };

test("without the variable, params are upstream's", () => {
  assert.deepEqual(applyThreadConfig({ ...UPSTREAM }, {}, {}), UPSTREAM);
  assert.equal(threadConfigFor("read-only", {}), null);
  checkPermissionProfile({}, {}, {});
});

test("the variable replaces sandbox, approval policy and cwd with the entry for the mode", () => {
  const env = { [THREAD_CONFIG_ENV]: CONFIG };
  assert.deepEqual(applyThreadConfig({ ...UPSTREAM }, {}, env), { model: null, ephemeral: true, config: READ });
  assert.deepEqual(
    applyThreadConfig({ ...UPSTREAM, sandbox: "workspace-write" }, { sandbox: "workspace-write" }, env),
    { model: null, ephemeral: true, config: WRITE }
  );
});

test("bad JSON or a missing entry fails instead of falling back", () => {
  assert.throws(() => threadConfigFor("read-only", { [THREAD_CONFIG_ENV]: "{" }), /not valid JSON/);
  assert.throws(
    () => threadConfigFor("workspace-write", { [THREAD_CONFIG_ENV]: JSON.stringify({ "read-only": READ }) }),
    /no config object for "workspace-write"/
  );
  assert.throws(() => threadConfigFor("read-only", { [THREAD_CONFIG_ENV]: JSON.stringify({ "read-only": [] }) }), /no config object/);
});

test("the active permission profile must be the requested one", () => {
  const env = { [THREAD_CONFIG_ENV]: CONFIG };
  checkPermissionProfile({ activePermissionProfile: { id: "research-read" } }, {}, env);
  checkPermissionProfile({ activePermissionProfile: { id: "research-write" } }, { sandbox: "workspace-write" }, env);
  assert.throws(() => checkPermissionProfile({ activePermissionProfile: { id: ":workspace" } }, {}, env), /did not apply/);
  assert.throws(() => checkPermissionProfile({}, {}, env), /active: none/);
});

// Upstream's fake Codex, changed in a copy at test time: it logs thread/start params and answers with the
// active permission profile (the requested one, or a wrong one).
function installProfileFakeCodex(binDir, profileMode) {
  installFakeCodex(binDir);
  const scriptPath = path.join(binDir, "codex");
  const logPath = path.join(binDir, "thread-start.jsonl");
  let source = fs.readFileSync(scriptPath, "utf8");
  const start = "const thread = nextThread(state, message.params.cwd, message.params.ephemeral);";
  const result = "result: { thread: buildThread(thread), model:";
  assert.ok(source.includes(start) && source.includes(result), "upstream's fake Codex changed; update this test");
  source = source.replace(
    start,
    `require("node:fs").appendFileSync(${JSON.stringify(logPath)}, JSON.stringify({ params: message.params, cwd: process.cwd() }) + "\\n");\n` +
      start.replace("message.params.cwd", "(message.params.cwd ?? process.cwd())")
  );
  source = source.replace(
    result,
    `result: { activePermissionProfile: ${JSON.stringify(profileMode)} === "wrong" ? { id: ":workspace" } : { id: message.params.config && message.params.config.default_permissions }, thread: buildThread(thread), model:`
  );
  fs.writeFileSync(scriptPath, source);
  return logPath;
}

function setupRepo() {
  const repo = makeTempDir();
  initGitRepo(repo);
  fs.writeFileSync(path.join(repo, "README.md"), "hello\n");
  run("git", ["add", "README.md"], { cwd: repo });
  run("git", ["commit", "-m", "init"], { cwd: repo });
  return repo;
}

test("a task with the variable sends the config, no sandbox or cwd, and starts no broker", () => {
  const repo = setupRepo();
  const binDir = makeTempDir();
  const logPath = installProfileFakeCodex(binDir, "right");
  const result = run("node", [SCRIPT, "task", "say hi"], {
    cwd: repo,
    env: { ...buildEnv(binDir), [THREAD_CONFIG_ENV]: CONFIG }
  });
  assert.equal(result.status, 0, result.stderr);
  const [entry] = fs.readFileSync(logPath, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  assert.deepEqual(entry.params.config, READ);
  for (const key of ["sandbox", "approvalPolicy", "cwd"]) {
    assert.equal(key in entry.params, false, `thread/start sent ${key}`);
  }
  assert.equal(fs.realpathSync(entry.cwd), fs.realpathSync(repo));
  assert.equal(loadBrokerSession(repo), null);
});

test("task --write sends the workspace-write entry", () => {
  const repo = setupRepo();
  const binDir = makeTempDir();
  const logPath = installProfileFakeCodex(binDir, "right");
  const result = run("node", [SCRIPT, "task", "--write", "say hi"], {
    cwd: repo,
    env: { ...buildEnv(binDir), [THREAD_CONFIG_ENV]: CONFIG }
  });
  assert.equal(result.status, 0, result.stderr);
  const [entry] = fs.readFileSync(logPath, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  assert.deepEqual(entry.params.config, WRITE);
});

test("a run whose active profile differs is stopped", () => {
  const repo = setupRepo();
  const binDir = makeTempDir();
  installProfileFakeCodex(binDir, "wrong");
  const result = run("node", [SCRIPT, "task", "say hi"], {
    cwd: repo,
    env: { ...buildEnv(binDir), [THREAD_CONFIG_ENV]: CONFIG }
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr + result.stdout, /did not apply the permission profile "research-read"/);
});
