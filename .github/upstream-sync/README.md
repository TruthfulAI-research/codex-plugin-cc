# Upstream sync

This fork takes the changes of its upstream, [Crazytieguy/codex-plugin-cc](https://github.com/Crazytieguy/codex-plugin-cc), automatically, but only once they are at least 7 days old. The delay is a defense against supply-chain attacks: every machine that installs the plugin updates itself from this fork's `main`, so a malicious commit pushed to upstream should have a week to be noticed and removed before it gets here.

## What the job does

The workflow `.github/workflows/upstream-sync.yml` runs `sync.sh` once a day. Each run:

1. Fetches upstream's `main`, this fork's `main`, and the branch `upstream-sync-state`. That branch holds `seen.tsv`, one line per upstream head the job has seen (the full commit hash and the time the job first saw it, in UTC), and `last_checked`, the time of the last run. The first run creates the branch.
2. Adds upstream's current head to `seen.tsv` if it is not there yet.
3. Picks the newest commit in `seen.tsv` that was first seen at least 7 days ago and is still on upstream's `main`. Commit dates play no part, since anyone can backdate them. A commit that a force-push removed from upstream is skipped.
4. If that commit is not yet in `main`, merges it into `main` with a merge commit that names it and the time it was first seen.
5. Pushes `upstream-sync-state`, on every run, then `main` if it merged something. The daily push is also meant to keep the repository active: GitHub turns off scheduled workflows in a public repository after 60 days without activity.

The job uses only `git` and `jq`: no third-party actions, and no upstream code is run.

## Plugin versions

Claude Code updates a plugin only when its version changes. Without a `version` field it uses the git commit, so each new commit of this fork counts as an update. The fork therefore keeps `version` deleted in `plugins/codex/.claude-plugin/plugin.json` and in the plugin entries of `.claude-plugin/marketplace.json`, while upstream changes the version in most commits.

`.gitattributes` gives both files the merge driver `fork-manifest` (`fork-manifest.sh`), which `sync.sh` configures: where both sides changed the file, the result is upstream's file without the version fields. After each merge, `sync.sh` also deletes version fields that only upstream changed. Any other change this fork makes to these two files is replaced by upstream's next change to them.

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
