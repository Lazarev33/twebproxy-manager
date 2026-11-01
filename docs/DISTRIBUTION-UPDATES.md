# Complete-distribution updates — unpublished v0.2.26-beta

PRERC-UPDATE-01 changes distribution/update transactions, not proxy networking.
A manager script alone is no longer a complete installation. No stable release
or project signing key is created by this work.

## Packaging and trust

From a verified complete checkout:

```sh
python3 tools/build-distribution.py --output twebproxy-manager-distribution.tar.gz
sha256sum twebproxy-manager-distribution.tar.gz
```

The deterministic archive includes the manager, numeric VERSION, distribution
descriptor, exact component manifest, updater, Bridge/offline dependencies,
default-site tool and bundled website. It contains no runtime credentials/state.
COMPONENTS.json pins file SHA-256, sizes and modes; the manager pins that manifest
and its updater. Nested Bridge/site manifests are also checked. DISTRIBUTION.json
binds manager identity to components. The builder refreshes pins; refresh the
source SHA256SUMS afterwards.

An independent full-archive SHA-256 is required unless a manifest verifies
against a pinned Ed25519 key. A checksum beside an artifact is not an independent
trust anchor. With signing keys configured, an invalid signature cannot fall
back to a correct operator SHA. HTTPS verification stays enabled.

Network updates require a nondraft, nonprerelease vX.Y.Z release. Its asset is
`twebproxy-manager-distribution.tar.gz`. The exact signed JSON contract is:

```json
{"format":"twebproxy.manager-distribution-release.v1","repository":"Lazarev33/twebproxy-manager","channel":"stable","version":"X.Y.Z","release_version":"X.Y.Z","tag":"vX.Y.Z","commit":"40 lowercase hex","artifact":{"name":"twebproxy-manager-distribution.tar.gz","size":12345,"sha256":"64 lowercase hex"}}
```

Sign exact manifest bytes with the offline Ed25519 key (`openssl pkeyutl -sign
-rawin`). Upload `twebproxy-manager-release.json` and its base64 signature as
`.json.sig`. Never ship the private key. The signed digest authenticates the
archive; commit records provenance. Do not publish a beta as a stable release
just to exercise the feed.

## Bootstrap from v0.2.25

The already installed v0.2.25 updater cannot acquire the new bundle. Independently
authenticate the complete handoff ZIP, extract privately and validate both outer
and source/SHA256SUMS manifests. Use its supplied runtime archive or reproduce it
with the verified builder. From the verified extraction:

```sh
sudo python3 -I source/updater/engine.py install \
  --archive twebproxy-manager-distribution.tar.gz --sha256 INDEPENDENT_ARCHIVE_SHA256
```

The bootstrap engine must itself come from the independently verified handoff.
Do not execute an unverified downloaded engine. Profiles, secrets, sites, TLS
settings and proxy units are not update targets. Two consistent, healthy old
manager copies and matching version metadata are required.

Passing only this candidate's Bash script through the old updater is unsupported.
The candidate's read-only installed health guard detects absent components; the
old transaction fails and restores exact old copies. It cannot refuse before
mutation because that preflight belongs to already installed old code. Help/status
never download/install code to hide a missing mandatory component.

## Subsequent updates

```sh
sudo twebproxy manager-update --sha256 INDEPENDENT_ARCHIVE_SHA256
sudo twebproxy manager-update --archive /root/distribution.tar.gz \
  --sha256 INDEPENDENT_ARCHIVE_SHA256
```

`--force` intentionally permits reinstall/downgrade. Without a signing key, the
independent digest remains mandatory. Transfers, expanded size/file count,
probe output and time are bounded. Traversal, links, duplicate/extra/missing
members, inconsistent versions and mismatched digests are refused.

The updater holds the manager-update lock and nonblocking Bridge controller lock;
busy returns75. Pending cleanup is refused. Active schema1 Bridge is allowed only
if its recorded executor digest matches the authenticated candidate agent.
Remote enrollment, agent, credentials, backend mapping and services do not change.
Agent migration is outside this implementation.

Components publish first into root-only immutable version directories at
`/opt/twebproxy-manager/distributions/`. Old bundles/dependency caches remain for
rollback. Verified backup, staged undo files on each target filesystem and a
durable pending record precede the first executable replacement. Health checks
both copies, JSON overview, exact component hashes and offline Bridge launcher
on supported x86_64 Python3.12/3.14. Version metadata must commit before
UPDATE_SUCCESS. Failure compensates both old copies and exact old metadata;
partial recovery never reports success.

## Rollback and interruption

```sh
sudo twebproxy manager-backup-list
sudo twebproxy manager-rollback BACKUP_ID
sudo /usr/local/libexec/twebproxy/restore-distribution-backup list
sudo /usr/local/libexec/twebproxy/restore-distribution-backup restore BACKUP_ID
sudo /usr/local/libexec/twebproxy/restore-distribution-backup recover
```

Interactive rollback remains default-NO and accepts explicit да/yes. The root-only
direct helper is intentionally noninteractive. New root-only dist-* backups in
`/var/lib/twebproxy/distribution-backups` include exact old manager, metadata
snapshot and SHA256SUMS. Old update-backups and validators retain their format;
the legacy offline helper delegates modern IDs to the standalone engine.

Manual rollback changes only manager version in current global settings; later
operator settings survive. Automatic failure undo restores its exact snapshot.
Immutable differing global metadata refuses rollback before executable changes.
Immutability is never silently removed.

SIGTERM/INT/HUP compensate; SIGKILL may leave mixed copies. Canonical new-manager
startup calls the independent helper before dispatch. Run helper recover directly
if old manager startup cannot do so. Recovery verifies backup and health.
Authenticated staging directories/unused component caches can remain after
SIGKILL; they are not silently selected in place of a different required bundle.
Backups/stores are retained rather than pruning rollback versions automatically.

Result lines: UPDATE_SUCCESS, UPDATE_CURRENT, UPDATE_REFUSED reason=...,
UPDATE_FAILED_ROLLBACK_SUCCESS/FAILED, RESTORE_SUCCESS and
RESTORE_FAILED_ROLLBACK_SUCCESS/FAILED. Failure codes remain nonzero; busy75,
SIGTERM143. English/Russian explanations go to stderr; JSON overview stays clean.

UPDATE_SUCCESS means coherent local distribution and metadata, not Telegram app,
public ACME or cold-boot acceptance. See handoff evidence and
[the executable tests](../tests/distribution).
