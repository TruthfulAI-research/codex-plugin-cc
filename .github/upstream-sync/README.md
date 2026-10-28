# Upstream sync

This fork takes the changes of its upstream, [Crazytieguy/codex-plugin-cc](https://github.com/Crazytieguy/codex-plugin-cc), automatically, but only once they are at least 7 days old. The delay is a defense against supply-chain attacks: every machine that installs the plugin updates itself from this fork's `main`, so a malicious commit pushed to upstream should have a week to be noticed and removed before it gets here. The rule is the one package managers use for a minimum release age, such as npm's `min-release-age` or uv's `exclude-newer`: take the newest version that upstream has had for at least 7 days.

## What the job does

The workflow `.github/workflows/upstream-sync.yml` runs `sync.sh` once a day. Each run:

1. Fetches upstream's `main`, this fork's `main`, and the branch `upstream-sync-state`. That branch holds `seen.tsv`, a log of upstream's head with one row per change (the full commit hash and the time the job saw it, in UTC), and `last_checked`, the time of the last run. The first run creates the branch.
2. Adds a row to `seen.tsv` when upstream's head differs from the last row's commit, even if that commit is in an earlier row.
3. Picks the newest row that is at least 7 days old and whose commit has stayed in upstream's history since: it is an ancestor of every later row's commit, the last of which is upstream's current head. Commit dates play no part, since anyone can backdate them.
4. Merges nothing if GitHub's activity log of upstream's `main` shows a force-push or a deletion of `main` after that row's time.
5. Merges nothing, and fails, if any upstream commit to merge touches `.github/` or `.gitattributes`, file modes and symbolic links included. The job's scripts, its workflow and its merge driver live there, so upstream can never change them.
6. Otherwise merges the commit into `main`, with a merge commit that names it and the time of its row.
7. Pushes `upstream-sync-state`, on every run, then `main` if it merged something.

## How force-pushes are handled

The job looks at upstream once a day, so `seen.tsv` shows upstream's head only at those times. A commit that a force-push removes from upstream is never merged, and a commit that comes back counts only from its new row. A removal and restore between two runs leaves no trace in `seen.tsv`; GitHub's activity log shows it, and step 4 then holds back every row logged before it. When the head after such a force-push is the same commit as the last row, the job logs it again, so it counts from that run.

So after any force-push of upstream's `main`, nothing is merged until a head logged after it has been on upstream for 7 days. If an upstream commit waits more than 30 days, the job fails and says why.

What the rule does not cover: a bad commit that upstream reverts instead of removing still reaches this fork's `main` 7 days after it appeared on upstream, and the revert follows 7 days after it appeared. Packages behave the same way: a bad version that is replaced by a newer one, but not withdrawn, is still installed once it is old enough.

The job uses `git`, `jq` and `curl` (for GitHub's activity log), and no third-party actions. It never runs upstream code: step 5 keeps upstream from changing what the job runs.

## Plugin versions

Claude Code updates a plugin only when its version changes. Without a `version` field it uses the git commit, so each new commit of this fork counts as an update. The fork therefore keeps `version` deleted in `plugins/codex/.claude-plugin/plugin.json` and in the plugin entries of `.claude-plugin/marketplace.json`, while upstream changes the version in most commits.

`.gitattributes` gives both files the merge driver `fork-manifest` (`fork-manifest.sh`), which `sync.sh` configures: where both sides changed the file, the result is upstream's file without the version fields. After each merge, `sync.sh` also deletes version fields that only upstream changed. Any other change this fork makes to these two files is replaced by upstream's next change to them.

## When the job stops running

GitHub turns off scheduled workflows in a public repository after 60 days without activity. The daily push to `upstream-sync-state` may count as activity; GitHub does not say. If GitHub turns the schedule off, it sends an email, the fork stays on the last upstream commit it merged, and this turns the schedule back on:

```sh
gh workflow enable upstream-sync.yml -R TruthfulAI-research/codex-plugin-cc
```

## When the job fails

GitHub emails the person who last changed the workflow's schedule. The run's log says why the run failed and names the upstream commit. Only the 30-day alert can come from a run that also merged something; every other failed run leaves `main` as it was.

- **Upstream changed `.github/` or `.gitattributes`.** Read the change first: merged workflows run in this repository, and this fork's sync files should stay as they are unless you mean to change them. Then merge by hand, as below, from a machine whose token may push workflow files (Johannes's laptop).
- **The merge conflicts.** Merge by hand, as below.
- **Upstream removed commits that this fork merged.** Upstream may have removed them because they were bad. Check them, and revert them in `main` if needed. The job fails on every run until their rows are deleted from `seen.tsv` on the branch `upstream-sync-state`; delete them once the commits are checked.
- **An upstream commit has waited 30 days.** The log says what held it back, usually force-pushes on upstream. Check upstream; the job merges again once a head has been on upstream for 7 days without a force-push.
- **GitHub's activity log could not be read.** Nothing was merged; the next run tries again.

To merge by hand, merge the commit that the log names, not upstream's newer head: it is the one that has been on upstream for 7 days.

```sh
git clone https://github.com/TruthfulAI-research/codex-plugin-cc.git && cd codex-plugin-cc
git config merge.fork-manifest.driver "bash '$PWD/.github/upstream-sync/fork-manifest.sh' %B %A %P"
git fetch https://github.com/Crazytieguy/codex-plugin-cc.git main
git merge --no-ff --no-commit <commit named in the log>
# Resolve any conflicts, then delete the version fields that the merge driver did not:
for f in plugins/codex/.claude-plugin/plugin.json .claude-plugin/marketplace.json; do
  bash .github/upstream-sync/fork-manifest.sh "$f" "$f.new" "$f" && mv "$f.new" "$f" && git add "$f"
done
git commit
git push origin main
```

The next run sees that the commit is in `main` and goes on from there.

## Dry runs and tests

- A pull request that changes the sync files runs `test.sh` and a dry run, which merges locally and pushes nothing. The dry run merges upstream's current candidate into the current `main`, so it can fail because of an upstream conflict that has nothing to do with the pull request.
- A dry run by hand: `gh workflow run upstream-sync.yml -R TruthfulAI-research/codex-plugin-cc -f dry_run=true`, or `SYNC_DRY_RUN=1 bash .github/upstream-sync/sync.sh` locally.
- `bash .github/upstream-sync/test.sh` tests `sync.sh` on scratch repos (a fake upstream and a fake fork, with the clock set by `SYNC_NOW`). It needs `git` and `jq`.
