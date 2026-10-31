# Stage B / B.1 verification

Default runs are model/static only and change no system nft, systemd or mount
state. They are safe on any Linux test workstation with Bash, jq, coreutils and
util-linux:

```sh
bash tests/stageb/run-stage-b-suite.sh    # exit 0 PASS, 1 FAIL, 77 INCOMPLETE
```

Model/static cases:

- `transaction-fixture.sh` — apply/verify/publish/rollback control flow.
- `libexec-permissions-fixture.sh` — F1: rebuild keeps `LIBEXEC_DIR`
  root:root 0755 (start and reload path), leaves other entries untouched, lets
  an unprivileged account run a service entrypoint, keeps `BASE_DIR` private,
  restores a v0.2.12-damaged 0700 directory, refuses a symlinked directory.
- `apply-ambiguity-fixture.sh` — R3: `nft -f` failing after the kernel
  committed; truthful message, previous table restored or new isolation kept.
- `firewall-unit-fixture.sh` — generated unit contract, including R1
  `ReloadPropagatedFrom=nftables.service`.
- `lab-gate-fixture.sh` — R5: real tests refuse to run without a prepared lab
  host; no privileged command in a default run.
- `json-verifier-fixture.sh`, `../fieldgate/tg7-backend-state-isolation.sh`.

The nft/service model proves control flow and file postconditions, **not**
kernel atomicity or real systemd behaviour.

`real-nft-validation.sh` and `real-systemd-validation.sh` are part of the suite
but run only on a disposable lab host; see `tests/LAB.md`. Elsewhere they
report `NOT_EXECUTED` and the suite is `INCOMPLETE`. Exit 77 /
`NOT_EXECUTED_ENVIRONMENT_LIMITATION` must never be counted as PASS.

v0.2.23: the firewall unit contract changed (P1-EXPOSURE-01 / P1-STOP-01):
`Type=exec` owned-guard session (`firewall-guard hold`, verified by
`firewall-guard wait` and `reload $MAINPID`), no `PartOf=nftables.service`,
backends `BindsTo=` and `WantedBy=` the firewall unit. `firewall-unit-fixture.sh`,
the systemctl/nft models and `real-systemd-validation.sh` follow it.
