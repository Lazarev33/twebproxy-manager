# Real lab validation (disposable VM only)

Kernel nft, systemd lifecycle, namespace/mount and genuine ENOSPC tests change
real host state. They run **only** on a disposable Linux VM that was prepared
for them. Every other host, including a production TWebProxy server where the
opt-in variable was set by mistake, reports `NOT_EXECUTED` (exit 77) before any
privileged command. A suite with a `NOT_EXECUTED` case is `INCOMPLETE`, never
`PASS`.

## Gate (`tests/lib/lab-gate.sh`)

A real test runs only when **all** of these hold:

1. `TWEBPROXY_LAB_MODE=disposable-vm` is exported.
2. `/etc/twebproxy-disposable-lab` is a regular root-owned file containing this
   host's `/etc/machine-id`.
3. No TWebProxy fingerprint exists: `/etc/twebproxy`, `/usr/local/libexec/twebproxy`,
   `/usr/local/sbin/twebproxy`, `/opt/twebproxy-manager`, `/srv/twebproxy`,
   `/etc/systemd/system/twebproxy*`. Use a fresh VM snapshot for every run.
4. The test runs as root.

Gated scripts: `tests/stageb/real-nft-validation.sh`,
`tests/stageb/real-systemd-validation.sh`, `tests/stagea/sa1-real-nft-validation.sh`,
the tmpfs section of `tests/stagea/sa3-state-publication.sh`,
`tests/fieldgate/tg1-real-nft-six-mode-gate.sh`,
`tests/fieldgate/tg3-installed-manager-lifecycle.sh`.
`tests/stageb/lab-gate-fixture.sh` fails if a new script uses `unshare`, `mount`,
`umount`, a real `nft` lookup or `/run/systemd/system` without the gate.

## Preparing the VM

Debian 12 (nft 1.0.6, systemd 252) and Ubuntu 22.04 (1.0.2/249) or 24.04
(1.0.9/255); optionally Debian 13. Packages: `nftables jq util-linux coreutils`.
Snapshot the VM first.

```sh
cat /etc/machine-id > /etc/twebproxy-disposable-lab   # as root, on the VM only
export TWEBPROXY_LAB_MODE=disposable-vm
```

## Runs

```sh
timeout 150 bash tests/stageb/real-nft-validation.sh
timeout 270 bash tests/stageb/real-systemd-validation.sh
timeout 150 bash tests/stagea/sa1-real-nft-validation.sh
timeout 600 bash tests/stagea/sa3-state-publication.sh   # re-execs in a private mount namespace
timeout 300 bash tests/fieldgate/tg1-real-nft-six-mode-gate.sh
timeout 600 bash tests/fieldgate/tg3-installed-manager-lifecycle.sh
bash tests/stageb/run-stage-b-suite.sh; bash tests/stagea/run-stage-a-suite.sh
```

Record `uname -r`, `nft --version`, `systemctl --version`, each exact command,
exit status and output. No secrets or real hostnames.

## Additional B.1 checks (manual, on the VM)

- **F1 under real systemd:** a `User=nobody` oneshot unit whose `ExecStart` is a
  script in a root-owned directory: active with 0755, `203/EXEC` or exit 126 with
  0700. Then, after a full `core-install` + `add` with v0.2.13:
  `stat -c %a /usr/local/libexec/twebproxy` is `755` and every
  `twebproxy-mtproxy@` unit is active; `repair` keeps them active.
- **R1 reload propagation:** with `nftables.service` enabled and the packaged
  `/etc/nftables.conf` (starts with `flush ruleset`), start the backend firewall
  unit, run `systemctl reload nftables`, and confirm `inet twebproxy_backend`
  is present again afterwards (`journalctl -u twebproxy-firewall` shows the
  propagated reload). Repeat with the unit started but `nftables.service`
  inactive (the reload is refused; nothing changes).
- **R2 dependency propagation:** with relay/backend test units that have
  `Requires=` + `After=` on the firewall unit, record whether
  `systemctl restart nftables` and `systemctl stop nftables` restart/stop them
  (`systemctl show -p ExecMainStartTimestamp`). Expected from systemd source:
  restart cascades as try-restart; stop stops them (fail-closed).
- **R3 ambiguous apply:** not reproducible on demand; the model fixture covers
  the decision logic. Optionally slow the netlink path and use a short timeout.
