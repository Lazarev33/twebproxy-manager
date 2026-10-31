# Stage F verification

Manager self-update and supply chain: only a stable GitHub Release is a
candidate (never a development branch); authenticity from a signed release
manifest (pinned Ed25519 key) or an operator-pinned SHA-256, never from a
same-source `SHA256SUMS`; strict release/manifest/artifact validation, refused
redirects, interrupted and truncated downloads; a bounded update lock that is
released on every return, never inherited by health probes and shared with the
manager-copy synchronisation of add/repair/update; staging cleanup; signals
deferred between the two installed copies; verified success, unchanged and
rollback outcomes; offline recovery. Model tests only; no system state changes.

```sh
bash tests/stagef/run-stage-f-suite.sh              # exit 0 PASS, 1 FAIL, 77 INCOMPLETE
bash tests/stagef/updater-fixture.sh [<manager>] [<case regex>]
bash tests/stagef/f-scope-invariants.sh <v0.2.19 source tree>
bash tests/stagef/updater-function-hashes.sh <manager>   # per-function SHA-256 (heredoc-aware)
```

`updater-harness.sh` runs each command against the unmodified manager in a
separate `bash` with production `set -Eeuo pipefail` and its ERR trap; only paths
are rebound into a temporary case directory. The real lock, staging, backup,
install, health gate, rollback, offline helper, `flock`, `jq` and `openssl` run;
installed managers and releases are small fake managers answering the health
probes. A curl model serves a modeled GitHub (API, raw, release downloads and
asset hosts) with redirect, partial/truncated-transfer and offline faults; `mv`
and `install` layers inject a failed rename, a failed backup write and a barrier
between the two copies. Release-signing keys are ephemeral Ed25519 keys created
per run; they are never pinned in the shipped manager. Needs root (sandboxed
`chown`/`flock`), otherwise exit 77.

Not proven here: real GitHub (API answers, asset redirects, rate limits), a real
signed release, SSH-session loss and power loss on a real host, real
`/run/lock` and `/usr/local/sbin` — disposable-VM gates before an RC.
