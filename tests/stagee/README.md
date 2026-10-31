# Stage E verification

Operations and diagnostics: prompts and menus under end of input (Ctrl-D,
closed stdin), malformed numbers and Ctrl-C; bounded read-only probes in
status, overview, audit, diagnose and the runtime snapshot; truthful states
(UNKNOWN for what could not be observed, INCOMPLETE audits, worst-state
dashboard); report bundles (re-applied redaction including private keys and URL
credentials, skipped unreadable logs, cleanup of staging and partial archives,
no unrelated routing tables). Model tests only; no system state changes.

```sh
bash tests/stagee/run-stage-e-suite.sh             # exit 0 PASS, 1 FAIL, 77 INCOMPLETE
bash tests/stagee/operations-fixture.sh [<manager>]
bash tests/stagee/e-scope-invariants.sh <v0.2.18 source tree>
```

`ops-harness.sh` extends the Stage D frontend harness. The real prompts, audit
and renderers run (the C1 harness's scripted answers are replaced by stdin);
`nft`, `ip`, `hostnamectl`, `dig`, `getent` and `openssl s_client` are models,
and systemctl, curl, journalctl and tar get hang/fail/barrier fault layers.
`DPI_NFT_BIN` is rebound to the nft model; nothing reads the host's firewall.
Hung probes are detected with an outer `timeout`; `TWEBPROXY_DIAG_TIMEOUT` is
shortened for the model.

Not proven here: real systemd/D-Bus stalls, real TTY Ctrl-D/Ctrl-C behaviour,
journald on large journals and real tcpdump/field captures — disposable-VM
gates before an RC.
