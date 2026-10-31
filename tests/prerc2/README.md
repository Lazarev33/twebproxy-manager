# v0.2.24 focused security correction — real-host gates

Real privileged tests for the two P1 findings of the rejected v0.2.23 acceptance.
They use the installed-host gate of `tests/lib/lab-gate.sh`: they run only with
`TWEBPROXY_PRERC_REAL=installed-test-host`, as root, on a host whose root-owned
`/etc/twebproxy-disposable-lab` holds `/etc/machine-id`, with an installed
TWebProxy; everywhere else they exit 77 before any privileged command.
Only port numbers, counts and booleans are recorded, never a secret.

| Script | Proves |
|---|---|
| `fw_owner_loss_probe.py OUT [--quick]` | P1-A. A peer network namespace (veth, non-loopback path into the host input hook) connects to every backend client and stats port every ~7 ms per port, alongside a control listener, `nft monitor` and a 100 ms state watcher. Scenarios: ordinary nftables/firewall transitions, daemon-reload, backend restarts, a direct foreign `flush ruleset`; SIGKILL of the owning `nft -i` child with a concurrent nftables restart, with concurrent backend restarts, with a direct flush; SIGKILL of the guard shell; concurrent firewall + nftables + backend restarts + daemon-reload; a **frozen guard shell** (SIGSTOP) with the owner killed and the ruleset flushed, held for 10 s (nothing reacts — only the per-backend cgroup filter remains); the owner killed during a firewall restart and a flush. Exit 0 only with zero backend OPEN samples, a reachable control port and recovery of every unit after every fault. |
| `no_table_windows.py OUT` | From the recorder output: every interval in which no TWebProxy nftables table existed while MTProxy processes were alive, and what the probe saw inside them. |
| `proc_ns_scenario.py` | Inner helper (run under `unshare -m --propagation private`): stacks an unprotected proc mount over `/proc`, optionally injects a failing `mount`, runs a manager command and counts readable `-S` arguments as `nobody` through the effective `/proc`. |
| `proc_fail_closed_probe.sh MANAGER OUT` | P1-B. S1 failed remount + `repair`; S2 failed remount + `restart`; S3 stacked proc mounts + `repair` (no injected failure); S4 host `/proc` unprotected without opt-out, then systemd restarts a backend and the firewall (start gate); S5 explicit operator opt-out honoured, logged, audited WARNING, re-enabled. Each scenario is followed by a `repair` of every instance to restore the steady state. |
| `start-gate-fixture.sh` | Model test of `backend_start_check_main`, the generated helper and the unit contract (no host access). |
| `prerc2-scope-invariants.sh V0223_TREE` | Static scope against v0.2.23: only the listed functions change; the Stage 4 update/rollback/offline-restore sets are byte-identical. |
| `run-prerc2-real-suite.sh MANAGER OUT [--quick]` | Runs the gates in order. |

RED is obtained by pointing `MANAGER` at the v0.2.23 script (and installing it
with its own `repair` before the firewall recorder); GREEN with v0.2.24.
