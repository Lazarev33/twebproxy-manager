#!/usr/bin/env bash
# Runs tests/stageg/real-process-oracle.py (needs python3); exit 77 without it.
command -v python3 >/dev/null 2>&1 || { echo 'NOT_EXECUTED real-process-oracle: python3 missing'; exit 77; }
exec python3 -I "$(dirname "${BASH_SOURCE[0]}")/real-process-oracle.py" "$@"
