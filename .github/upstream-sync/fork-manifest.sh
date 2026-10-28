#!/usr/bin/env bash
# Writes a plugin manifest without its version fields: usage fork-manifest.sh <source> <destination> <repo path>.
# Git runs it as the merge driver "fork-manifest" (see .gitattributes) with upstream's file as the source,
# so the merge result is upstream's file without the version fields. sync.sh also runs it after each merge.
# Without a version, Claude Code updates the plugin on every new commit of the fork.
set -euo pipefail

src=$1 dest=$2 path=$3
if [ "$src" -ef "$dest" ]; then
  echo "fork-manifest.sh: source and destination must be different files" >&2
  exit 1
fi

case $path in
  plugins/codex/.claude-plugin/plugin.json)
    has_version='has("version")'
    strip='del(.version)'
    ;;
  .claude-plugin/marketplace.json)
    has_version='any(.plugins[]?; has("version"))'
    strip='del(.plugins[]?.version)'
    ;;
  *)
    echo "fork-manifest.sh: not a plugin manifest: $path" >&2
    exit 1
    ;;
esac

# Exits here on invalid JSON, which makes git report a conflict.
has=$(jq "$has_version" "$src")
if [ "$has" = true ]; then
  jq "$strip" "$src" > "$dest"
else
  # Keep the file byte for byte when there is nothing to delete.
  cat "$src" > "$dest"
fi
