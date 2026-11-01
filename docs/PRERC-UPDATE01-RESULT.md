# PRERC-UPDATE-01 — complete-distribution correction

Unpublished v0.2.26-beta on release-prep/v0.2.26-beta / draft PR1. Baseline main
4049dee7d0f9a0cc19da896d1ca9ccf4bb4abc9c; correction starts from integration
4fcb2112d2e749b6d13b5424777a5a8b636ec8b6. No main merge, release or live deployment.

The defect was independently reproduced on a genuine installed Ubuntu24.04 KVM:
baseline Bridge status0 → old script updater UPDATE_SUCCESS0 → Bridge status1.
The accepted old candidate script SHA was
c592c71b045c4eb780ccd95318a4230b2f4d51f311b4b624274f7b2d7976fe77.

The correction distributes/authenticates the manager and all mandatory runtime
components together. Immutable component directories, verified backups, staged
undo files and a durable operation-local pending record make the executable pair
and manager-version metadata recoverable. The independent helper handles offline
rollback and interrupted startup. It never downloads code from help/status or
accepts an older bundle under a new digest. Manual rollback preserves newer
nonversion global settings. [Operational instructions](DISTRIBUTION-UPDATES.md).

Actual installed tests use the canonical CLI and real systemd/nft/WireGuard in
two private KVM guests. Both authenticated HTTPS/SHA and Ed25519 fixture updates
work. Missing/mismatched members, wrong digest/signature, failed download,
SIGTERM, SIGKILL after first rename, immutable global metadata and actual ext4
ENOSPC have explicit evidence. ENOSPC is a separate filesystem/kernel fixture
with doubled health, not application acceptance. Models and retained legacy
transaction regressions remain labelled separately.

An active same-agent schema1 Bridge is compatible with local distribution
replacement; remote agent, keys, mapping, rules, units and secrets are not
rewritten. Pending cleanup and incompatible executor identities refuse. The
deliberate pending-state fixture triggers the existing watchdog's fail-closed
forwarder stop; this is distinguished from the strict no-fault positive-update
preservation measurements. Volatile watch timestamps and RA lifetimes are not
configuration changes.

Legacy v0.2.25 needs a one-time independently verified complete bootstrap. Its
old preflight cannot be retroactively changed by a new script. The new installed
health guard makes a bare-script attempt fail and roll back instead of reporting
success; it does not claim a pre-mutation refusal from untouched old code.

Known scope limits: same-host KVM guests are not two independent public VPSs;
the release feed uses an explicitly trusted loopback CA and ephemeral signing
key, not a project stable release. No new Telegram application/public ACME/
future-renewal/platform/cold-boot acceptance is claimed. A fresh foreign guest
needed the standard traversable /usr/local/libexec parent prepared after its
accepted agent created an absent ancestor under umask077. The initial failure
and compensation are retained; the production agent is unchanged. Intermittent
lab TCP SYN failures occurred independently of Manager and produced UNKNOWN RPC
status and two failed repair attempts. After replacing only the guest's virtual
lab NIC with e1000, ten connection samples, installed repair and removal passed.
The packets and failed attempts remain evidence; exact NIC/driver root cause is
not proven. Final canonical checks separately confirm service/security OK.
CLI return0 alone is not remote-health proof. No public client test is inferred.

The complete handoff REPORT, RESULTS, remaining acceptance matrix and sanitized
logs contain final execution counts, exact source identity and cleanup results.
No stable readiness follows from this scoped updater acceptance.
