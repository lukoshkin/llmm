#!/usr/bin/env sh
# SessionStart (compact) hook: re-inject only the always-on sections after compaction.
# Args: <scratchpad-dir> <session-id>
dir=$1
id=$2
f="$dir/$id.md"
[ -f "$f" ] || exit 0

awk '
  /^## / { keep = ($0 == "## Status" || $0 == "## Open questions") }
  keep { print }
' "$f"

printf '\nOther sections available on demand via recall(findings|decisions|dead_ends).\n'
exit 0
