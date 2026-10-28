#!/usr/bin/env bash
# Merges upstream's main into this fork's main, but only commits first seen on upstream main at least
# 7 days ago. See README.md in this folder.
#
# Environment (all optional):
#   SYNC_DRY_RUN=1     do everything locally, push nothing, print what would happen
#   SYNC_TOKEN         token for pushing to the fork over HTTPS (the job's GITHUB_TOKEN)
#   SYNC_NOW           the current time, as 2026-10-28T17:00:00Z (tests)
#   SYNC_ORIGIN_URL    the fork (default: this GitHub repository)
#   SYNC_UPSTREAM_URL  upstream (default: Crazytieguy/codex-plugin-cc)
set -euo pipefail
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)
origin_url=${SYNC_ORIGIN_URL:-https://github.com/${GITHUB_REPOSITORY:-TruthfulAI-research/codex-plugin-cc}.git}
upstream_url=${SYNC_UPSTREAM_URL:-https://github.com/Crazytieguy/codex-plugin-cc.git}
state_branch=upstream-sync-state
min_age_seconds=$((7 * 24 * 60 * 60))
manifests="plugins/codex/.claude-plugin/plugin.json .claude-plugin/marketplace.json"
tab=$(printf '\t')
time_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

die() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::error::$*"; else echo "error: $*" >&2; fi
  exit 1
}

command -v jq > /dev/null || die "jq is not installed"

case ${SYNC_DRY_RUN:-0} in
  1 | true) dry_run=1 ;;
  0 | false | '') dry_run=0 ;;
  *) die "SYNC_DRY_RUN must be 0 or 1" ;;
esac

now=${SYNC_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
[[ $now =~ $time_re ]] || die "SYNC_NOW must look like 2026-10-28T17:00:00Z, not $now"
# Times in this format compare correctly as strings.
cutoff=$(jq -nr --arg now "$now" --argjson age "$min_age_seconds" '$now | fromdateiso8601 - $age | todate')

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/upstream-sync.XXXXXX")
trap 'rm -rf "$work"' EXIT
git init -q -b sync "$work/repo"
cd "$work/repo"
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
fi
git config merge.fork-manifest.name 'upstream manifest without version fields'
git config merge.fork-manifest.driver "bash '$here/fork-manifest.sh' %B %A %P"

if [ -n "${SYNC_TOKEN:-}" ]; then
  auth=$(printf 'x-access-token:%s' "$SYNC_TOKEN" | base64 | tr -d '\n')
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::add-mask::$auth"; fi
  # The header goes only to the fork's URL, and through the environment, so the token is in no file.
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="http.$origin_url.extraheader"
  export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth"
fi

git remote add origin "$origin_url"
git remote add upstream "$upstream_url"
git fetch -q --no-tags upstream +refs/heads/main:refs/remotes/upstream/main
git fetch -q --no-tags origin +refs/heads/main:refs/remotes/origin/main
status=0
git ls-remote --exit-code origin "refs/heads/$state_branch" > /dev/null || status=$?
case $status in
  0)
    have_state=1
    git fetch -q --no-tags origin "+refs/heads/$state_branch:refs/remotes/origin/$state_branch"
    git show "refs/remotes/origin/$state_branch:seen.tsv" > "$work/seen.tsv"
    ;;
  2)
    have_state=0
    echo "The state branch $state_branch does not exist yet; this run creates it."
    : > "$work/seen.tsv"
    ;;
  *) die "could not list the branches of $origin_url" ;;
esac

if grep -Evq "^[0-9a-f]{40}${tab}[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\$" "$work/seen.tsv"; then
  die "seen.tsv on $state_branch has a malformed line"
fi
duplicates=$(cut -f1 "$work/seen.tsv" | sort | uniq -d)
if [ -n "$duplicates" ]; then
  die "seen.tsv on $state_branch lists a commit twice"
fi

head=$(git rev-parse refs/remotes/upstream/main)
head_seen=$(awk -F "$tab" -v head="$head" '$1 == head { print $2 }' "$work/seen.tsv")
if [ -n "$head_seen" ]; then
  echo "Upstream main is at $head, first seen $head_seen."
else
  printf '%s\t%s\n' "$head" "$now" >> "$work/seen.tsv"
  echo "Upstream main is at $head, first seen now ($now)."
fi

# The candidate: the newest commit first seen at least 7 days ago that is still on upstream main.
# Commit dates are never used: an attacker can backdate them.
candidate='' candidate_seen=''
sort -t "$tab" -k2,2r "$work/seen.tsv" > "$work/newest-first.tsv"
while IFS="$tab" read -r sha first_seen; do
  if [[ $first_seen > $cutoff ]]; then continue; fi
  if git cat-file -e "$sha^{commit}" 2> /dev/null && git merge-base --is-ancestor "$sha" refs/remotes/upstream/main; then
    candidate=$sha candidate_seen=$first_seen
    break
  fi
  echo "Skipping $sha (first seen $first_seen): it is no longer on upstream main."
done < "$work/newest-first.tsv"

merged=0 conflict=0
if [ -z "$candidate" ]; then
  echo "No commit still on upstream main was first seen at least 7 days ago (by $cutoff): nothing to merge."
elif git merge-base --is-ancestor "$candidate" refs/remotes/origin/main; then
  echo "$candidate (first seen $candidate_seen) is already in main: nothing to merge."
else
  echo "Merging $candidate (first seen $candidate_seen). Upstream commits it brings:"
  git log --oneline --no-decorate "refs/remotes/origin/main..$candidate"
  git checkout -q --detach refs/remotes/origin/main
  if git merge -q --no-ff --no-commit "$candidate"; then
    # The merge driver runs only where both sides changed a manifest. This also deletes version
    # fields that only upstream added or changed.
    for path in $manifests; do
      if [ -f "$path" ]; then
        bash "$here/fork-manifest.sh" "$path" "$work/manifest" "$path"
        if ! cmp -s "$work/manifest" "$path"; then
          cp "$work/manifest" "$path"
          git add "$path"
          echo "Deleted the version fields in $path."
        fi
      fi
    done
    {
      echo "Merge upstream commit ${candidate:0:12}"
      echo
      echo "Upstream: $upstream_url"
      echo "Commit: $candidate"
      echo "First seen on upstream main: $candidate_seen"
      echo
      echo "Merged by the upstream sync job, which merges an upstream commit only 7 days after"
      echo "it first appeared on upstream main (.github/upstream-sync/README.md)."
    } > "$work/message"
    git commit -q --no-verify -F "$work/message"
    merged=1
  else
    conflict=1
    echo "The merge conflicts in:"
    git diff --name-only --diff-filter=U
  fi
fi

workflow_commits=''
if [ "$merged" = 1 ]; then
  workflow_commits=$(git log --format='%h %s' --full-history refs/remotes/origin/main..HEAD -- .github/workflows)
fi

printf '%s\n' "$now" > "$work/last_checked"
seen_blob=$(git hash-object -w "$work/seen.tsv")
checked_blob=$(git hash-object -w "$work/last_checked")
tree=$(printf '100644 blob %s\tlast_checked\n100644 blob %s\tseen.tsv\n' "$checked_blob" "$seen_blob" | git mktree)
message="Upstream sync check at $now (upstream main $head)"
if [ "$have_state" = 1 ]; then
  state_commit=$(git commit-tree "$tree" -p "refs/remotes/origin/$state_branch" -m "$message")
else
  state_commit=$(git commit-tree "$tree" -m "$message")
fi

if [ "$dry_run" = 1 ]; then
  echo "Dry run: would push $state_branch ($(wc -l < "$work/seen.tsv" | tr -d ' ') rows in seen.tsv, last_checked $now)."
else
  git push -q origin "$state_commit:refs/heads/$state_branch"
  echo "Pushed $state_branch (last_checked $now)."
fi

if [ "$conflict" = 1 ]; then
  die "merging upstream commit $candidate into main conflicts; main was not changed. Merge by hand: see .github/upstream-sync/README.md."
fi
if [ "$merged" = 1 ]; then
  if [ -n "$workflow_commits" ]; then
    echo "These upstream commits change .github/workflows/, which the job's token may not push:"
    echo "$workflow_commits"
  fi
  if [ "$dry_run" = 1 ]; then
    echo "Dry run: would push main as $(git log -1 --format='%h %s')."
  elif git push -q origin HEAD:refs/heads/main; then
    echo "Pushed main: $(git log -1 --format='%h %s')."
  elif [ -n "$workflow_commits" ]; then
    die "pushing main failed: upstream changed .github/workflows/, which the job's token may not push; main was not changed. Merge by hand from the laptop: see .github/upstream-sync/README.md."
  else
    die "pushing main failed; main was not changed."
  fi
fi
