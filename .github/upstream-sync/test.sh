#!/usr/bin/env bash
# Tests sync.sh on scratch repos: a fake upstream and a fake fork, with SYNC_NOW as the clock.
# Needs git and jq. Usage: bash .github/upstream-sync/test.sh
set -euo pipefail
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
root=$(mktemp -d "${TMPDIR:-/tmp}/upstream-sync-test.XXXXXX")
trap 'rm -rf "$root"' EXIT

# Keep git away from the user's and the system's config, and from the job's settings.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
unset GITHUB_ACTIONS RUNNER_TEMP SYNC_TOKEN SYNC_API_TOKEN SYNC_DRY_RUN SYNC_NOW GIT_CONFIG_COUNT

up=$root/up         # upstream (a plain repo, so a force-push is a reset)
fork=$root/fork.git # the fork's GitHub repo
tab=$(printf '\t')
plugin=plugins/codex/.claude-plugin/plugin.json
marketplace=.claude-plugin/marketplace.json
failures=0

pass() { echo "ok - $1"; }
fail() {
  echo "FAIL - $1"
  sed 's/^/    | /' "$root/out"
  failures=$((failures + 1))
}
check() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}
not() { ! "$@"; }

# An upstream with a workflow of its own, and a fork whose main is upstream's first commit plus the
# fork's own commit: versions deleted, and this repo's .gitattributes, sync files and workflow.
# The fork's pre-receive hook refuses what GitHub refuses the job's token: a new commit on main
# that changes .github/workflows/ compared with its first parent. (GitHub accepts a merge commit
# whose tree has a workflow file that only its second parent lacks; checked on 2026-10-28.)
# GitHub's activity log of upstream is the file $activity, empty unless a test fills it.
setup() {
  rm -rf "$up" "$fork" "$root/clone"
  git init -q -b main "$up"
  mkdir -p "$up/plugins/codex/.claude-plugin" "$up/.claude-plugin" "$up/.github/workflows"
  printf '{\n  "name": "codex",\n  "version": "1.0.0",\n  "description": "d"\n}\n' > "$up/$plugin"
  printf '{\n  "name": "m",\n  "owner": { "name": "o" },\n  "plugins": [\n    { "name": "codex", "source": "./plugins/codex" }\n  ]\n}\n' > "$up/$marketplace"
  printf 'line 1\nline 2\n' > "$up/a.txt"
  printf 'on: pull_request\n' > "$up/.github/workflows/ci.yml"
  up_commit "upstream 0" > /dev/null
  git clone -q --bare "$up" "$fork"
  git clone -q "$fork" "$root/clone"
  cp "$repo_root/.gitattributes" "$root/clone/.gitattributes"
  cp -R "$here" "$root/clone/.github/upstream-sync"
  cp "$repo_root/.github/workflows/upstream-sync.yml" "$root/clone/.github/workflows/"
  jq 'del(.version)' "$up/$plugin" > "$root/clone/$plugin"
  git -C "$root/clone" add -A
  git -C "$root/clone" commit -q -m "fork: delete version, add the sync job"
  git -C "$root/clone" push -q origin main
  cat > "$fork/hooks/pre-receive" << 'EOF'
#!/bin/sh
while read -r old new ref; do
  [ "$ref" = refs/heads/main ] || continue
  for c in $(git rev-list "$old..$new"); do
    if [ -n "$(git diff --name-only "$c^1" "$c" -- .github/workflows)" ]; then
      echo "refusing to allow a GitHub App to create or update workflow without workflows permission" >&2
      exit 1
    fi
  done
done
EOF
  chmod +x "$fork/hooks/pre-receive"
  main0=$(main_head)
  activity=$root/activity.json
  echo '[]' > "$activity"
}

up_commit() {
  git -C "$up" add -A
  git -C "$up" commit -q -m "$1"
  git -C "$up" rev-parse HEAD
}

# run_sync <now> [dry run: 0 or 1]: output in $root/out, exit status in $status.
run_sync() {
  status=0
  SYNC_NOW=$1 SYNC_DRY_RUN=${2:-0} SYNC_ORIGIN_URL=$fork SYNC_UPSTREAM_URL=$up SYNC_ACTIVITY_URL=file://$activity \
    bash "$here/sync.sh" > "$root/out" 2>&1 || status=$?
}

main_head() { git -C "$fork" rev-parse main; }
has_ref() { git -C "$fork" rev-parse -q --verify "$1" > /dev/null; }
state_file() { git -C "$fork" show "upstream-sync-state:$1"; }
in_main() { git -C "$fork" merge-base --is-ancestor "$1" main 2> /dev/null; }
said() { grep -qF -- "$1" "$root/out"; }
succeeded() { [ "$status" = 0 ]; }
equal() { [ "$1" = "$2" ]; }
# rewrite <time> [type]: an entry in GitHub's activity log of upstream's main (default: force_push).
rewrite() {
  jq --arg t "$1" --arg type "${2:-force_push}" '. + [{ref: "refs/heads/main", activity_type: $type, timestamp: $t}]' \
    "$activity" > "$root/activity.new"
  mv "$root/activity.new" "$activity"
}

# put_state <seen.tsv>: replaces seen.tsv on the state branch, as anyone with write access could.
put_state() {
  local blob tree
  blob=$(printf '%s' "$1" | git -C "$fork" hash-object -w --stdin)
  tree=$(printf '100644 blob %s\tseen.tsv\n' "$blob" | git -C "$fork" mktree)
  edited_state=$(git -C "$fork" commit-tree "$tree" -p upstream-sync-state -m "edited state")
  git -C "$fork" update-ref refs/heads/upstream-sync-state "$edited_state"
}

echo "# a missing state branch is created"
setup
u0=$(git -C "$up" rev-parse HEAD)
run_sync 2026-01-01T00:00:00Z
check "first run succeeds" succeeded
check "state branch exists" has_ref refs/heads/upstream-sync-state
check "seen.tsv lists upstream's head with the time" equal "$(state_file seen.tsv)" "$u0${tab}2026-01-01T00:00:00Z"
check "last_checked is the time" equal "$(state_file last_checked)" 2026-01-01T00:00:00Z
check "main is unchanged" equal "$(main_head)" "$main0"

echo "# no merge before 7 days, a merge after"
setup
run_sync 2026-01-01T00:00:00Z
printf 'line 1\nupstream line 2\n' > "$up/a.txt"
u1=$(up_commit "upstream 1")
run_sync 2026-01-02T00:00:00Z
run_sync 2026-01-08T23:59:59Z
check "a run 1 second before 7 days succeeds" succeeded
check "it merges nothing" equal "$(main_head)" "$main0"
check "it updates last_checked" equal "$(state_file last_checked)" 2026-01-08T23:59:59Z
run_sync 2026-01-09T00:00:00Z
check "a run at 7 days succeeds" succeeded
check "main's first parent is the old main" equal "$(git -C "$fork" rev-parse main^1)" "$main0"
check "main's second parent is the upstream commit" equal "$(git -C "$fork" rev-parse main^2)" "$u1"
check "the merge message names the commit" grep -qF "Commit: $u1" <(git -C "$fork" log -1 --format=%B main)
check "the merge message says since when it was on upstream main" \
  grep -qF "On upstream main since: 2026-01-02T00:00:00Z" <(git -C "$fork" log -1 --format=%B main)
merged=$(main_head)
run_sync 2026-01-10T00:00:00Z
check "a later run succeeds" succeeded
check "it says the commit is already in main" said "is already in main"
check "it merges nothing" equal "$(main_head)" "$merged"

echo "# the newest commit seen at least 7 days ago is merged, not a newer one"
setup
printf 'line 1\nx\n' > "$up/a.txt"
u1=$(up_commit "upstream 1")
run_sync 2026-01-01T00:00:00Z
printf 'line 1\ny\n' > "$up/a.txt"
u2=$(up_commit "upstream 2")
run_sync 2026-01-04T00:00:00Z
run_sync 2026-01-08T00:00:00Z
check "the run succeeds" succeeded
check "the commit seen 7 days ago is in main" in_main "$u1"
check "the commit seen 4 days ago is not" not in_main "$u2"

echo "# a re-pushed commit counts only from its re-push"
setup
printf 'line 1\nm\n' > "$up/a.txt"
m=$(up_commit "m")
run_sync 2026-01-01T00:00:00Z
git -C "$up" reset -q --hard HEAD~1
printf 'line 1\nx\n' > "$up/a.txt"
x=$(up_commit "x")
run_sync 2026-01-02T00:00:00Z
git -C "$up" reset -q --hard "$m"
run_sync 2026-01-04T00:00:00Z
check "seen.tsv logs the re-pushed commit again" equal "$(state_file seen.tsv | cut -f1 | tr '\n' ' ')" "$m $x $m "
run_sync 2026-01-10T23:59:59Z
check "a run 7 days after its first row succeeds" succeeded
check "it skips the first row" said "Skipping $m (on upstream main at 2026-01-01T00:00:00Z)"
check "it merges nothing" equal "$(main_head)" "$main0"
run_sync 2026-01-11T00:00:00Z
check "7 days after the re-push, the commit is merged" equal "$(git -C "$fork" rev-parse main^2)" "$m"
check "the commit that replaced it for 2 days is not in main" not in_main "$x"

echo "# a commit reverted within the week is still merged on day 7, as with packages"
setup
run_sync 2026-01-01T00:00:00Z
printf 'line 1\nbad\n' > "$up/a.txt"
m=$(up_commit "bad")
run_sync 2026-01-02T00:00:00Z
git -C "$up" revert --no-edit HEAD > /dev/null
r=$(git -C "$up" rev-parse HEAD)
run_sync 2026-01-03T00:00:00Z
run_sync 2026-01-09T00:00:00Z
check "the run on day 7 succeeds" succeeded
check "it merges the reverted commit" equal "$(git -C "$fork" rev-parse main^2)" "$m"
run_sync 2026-01-10T00:00:00Z
check "the revert follows a day later" equal "$(git -C "$fork" rev-parse main^2)" "$r"

echo "# an upstream version bump merges without a conflict and the version stays deleted"
setup
printf '{\n  "name": "codex",\n  "version": "1.0.1",\n  "description": "d2"\n}\n' > "$up/$plugin"
jq '.plugins[0].version = "1.0.1"' "$up/$marketplace" > "$root/m.json" && mv "$root/m.json" "$up/$marketplace"
up_commit "bump to 1.0.1" > /dev/null
run_sync 2026-01-01T00:00:00Z
run_sync 2026-01-08T00:00:00Z
check "the run succeeds" succeeded
check "main has the merge" equal "$(git -C "$fork" rev-parse main^1)" "$main0"
check "plugin.json is upstream's without the version" \
  equal "$(git -C "$fork" show "main:$plugin" | jq -c .)" '{"name":"codex","description":"d2"}'
check "marketplace.json has no version" \
  equal "$(git -C "$fork" show "main:$marketplace" | jq -c '[.plugins[] | has("version")]')" '[false]'

echo "# a conflict fails the job and leaves main unchanged"
setup
printf 'fork line 1\nline 2\n' > "$root/clone/a.txt"
git -C "$root/clone" commit -q -am "fork change"
git -C "$root/clone" push -q origin main
main0=$(main_head)
printf 'upstream line 1\nline 2\n' > "$up/a.txt"
up_commit "upstream change" > /dev/null
run_sync 2026-01-01T00:00:00Z
run_sync 2026-01-08T00:00:00Z
check "the run fails" not succeeded
check "it names the conflict" said "conflicts"
check "main is unchanged" equal "$(main_head)" "$main0"
check "the state branch is still updated" equal "$(state_file last_checked)" 2026-01-08T00:00:00Z

echo "# a backdated commit does not count as old"
setup
printf 'line 1\nold\n' > "$up/a.txt"
git -C "$up" add -A
GIT_AUTHOR_DATE=2020-01-01T00:00:00Z GIT_COMMITTER_DATE=2020-01-01T00:00:00Z git -C "$up" commit -q -m "backdated"
run_sync 2026-01-01T00:00:00Z
run_sync 2026-01-02T00:00:00Z
check "the run succeeds" succeeded
check "it merges nothing" equal "$(main_head)" "$main0"

echo "# a commit that a force-push removed from upstream is skipped"
setup
printf 'line 1\nbad\n' > "$up/a.txt"
bad=$(up_commit "bad")
run_sync 2026-01-01T00:00:00Z
git -C "$up" reset -q --hard HEAD~1
printf 'line 1\ngood\n' > "$up/a.txt"
good=$(up_commit "good")
run_sync 2026-01-02T00:00:00Z
run_sync 2026-01-08T01:00:00Z
check "the run succeeds" succeeded
check "it skips the removed commit" said "Skipping $bad"
check "it merges nothing" equal "$(main_head)" "$main0"
run_sync 2026-01-09T00:00:00Z
check "a run 7 days after the new head succeeds" succeeded
check "the new head is in main" in_main "$good"
check "the removed commit is not" not in_main "$bad"

echo "# a dry run pushes nothing"
setup
printf 'line 1\nupstream line 2\n' > "$up/a.txt"
up_commit "upstream 1" > /dev/null
refs_before=$(git -C "$fork" for-each-ref)
run_sync 2026-01-01T00:00:00Z 1
check "a dry run without a state branch succeeds" succeeded
check "it creates no state branch" equal "$(git -C "$fork" for-each-ref)" "$refs_before"
run_sync 2026-01-01T00:00:00Z
refs_before=$(git -C "$fork" for-each-ref)
run_sync 2026-01-08T00:00:00Z 1
check "a dry run with a commit to merge succeeds" succeeded
check "it says it would push main" said "Dry run: would push main"
check "it pushes nothing" equal "$(git -C "$fork" for-each-ref)" "$refs_before"

echo "# upstream changes to .github/ or .gitattributes are never merged"
for change in "a new workflow" "a mode change" "a symlink" "a .gitattributes"; do
  setup
  case $change in
    "a new workflow") printf 'on: push\n' > "$up/.github/workflows/new.yml" ;;
    "a mode change") chmod +x "$up/.github/workflows/ci.yml" ;;
    "a symlink") ln -s ../a.txt "$up/.github/link" ;;
    "a .gitattributes") printf '* text=auto\n' > "$up/.gitattributes" ;;
  esac
  up_commit "$change" > /dev/null
  run_sync 2026-01-01T00:00:00Z
  run_sync 2026-01-08T00:00:00Z
  check "$change: the run fails" not succeeded
  check "$change: it says to merge by hand" said "Merge by hand from a machine whose token may push workflow files"
  check "$change: main is unchanged" equal "$(main_head)" "$main0"
  check "$change: the state branch is still updated" equal "$(state_file last_checked)" 2026-01-08T00:00:00Z
done

echo "# upstream cannot take over the sync script, in one step or two"
setup
mkdir -p "$up/.github/upstream-sync"
cp "$here/sync.sh" "$up/.github/upstream-sync/sync.sh"
u1=$(up_commit "a copy of the fork's sync.sh")
check "upstream's copy is the same file, mode included" \
  equal "$(git -C "$up" ls-tree HEAD .github/upstream-sync/sync.sh)" "$(git -C "$fork" ls-tree main .github/upstream-sync/sync.sh)"
run_sync 2026-01-01T00:00:00Z
run_sync 2026-01-08T00:00:00Z
check "the identical copy is not merged" not in_main "$u1"
check "the run fails" not succeeded
# Someone merges the copy by hand; then upstream edits the script.
git -C "$root/clone" fetch -q "$up" main
git -C "$root/clone" merge -q --no-ff --no-edit FETCH_HEAD
git -C "$root/clone" push -q origin main
main1=$(main_head)
printf 'echo replaced\n' >> "$up/.github/upstream-sync/sync.sh"
up_commit "edit the sync script" > /dev/null
run_sync 2026-01-09T00:00:00Z
run_sync 2026-01-16T00:00:00Z
check "the edit fails the run" not succeeded
check "it says to merge by hand" said "Merge by hand from a machine whose token may push workflow files"
check "main and its sync.sh are unchanged" equal "$(main_head)" "$main1"

echo "# GitHub's activity log: a force-push after a commit's row blocks it"
setup
printf 'line 1\nm\n' > "$up/a.txt"
m=$(up_commit "m")
run_sync 2026-01-01T00:00:00Z
# Upstream removed and restored m between two runs: only GitHub's activity log shows it.
rewrite 2026-01-03T10:00:00Z
rewrite 2026-01-03T11:00:00Z
run_sync 2026-01-08T00:00:00Z
check "the run succeeds" succeeded
check "it names the force-push" said "2026-01-03T11:00:00Z force_push"
check "it merges nothing" equal "$(main_head)" "$main0"
check "it logs the head again, as of now" \
  equal "$(state_file seen.tsv | tr '\n' ' ')" "$m${tab}2026-01-01T00:00:00Z $m${tab}2026-01-08T00:00:00Z "
run_sync 2026-01-14T23:59:59Z
check "6 days later it still merges nothing" equal "$(main_head)" "$main0"
run_sync 2026-01-15T00:00:00Z
check "7 days after the new row, the commit is merged" equal "$(git -C "$fork" rev-parse main^2)" "$m"

echo "# GitHub's activity log: a deletion of upstream's main after a commit's row blocks it"
setup
printf 'line 1\nm\n' > "$up/a.txt"
up_commit "m" > /dev/null
run_sync 2026-01-01T00:00:00Z
rewrite 2026-01-02T00:00:00Z branch_deletion
run_sync 2026-01-08T00:00:00Z
check "the run succeeds" succeeded
check "it merges nothing" equal "$(main_head)" "$main0"

echo "# GitHub's activity log: a force-push before a commit's row, or a plain push, does not block it"
setup
rewrite 2025-12-31T00:00:00Z
rewrite 2026-01-02T00:00:00Z push
printf 'line 1\nm\n' > "$up/a.txt"
m=$(up_commit "m")
run_sync 2026-01-01T00:00:00Z
run_sync 2026-01-08T00:00:00Z
check "the run succeeds" succeeded
check "the commit is merged" equal "$(git -C "$fork" rev-parse main^2)" "$m"

echo "# GitHub's activity log: if it cannot be read, the job fails and merges nothing"
for response in missing '{"message": "Not Found"}' '[{"ref": "refs/heads/main", "activity_type": "force_push"}]'; do
  setup
  printf 'line 1\nm\n' > "$up/a.txt"
  up_commit "m" > /dev/null
  run_sync 2026-01-01T00:00:00Z
  if [ "$response" = missing ]; then rm "$activity"; else printf '%s\n' "$response" > "$activity"; fi
  run_sync 2026-01-08T00:00:00Z
  check "response $response: the run fails" not succeeded
  check "response $response: it names the activity log" said "activity log"
  check "response $response: main is unchanged" equal "$(main_head)" "$main0"
  check "response $response: the state branch is still updated" equal "$(state_file last_checked)" 2026-01-08T00:00:00Z
done

echo "# a malformed seen.tsv fails the job and pushes nothing"
setup
run_sync 2026-01-01T00:00:00Z
u0=$(git -C "$up" rev-parse HEAD)
nl=$'\n'
for content in "not a commit${tab}2026-01-01T00:00:00Z$nl" \
  "$u0${tab}2026-01-03T00:00:00Z$nl$u0${tab}2026-01-01T00:00:00Z$nl" \
  "$u0${tab}2026-01-01T00:00:00Z"; do
  put_state "$content"
  run_sync 2026-01-04T00:00:00Z
  check "the run fails" not succeeded
  check "it names the problem" said "seen.tsv on upstream-sync-state"
  check "the state branch is unchanged" equal "$(git -C "$fork" rev-parse upstream-sync-state)" "$edited_state"
done

echo "# a clock behind the last row fails the job and pushes nothing"
setup
run_sync 2026-01-05T00:00:00Z
state_before=$(git -C "$fork" rev-parse upstream-sync-state)
printf 'line 1\nm\n' > "$up/a.txt"
up_commit "m" > /dev/null
run_sync 2026-01-04T00:00:00Z
check "the run fails" not succeeded
check "it says the clock is behind" said "the clock is behind its last row"
check "the state branch is unchanged" equal "$(git -C "$fork" rev-parse upstream-sync-state)" "$state_before"

echo "# a commit that upstream removes after the fork merged it fails the job"
setup
printf 'line 1\nm\n' > "$up/a.txt"
m=$(up_commit "m")
run_sync 2026-01-01T00:00:00Z
run_sync 2026-01-08T00:00:00Z
check "the commit is merged on day 7" equal "$(git -C "$fork" rev-parse main^2)" "$m"
merged=$(main_head)
git -C "$up" reset -q --hard HEAD~1
printf 'line 1\nx\n' > "$up/a.txt"
up_commit "x" > /dev/null
run_sync 2026-01-09T00:00:00Z
check "the next run fails" not succeeded
check "it names the removed commit" said "upstream removed from its main commits that this fork merged ($m)"
check "main is unchanged" equal "$(main_head)" "$merged"
check "the state branch is still updated" equal "$(state_file last_checked)" 2026-01-09T00:00:00Z

echo "# a commit that waits 30 days fails the job, saying why"
setup
printf 'line 1\nm\n' > "$up/a.txt"
up_commit "m" > /dev/null
run_sync 2026-01-01T00:00:00Z
for day in 02 09 16 23; do
  rewrite "2026-01-${day}T00:00:00Z"
  run_sync "2026-01-$((10#$day + 6))T00:00:00Z"
done
run_sync 2026-01-30T23:59:59Z
check "29 days and 23:59:59 after the commit was logged, the run succeeds" succeeded
run_sync 2026-01-31T00:00:00Z
check "after 30 days, the run fails" not succeeded
check "it says the job could not merge for 30 days" said "has not been able to merge upstream commit"
check "it says why" said "This run: upstream's main was force-pushed or deleted"
check "main is unchanged" equal "$(main_head)" "$main0"

echo "# merges on top of earlier sync merges, with merge commits upstream"
setup
printf 'line 1\nu1\n' > "$up/a.txt"
up_commit "u1" > /dev/null
run_sync 2026-01-01T00:00:00Z
run_sync 2026-01-08T00:00:00Z
first_merge=$(main_head)
git -C "$up" checkout -q -b feature
printf 'feature\n' > "$up/b.txt"
up_commit "feature" > /dev/null
git -C "$up" checkout -q main
printf '{\n  "name": "codex",\n  "version": "1.0.2",\n  "description": "d"\n}\n' > "$up/$plugin"
up_commit "bump to 1.0.2" > /dev/null
git -C "$up" merge -q --no-ff --no-edit feature
u3=$(git -C "$up" rev-parse HEAD)
run_sync 2026-01-09T00:00:00Z
run_sync 2026-01-16T00:00:00Z
check "the run succeeds" succeeded
check "main's first parent is the earlier sync merge" equal "$(git -C "$fork" rev-parse main^1)" "$first_merge"
check "main's second parent is upstream's merge commit" equal "$(git -C "$fork" rev-parse main^2)" "$u3"
check "plugin.json still has no version" equal "$(git -C "$fork" show "main:$plugin" | jq 'has("version")')" false
check "the fork's sync job is unchanged" \
  equal "$(git -C "$fork" rev-parse main:.github)" "$(git -C "$fork" rev-parse "$main0:.github")"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed."
