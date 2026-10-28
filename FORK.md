# TruthfulAI-research's fork of codex-plugin-cc

This repository is a fork of [Crazytieguy/codex-plugin-cc](https://github.com/Crazytieguy/codex-plugin-cc), which is itself a fork of [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc). It is installed as `codex@codex-plugin-cc` (the marketplace keeps upstream's name), and the TruthfulAI-research research plugin (`research-codex`) uses it for GPT reviews and tasks. Everything else is upstream's; see README.md.

## What differs from upstream

1. **The caller can choose the sandbox.** Upstream starts every Codex run read-only (`task --write`: workspace-write) with no network and no approvals, which overrides Codex's own config. When `CODEX_COMPANION_THREAD_CONFIG` is set, the plugin sends a Codex config object instead of `sandbox`, `approvalPolicy` and `cwd`. The variable holds a JSON object keyed by the mode the command would otherwise use:

   ```json
   {"read-only": {"default_permissions": "research-read", "permissions.research-read": {"filesystem": {}, "network": {}}},
    "workspace-write": {"default_permissions": "research-write", "permissions.research-write": {}}}
   ```

   Each entry is sent as thread/start's (and thread/resume's) `config`: keys are split on dots, so absolute paths go inside values. With the variable set:
   - every run starts its own `codex app-server` in the run's folder, with the caller's environment; no broker is shared;
   - `cwd` is not sent, because Codex marks a cwd that the sandbox can write as a trusted project in its config.toml (the app-server's own folder is used instead);
   - a run stops before its first turn when the thread's active permission profile is not the entry's `default_permissions`;
   - invalid JSON or a missing entry stops the run; it never falls back to the old settings.

   - `cancel` (for tasks and the plugin's plain `review`) signals the run's process (a shared broker would otherwise take the interrupt). The run then interrupts its own turn and kills the processes below its app-server, which Codex's interrupt leaves running, before it exits. For a run that leads no process group (started with `nohup` from a shell), the kill helper in `lib/process.mjs` now signals the process itself, where upstream gave up, after checking that the process is still the plugin's.

   Without the variable, the plugin behaves as upstream, apart from that kill-helper fix. The code is `plugins/codex/scripts/lib/fork-thread-config.mjs`, called from `codex.mjs`, `app-server.mjs` and `process.mjs`; the tests are `tests/fork-thread-config.test.mjs`.

2. **No `version` in `plugins/codex/.claude-plugin/plugin.json`.** Claude Code installs a plugin update only when the version string changes, and uses the marketplace's git commit when there is none. Without the field, each commit of this fork installs as its own version, so switching from upstream and taking upstream's merges both reach installed copies. (`npm run check-version` reports the missing field; upstream's CI does not run it.)

3. **Upstream's changes arrive through a daily job, after 7 days.** `.github/workflows/upstream-sync.yml` merges into this `main` the newest upstream commit that has been in upstream's `main` for at least 7 days, as npm's `min-release-age` does for packages: a defense against supply-chain attacks, since every machine that installs this plugin updates itself from `main`. A commit upstream removes is never merged; one it only reverts is merged once 7 days old. A commit that was force-pushed away and back counts from its return; the job checks GitHub's activity log of upstream's `main` for that. Upstream changes to `.github/` or `.gitattributes` are never merged automatically, so upstream cannot change the job itself; those merges are done by hand. See `.github/upstream-sync/README.md`.

Changed files carry a comment saying so, as the Apache License 2.0 (section 4(b)) asks.
