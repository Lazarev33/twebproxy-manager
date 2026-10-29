#!/usr/bin/env bash
# Stage H static guard: no backtick inside an unquoted heredoc of the manager.
# An unquoted heredoc (<<EOF) expands $(...) and `...`; a backtick in help or
# message text there runs that text as a command (it did once, in a draft of the
# Stage H help: `sudo twebproxy` executed the installed manager). Text meant to
# be printed uses plain quotes; deliberate expansions use $(...).
# Usage: heredoc-guard.sh [path/to/twebproxy-manager.sh]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MGR="${1:-$ROOT/twebproxy-manager.sh}"
awk '
  term == "" {
    if ($0 ~ /^[[:space:]]*#/) next
    if (match($0, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
      tok = substr($0, RSTART, RLENGTH)
      if (RSTART > 1 && substr($0, RSTART - 1, 1) == "<") next   # here-string <<<
      quoted = (tok ~ /["\047]/)
      dash = (tok ~ /^<<-/)
      sub(/^<<-?[[:space:]]*["\047]?/, "", tok); sub(/["\047]$/, "", tok)
      term = tok; start = NR
    }
    next
  }
  {
    cur = $0; if (dash) sub(/^\t+/, "", cur)
    if (cur == term) { term = ""; next }
    if (!quoted && index($0, "`") > 0) { printf "unquoted heredoc (line %d) has a backtick at line %d: %s\n", start, NR, $0; bad = 1 }
  }
  END { exit bad }
' "$MGR" && echo 'heredoc-guard: PASS (no backtick in an unquoted heredoc)'
