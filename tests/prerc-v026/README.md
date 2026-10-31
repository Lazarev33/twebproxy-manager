# Bounded pre-RC fixtures

Local: `bash tests/tui-smart-defaults/run-local.sh`. See the handoff REPRODUCE.md
for the exact commands and separate model/process/kernel/application results.

Privileged scripts run ONLY in explicitly authorized disposable KVM guests,
never live proxy servers or the development host's own networking. The tested
official Ubuntu24.04.5 x86_64 cloud image SHA256 is
`04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94`;
its matching checksum signature was verified with Ubuntu's cloud-image keyring.
Use a fresh overlay, bounded memory/CPU, root-only temporary SSH key/seed and
loopback-only SSH forwards. Pin guest keys against the hypervisor console first.
Different image hashes are different environments; no VPS reboot is needed.

Guest1: `prerc-v026-lab`,1024MiB/one vCPU. Guest2: `prerc-v026-clean`,768MiB/one vCPU.
On guest1 BEFORE Manager installation:

```sh
test "$(hostname)" = prerc-v026-lab || exit 1
cat /etc/machine-id > /etc/twebproxy-disposable-lab
chmod 600 /etc/twebproxy-disposable-lab
bash /root/candidate26/tests/prerc-v026/clean-kernel.sh /root/candidate26
```

Existing real nft/systemd/ownership/six-mode gates execute in their isolated
scopes. After installed tests, normal uninstall and removal of only owned test
residue, `tests/stagea/sa1-real-nft-validation.sh` commits DPI rules and verifies
kernel JSON in a private network namespace. Do not bypass its clean-host gate.

Guest2 starts pristine with the full candidate at `/root/candidate26`:

```sh
bash /root/candidate26/tests/prerc-v026/clean-install.sh /root/candidate26
```

This tests Quick's DNS refusal then a genuine Advanced install with normal
official downloads/builds, bundled site, manual external TLS and `.invalid`
hostname. Manual TLS is not public ACME success. Installed profile creation and
audit follow. Capture raw output privately: creation prints private links.

Guest1 installs the exact main4049dee distribution at `/root/baseline25`:

```sh
export GOMAXPROCS=1 GOFLAGS=-p=1 TWEBPROXY_UI_LANGUAGE=ru NO_COLOR=1
bash /root/baseline25/twebproxy-manager.sh core-install
printf 'upgrade-lab.invalid\n1\n1\n4\ny\n' | twebproxy add
python3 /root/candidate26/tests/prerc-v026/upgrade-real.py
```

The unchanged updater/backup/rollback uses real installed files, curl and a
trusted loopback test CA; only API/raw origins are redirected, with an exact
operator-pinned SHA. This publishes no stable Release. Failed health is an
explicit test mutant. The first observer's exact executed copy is retained;
the current harness returns nonzero for the reproduced Bridge bundle gap.
`--bundle-only` isolates baseline status0 → script upgrade → status1. A repeat
may hold/restore an owned test bundle to recreate the original fresh-v025 layout;
never remove an operator installation. The defect intentionally returns1.

After complete-source repair:

```sh
bash /root/candidate26/tests/prerc-v026/installed-invariants.sh upgrade-lab.invalid
```

Actual procfs read refusal, audit, denied backend startup with missing required
unit policy while stopped, policy restoration, SIGKILL recovery and four carrier
configurations/readiness are measured. Readiness is not application success.

Existing `tests/prerc/fw-transition-probe.sh` is installed-host gated. Its veth
peer is non-loopback inside the VM; an owned TCP443 listener is a positive
control, not TLS or an Internet client. Target-start is not reboot acceptance.

Export sanitized logs/state hashes only, no keys/raw links. Preserve SSH/cloud
services. Uninstall test instances, verify postconditions, remove owned residue,
power off guests and remove private overlays/keys. Missing public DNS/TLS,
clients, two-VPS, platform and cold-boot prerequisites remain NOT_EXECUTED.
