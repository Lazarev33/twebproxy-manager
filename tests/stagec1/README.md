# Stage C1 verification

Profile/instance state integrity (F03 identity, F04 persistence, F05
concurrency, F13 port allocation). Model tests only: safe on any Linux test
workstation with Bash, jq, coreutils and util-linux; no system state changes.

```sh
bash tests/stagec1/run-stage-c1-suite.sh            # exit 0 PASS, 1 FAIL, 77 INCOMPLETE
bash tests/stagec1/c1-scope-invariants.sh <v0.2.13 source tree>
bash tests/stagec1/c11-scope-invariants.sh <v0.2.14 source tree>
bash tests/stagec1/c12-scope-invariants.sh <v0.2.15 source tree>
```

`state-harness.sh` runs the unmodified manager code with only the host boundary
replaced (systemctl/ss/curl/journalctl models, a jq-based `tproxy-server -check`,
scripted prompts). Commands run through `c1_run`/`c1_eval` in a separate bash
process with production `set -Eeuo pipefail`: bash ignores errexit inside an
`if` condition even in a `( set -e; ... )` subshell, which would hide failures.

Write failures are injected command failures (one-shot `printf`/`jq` faults),
not a real ENOSPC; races use barriers inside interactive prompts, not timing.
None of this proves real systemd, flock-under-load or filesystem behaviour.
