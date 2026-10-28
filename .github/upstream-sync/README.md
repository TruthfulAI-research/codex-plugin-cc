# Upstream sync

This fork takes the changes of its upstream, [Crazytieguy/codex-plugin-cc](https://github.com/Crazytieguy/codex-plugin-cc), automatically, but only once they are at least 7 days old. The delay is a defense against supply-chain attacks: every machine that installs the plugin updates itself from this fork's `main`, so a malicious commit pushed to upstream should have a week to be noticed and removed before it gets here. The rule is the one package managers use for a minimum release age, such as npm's `min-release-age` or uv's `exclude-newer`: take the newest version that upstream has had for at least 7 days.

## What the job does

The workflow `.github/workflows/upstream-sync.yml` runs `sync.sh` once a day. Each run:

1. Fetches upstream's `main`, this fork's `main`, and the branch `upstream-sync-state`. That branch holds `seen.tsv`, a log of upstream's head with one row per change (the full commit hash and the time the job saw it, in UTC), and `last_checked`, the time of the last run. The first run creates the branch.
2. Adds a row to `seen.tsv` when upstream's head differs from the last row's commit, even if that commit is in an earlier row.
3. Picks the newest row that is at least 7 days old and whose commit has stayed in upstream's history since: it is an ancestor of every later row's commit, the last of which is upstream's current head. Commit dates play no part, since anyone can backdate them.
4. If that commit is not yet in `main`, merges it into `main` with a merge commit that names it and the time of its row.
5. Pushes `upstream-sync-state`, on every run, then `main` if it merged something.

So a commit that a force-push removes from upstream within the 7 days is never merged, and a commit that comes back later counts only from its new row.

What the rule does not cover: a bad commit that upstream reverts instead of removing still reaches this fork's `main` 7 days after it appeared on upstream, and the revert follows 7 days after it appeared. Packages behave the same way: a bad version that is replaced by a newer one, but not withdrawn, is still installed once it is old enough.

The job uses only `git` and `jq`: no third-party actions, and no upstream code is run.

## Plugin versions

Claude Code updates a plugin only when its version changes. Without a `version` field it uses the git commit, so each new commit of this fork counts as an update. The fork therefore keeps `version` deleted in `plugins/codex/.claude-plugin/plugin.json` and in the plugin entries of `.claude-plugin/marketplace.json`, while upstream changes the version in most commits.

`.gitattributes` gives both files the merge driver `fork-manifest` (`fork-manifest.sh`), which `sync.sh` configures: where both sides changed the file, the result is upstream's file without the version fields. After each merge, `sync.sh` also deletes version fields that only upstream changed. Any other change this fork makes to these two files is replaced by upstream's next change to them.

## When the job stops running

GitHub turns off scheduled workflows in a public repository after 60 days without activity. The daily push to `upstream-sync-state` may count as activity; GitHub does not say. If GitHub turns the schedule off after a quiet spell, it sends an email, the fork stays on the last upstream commit it merged, and this turns the schedule back on:

```sh
gh workflow enable upstream-sync.yml -R TruthfulAI-research/codex-plugin-cc
```

## When the job fails

A failed run never changes `main`, and GitHub emails the person who last changed the workflow's schedule. The run's log says why it failed and which upstream commit it tried to merge. Merge that commit, not upstream's newer head: it is the one that has been on upstream for 7 days.

- **Upstream changed `.github/workflows/`.** The job's token may not push workflow files. Read the workflow changes first: once merged, they run in this repository. Then run the job's script from a clone of `main` on the laptop, where git pushes with your own GitHub login, which needs the `workflow` scope. It applies the same 7-day rule:

  ```sh
  git clone https://github.com/TruthfulAI-research/codex-plugin-cc.git && cd codex-plugin-cc
  bash .github/upstream-sync/sync.sh
  ```

- **The merge conflicts.** Merge by hand, keeping the version fields deleted:

  ```sh
  git clone https://github.com/TruthfulAI-research/codex-plugin-cc.git && cd codex-plugin-cc
  git config merge.fork-manifest.driver "bash '$PWD/.github/upstream-sync/fork-manifest.sh' %B %A %P"
  git fetch https://github.com/Crazytieguy/codex-plugin-cc.git main
  git merge --no-ff <commit named in the log>
  # resolve the conflicts, commit, then:
  git push origin main
  ```

  The next run sees that the commit is in `main` and goes on from there.

## Dry runs and tests

- A pull request that changes the sync files runs `test.sh` and a dry run, which merges locally and pushes nothing.
- A dry run by hand: `gh workflow run upstream-sync.yml -R TruthfulAI-research/codex-plugin-cc -f dry_run=true`, or `SYNC_DRY_RUN=1 bash .github/upstream-sync/sync.sh` locally.
- `bash .github/upstream-sync/test.sh` tests `sync.sh` on scratch repos (a fake upstream and a fake fork, with the clock set by `SYNC_NOW`). It needs `git` and `jq`.
