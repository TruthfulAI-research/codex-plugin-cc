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
unset GITHUB_ACTIONS RUNNER_TEMP SYNC_TOKEN SYNC_DRY_RUN SYNC_NOW GIT_CONFIG_COUNT

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

# A fork whose main is upstream's first commit plus the fork's own commit (versions deleted,
# .gitattributes from this repo). Its pre-receive hook refuses workflow changes on main, as
# GitHub does for the job's token.
setup() {
  rm -rf "$up" "$fork" "$root/clone"
  git init -q -b main "$up"
  mkdir -p "$up/plugins/codex/.claude-plugin" "$up/.claude-plugin"
  printf '{\n  "name": "codex",\n  "version": "1.0.0",\n  "description": "d"\n}\n' > "$up/$plugin"
  printf '{\n  "name": "m",\n  "owner": { "name": "o" },\n  "plugins": [\n    { "name": "codex", "source": "./plugins/codex" }\n  ]\n}\n' > "$up/$marketplace"
  printf 'line 1\nline 2\n' > "$up/a.txt"
  up_commit "upstream 0" > /dev/null
  git clone -q --bare "$up" "$fork"
  git clone -q "$fork" "$root/clone"
  cp "$repo_root/.gitattributes" "$root/clone/.gitattributes"
  jq 'del(.version)' "$up/$plugin" > "$root/clone/$plugin"
  git -C "$root/clone" add -A
  git -C "$root/clone" commit -q -m "fork: delete version, add merge driver"
  git -C "$root/clone" push -q origin main
  cat > "$fork/hooks/pre-receive" << 'EOF'
#!/bin/sh
while read -r old new ref; do
  if [ "$ref" = refs/heads/main ] && [ -n "$(git rev-list --full-history "$old..$new" -- .github/workflows)" ]; then
    echo "refusing to allow a GitHub App to create or update workflow without workflows permission" >&2
    exit 1
  fi
done
EOF
  chmod +x "$fork/hooks/pre-receive"
  main0=$(main_head)
}

up_commit() {
  git -C "$up" add -A
  git -C "$up" commit -q -m "$1"
  git -C "$up" rev-parse HEAD
}

# run_sync <now> [dry run: 0 or 1]: output in $root/out, exit status in $status.
run_sync() {
  status=0
  SYNC_NOW=$1 SYNC_DRY_RUN=${2:-0} SYNC_ORIGIN_URL=$fork SYNC_UPSTREAM_URL=$up \
    bash "$here/sync.sh" > "$root/out" 2>&1 || status=$?
}

main_head() { git -C "$fork" rev-parse main; }
has_ref() { git -C "$fork" rev-parse -q --verify "$1" > /dev/null; }
state_file() { git -C "$fork" show "upstream-sync-state:$1"; }
in_main() { git -C "$fork" merge-base --is-ancestor "$1" main 2> /dev/null; }
said() { grep -qF -- "$1" "$root/out"; }
succeeded() { [ "$status" = 0 ]; }
equal() { [ "$1" = "$2" ]; }

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
check "the merge message says when it was first seen" grep -qF "First seen on upstream main: 2026-01-02T00:00:00Z" <(git -C "$fork" log -1 --format=%B main)
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

echo "# an upstream change to .github/workflows/ fails the push with a message"
setup
mkdir -p "$up/.github/workflows"
printf 'on: push\n' > "$up/.github/workflows/ci.yml"
up_commit "add a workflow" > /dev/null
run_sync 2026-01-01T00:00:00Z
run_sync 2026-01-08T00:00:00Z
check "the run fails" not succeeded
check "it says to merge by hand from the laptop" said "Merge by hand from the laptop"
check "main is unchanged" equal "$(main_head)" "$main0"
check "the state branch is still updated" equal "$(state_file last_checked)" 2026-01-08T00:00:00Z

echo "# a malformed seen.tsv fails the job and pushes nothing"
setup
run_sync 2026-01-01T00:00:00Z
blob=$(printf 'not a commit\t2026-01-01T00:00:00Z\n' | git -C "$fork" hash-object -w --stdin)
tree=$(printf '100644 blob %s\tseen.tsv\n' "$blob" | git -C "$fork" mktree)
bad_state=$(git -C "$fork" commit-tree "$tree" -p upstream-sync-state -m "bad state")
git -C "$fork" update-ref refs/heads/upstream-sync-state "$bad_state"
run_sync 2026-01-02T00:00:00Z
check "the run fails" not succeeded
check "it names the problem" said "malformed line"
check "the state branch is unchanged" equal "$(git -C "$fork" rev-parse upstream-sync-state)" "$bad_state"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed."
