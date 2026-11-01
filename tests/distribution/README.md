# PRERC-UPDATE-01 regression fixtures

Run from a complete root-owned source extraction; no global pip/Paramiko install:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tests/distribution/test_engine.py
PYTHONDONTWRITEBYTECODE=1 python3 tests/distribution/test_download.py
bash tests/tui-smart-defaults/run-local.sh
bash tests/stagef/updater-fixture.sh
PYTHONDONTWRITEBYTECODE=1 python3 tests/stageg/real-process-oracle.py
```

The 26 engine tests use private filesystem roots and explicitly doubled health;
they include real process SIGKILL, file corruption and bounded child processes.
The 12 download tests use actual loopback HTTPS and OpenSSL Ed25519, with an
ephemeral one-day CA/signing key. They do not install on the host. The retained
StageF/G suites intentionally select the private **legacy** transaction; their
results are not evidence of the new complete-distribution install by themselves.

## Actual installed Ubuntu24.04 KVM

Destructive scripts refuse an unmarked/wrong-name host. Run only in disposable
guests, never the dev host's canonical runtime or a live Entry/Exit. The lab used
an official verified Ubuntu24.04 image, real PID1systemd, NET_ADMIN, nftables,
procfs protection, private Ethernet and host-key-pinned root SSH. Hosts:
update01-final-entry192.0.2.10, update01-final-exit192.0.2.11; host forwards22 only
to127.0.0.1:22230/22231. The dev host's firewall/routing is not changed.

Create /etc/twebproxy-disposable-lab from the guest's /etc/machine-id only after
independently confirming the guest is disposable. Obtain baseline4049dee source
from the supplied Git history and install its complete normal Manager/core and
upgrade-lab.invalid/default profile with manual lab TLS, unchanged stock backend
and bundled site. Core materials/builds must be official and verified. Inspect
the retained baseline install log. Check baseline local/foreign-node status0.
Do not call this public ACME or application acceptance.

The supplied historical RED observer is in handoff evidence; run it with
--bundle-only and the exact frozen pre-correction c592c71 script before applying
the fix. It intentionally returns1 after observing UPDATE_SUCCESS0/Bridge1.
Restore the verified old manager and metadata with its ordinary rollback.

Use a cold offline snapshot of this genuine baseline for the exact final repeat:

```sh
python3 legacy_installed.py /root/final-manager.sh /root/final-legacy-private
python3 -I /root/newengine.py install --archive /root/distribution.tar.gz \
  --sha256 INDEPENDENT_ARCHIVE_SHA256
twebproxy foreign-node status
twebproxy --json overview
```

The engine and artifact must be independently authenticated before execution.
The replay is explicitly a snapshot replay, not another fresh installation.

For active compatibility, provision the existing Bridge through the installed
normal CLI and private VM addresses. Generate the initial disposable SSH key
inside Entry; install only its public key on Exit, verify Exit's console host
fingerprint, and approve the scoped plan. Use standard /usr/local/libexec0755
on the clean foreign guest (the initial absent-parent/umask077 failure is recorded).
Never transfer private bootstrap/managed keys into source or evidence.

```sh
python3 /root/observe_installed.py > /root/before.json
python3 /root/installed_matrix.py /root/distribution.tar.gz
python3 /root/recovery_installed.py /root/distribution.tar.gz
python3 /root/enospc_kernel.py /root/distribution.tar.gz
python3 /root/observe_installed.py > /root/after.json
```

Stage these source scripts into /root and the verified engine as /root/newengine.py.
The installed matrix has real canonical CLI signed/SHA HTTPS success, bad
downloads/signatures/digests/missing members, SIGTERM, pending-node/incompatible
executor refusal and immutable global.env rollback. The explicit pending-node
fixture may trigger the **existing** watchdog to stop the forwarder. Compare that
fault campaign with compare_observations.py --pending-fixture; compare a separate
normal update without that flag to require exact unit/PID/start/restart state.
Raw observations are retained; exclude only watch heartbeat/RA expiry counters.
The initial virtio lab link showed intermittent SYN failures independently of
Manager. The retained lab can be restarted with --lab-nic e1000 after stopping
both guests; private IPs/MACs, WireGuard topology and security policy stay the
same. This fixture substitution allowed repair/removal; it is not a product fix
or proof of a specific virtio driver defect. Preserve both failed attempts.

Recovery exercises manual rollback25 with a late-added setting, immutable refusal,
real SIGKILL at the first replacement and actual new-manager startup recovery.
ENOSPC fills only a new256MiB ext4 loop filesystem in the guest, with an explicit
health double; it never fills the guest/dev root filesystem. It unmounts/removes
that image afterwards. See separate results; do not label this application health.

CLI return0 proves command availability, not all remote checks. Assert the actual
JSON peer route/TCP, remote service and security boundary values. Historical
under-load RPC timeouts remain UNKNOWN; final canonical observations and direct
restricted forced-command verification are recorded separately. MTProto/client
UNKNOWN must not be converted into a Telegram application PASS.

Raw logs, snapshots, VM disks, TLS/signing/SSH keys and configuration are private
root-only material. Export only sanitized .raw/.json observations; remove complete
links/tokens/credentials and never include private keys. The final handoff also
records cleanup, source protection comparison and independent archive validation.

start_retained_lab.py only restarts preexisting private disks on the exact named
development host after operator interruption; it is not a provisioning framework
and cannot recreate missing disks. Stop all named QEMU units after tests. Preserve
original work/archives; remove only owned new transient images/keys after saving
sanitized results. No production operation, Git merge or release is part of tests.
