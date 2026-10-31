# v0.2.23 pre-RC corrections — real-host harnesses

These scripts test privileged behaviour on a **real, installed** TWebProxy on a
host the owner marked disposable (`/etc/twebproxy-disposable-lab` containing the
machine-id, see `tests/LAB.md`). They refuse everywhere else with exit 77
(`installed_host_gate_or_exit` in `tests/lib/lab-gate.sh`; the Python harness
applies the same checks). They print booleans and hashes only, never secrets.

| Script | Proves |
|---|---|
| `fw-transition-probe.sh` | From a non-loopback peer (netns + veth, Python connect probe every ~50 ms per port, `nft monitor` alongside): no MTProxy client port is reachable during `systemctl start/reload/restart/stop nftables`, firewall restart/reload/stop/start, `twebproxy repair` and a cold start (`multi-user.target`); a valid foreign `inet` table survives TWebProxy's own transitions; every relay/backend unit is active after every step except an explicit firewall stop (P1-EXPOSURE-01, P1-STOP-01). |
| `guard-continuity-real.sh` | The owned guard is the same kernel object (table handle, owning `nft` PID) across every nftables.service transition - never deleted, so no gap between samples. |
| `restore-metadata-real.py` | Installed paths, real updater/backup/offline helper, `chattr +i` on the real `global.env`: offline restore and `manager-rollback` report `RESTORE_PARTIAL … metadata=stale` with status 3, never `RESTORE_SUCCESS`; `repair` fails while immutable and fixes the metadata afterwards (P1-G-01). |
| `proc-secret-real.sh` | `www-data`, `nobody`, `caddy` cannot see the backend processes or read the `-S` argument (P1-INHERITED-01). |
| `dpi-enospc-real.sh` | Real ENOSPC (16 KiB tmpfs) during `dpi set`: no false "previous state restored"; `dpi status` reports a recorded-vs-kernel divergence explicitly. |
| `quick-setup-pty.py` | Drives the installed `twebproxy add` Quick Setup on a pseudo-terminal (used for the Caddy certificate-wait check). |
| `prerc-scope-invariants.sh` | Static scope against the v0.2.22 tree (functions, variables, files, Stage 4 hashes). |
| `run-prerc-real-suite.sh` | Runs the real-host harnesses in order. |

```sh
TWEBPROXY_PRERC_REAL=installed-test-host bash tests/prerc/run-prerc-real-suite.sh <hostname> <out-dir>
bash tests/prerc/prerc-scope-invariants.sh <v0.2.22 source tree>
```

Sampling limits: the connect probe cannot see a sub-50 ms window by itself;
`guard-continuity-real.sh` closes that gap for nftables.service transitions by
showing the guard is never re-created. A real cold boot was not repeated
(no reboot authorized); boot ordering is covered by `multi-user.target` start,
`After=`/`BindsTo=` and the existing independent cold-boot evidence for v0.2.22.
