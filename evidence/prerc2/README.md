# Evidence — v0.2.24 focused pre-RC security correction

Disposable test VPS (owner-authorized), Ubuntu 24.04.5, kernel 6.8.0-147, systemd 255, nft 1.0.9.
Sanitized: test hostnames `<test-host-N>`, `<hostname>`, `<machine-id>`, `<public-ip>`, host paths, 32-hex values, proxy links.
`probe.tsv.gz` = raw per-attempt probe samples (`monotonic ns, wall ns, port, OPEN|TIMEOUT|ERR<errno>`).
Secret scan: no live client secret appears in any file (checked against the backend env files, gz included).

| Path | Content |
|---|---|
| `red/fw-v0.2.23-quick` | first RED run on the installed baseline (224 backend OPEN samples) |
| `red/fw-v0.2.23-full` | RED with the final recorder incl. frozen-guard scenario (2,789 OPEN) |
| `red/proc-v0.2.23` | P1-B RED: S1-S4 RED, S5 preserved |
| `green/fw-v0.2.24-dev1`, `green/fw-v0.2.24-final` | P1-A GREEN during development (0 OPEN) |
| `green/proc-v0.2.24` | P1-B GREEN during development |
| `green/final-prerc2` | `tests/prerc2/run-prerc2-real-suite.sh` on the committed candidate code: start-gate fixture, P1-A recorder (0 OPEN / 41,347), no-nftables windows (31.5 s, 0 OPEN), P1-B S1-S5 GREEN |
| `regression/prerc-real` | v0.2.23 real-host harness suite run against v0.2.24 (rollback/restore P1-G-01, guard continuity, DPI ENOSPC, procfs readers, rollback EOF) |
| `regression/model` | model/static suites under the sentinel PATH (41 PASS, 2 NOT_EXECUTED lab-only, 0 sentinel calls) |
| `lifecycle` | delete x2 -> core-uninstall -> clean-host facts -> core-install -> restore -> repair x2 -> audits + HTTPS |
| `results.json` | machine-readable summary (same as handoff RESULTS.json) |
