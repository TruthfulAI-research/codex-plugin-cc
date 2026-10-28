// TruthfulAI-research fork of codex-plugin-cc (see FORK.md); not in upstream.
//
// With CODEX_COMPANION_THREAD_CONFIG set, the caller, not this plugin, decides how Codex sandboxes a run.
// The variable holds a JSON object keyed by the sandbox mode a command would otherwise send ("read-only",
// or "workspace-write" for `task --write`); each entry is a Codex config object (thread/start's `config`).
// Then thread/start and thread/resume send that entry instead of `sandbox`, `approvalPolicy` and `cwd`,
// every run starts its own `codex app-server` (no shared broker, so it runs with the caller's environment),
// and a run whose active permission profile is not the entry's `default_permissions` is stopped before
// its first turn. `cwd` is left out because Codex marks a cwd that the sandbox can write as a trusted
// project in its config.toml; the app-server runs in cwd, which Codex then uses. Without a broker, `cancel`
// cannot reach a run's app-server, so it signals the run's process (lib/process.mjs), which then interrupts its
// own turn, so that Codex stops the turn's commands, before it exits.

export const THREAD_CONFIG_ENV = "CODEX_COMPANION_THREAD_CONFIG";

export function threadConfigEnabled(env = process.env) {
  return Boolean(env[THREAD_CONFIG_ENV]);
}

export function threadConfigFor(sandbox, env = process.env) {
  const raw = env[THREAD_CONFIG_ENV];
  if (!raw) {
    return null;
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(`${THREAD_CONFIG_ENV} is not valid JSON: ${error.message}`);
  }
  const config = parsed?.[sandbox];
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    throw new Error(`${THREAD_CONFIG_ENV} has no config object for "${sandbox}" runs.`);
  }
  return config;
}

// thread/start or thread/resume params as upstream builds them, changed when the variable is set.
export function applyThreadConfig(params, options = {}, env = process.env) {
  const config = threadConfigFor(options.sandbox ?? "read-only", env);
  if (!config) {
    return params;
  }
  const { cwd: _cwd, approvalPolicy: _approvalPolicy, sandbox: _sandbox, ...rest } = params;
  return { ...rest, config };
}

// Throws unless the thread/start or thread/resume response names the requested permission profile.
export function checkPermissionProfile(response, options = {}, env = process.env) {
  const wanted = threadConfigFor(options.sandbox ?? "read-only", env)?.default_permissions;
  if (!wanted) {
    return;
  }
  const active = response?.activePermissionProfile?.id;
  if (active !== wanted) {
    throw new Error(
      `Codex did not apply the permission profile "${wanted}" (active: ${active ?? "none"}), so the run was stopped before it started.`
    );
  }
}

// Installs, for a run with the variable set, a SIGTERM/SIGINT handler that interrupts this thread's turn and
// closes the app-server before the process exits. Pass `onResponse` to captureTurn; call `remove` afterwards.
export function interruptTurnOnSignal(client, threadId, env = process.env, proc = process) {
  if (!threadConfigEnabled(env)) {
    return { onResponse: undefined, remove() {} };
  }
  let turnId = null;
  const handler = (signal) => {
    const exit = () => proc.exit(signal === "SIGINT" ? 130 : 143);
    const timer = setTimeout(exit, 5000);
    const interrupt = turnId ? client.request("turn/interrupt", { threadId, turnId }) : Promise.resolve();
    interrupt
      .catch(() => {})
      .then(() => client.close())
      .catch(() => {})
      .finally(() => {
        clearTimeout(timer);
        exit();
      });
  };
  proc.once("SIGTERM", handler);
  proc.once("SIGINT", handler);
  return {
    onResponse: (response) => {
      turnId = response?.turn?.id ?? null;
    },
    remove() {
      proc.off("SIGTERM", handler);
      proc.off("SIGINT", handler);
    }
  };
}
