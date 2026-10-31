# Manager self-update: trust policy and release publishing

This describes `twebproxy check-update` / `twebproxy manager-update` from
v0.2.20 (Stage F) on. The relay update (`twebproxy update`) is unrelated.

## Policy

- **Only a stable GitHub Release is an update candidate.** The manager asks
  `GET https://api.github.com/repos/Lazarev33/twebproxy-manager/releases/latest`
  (the newest published release that is neither a draft nor a prerelease) and
  validates the answer: a tag of the form `vX.Y.Z`, `draft == false`,
  `prerelease == false`, and `html_url` belonging to this repository. Redirects
  are not followed. Development branches (`main`, `stage-*`), their `VERSION`
  files and their `SHA256SUMS` are never update sources, also not for the
  automatic hint or `check-update`.
- **Authentication comes from one of two trust anchors:**
  1. a **signed release manifest** that verifies against an Ed25519 public key
     pinned in the manager source (`MANAGER_UPDATE_TRUSTED_KEYS`). As soon as at
     least one key is pinned, a valid signature is mandatory;
  2. while no key is pinned, an **operator-pinned SHA-256**:
     `manager-update --sha256 <64 hex>`. The digest must come from an
     independent channel (for example a reviewed source tree, a signed
     announcement, or a check on a trusted machine). The output labels this
     `trust=operator-sha256`; it is the operator's assertion.
- A `SHA256SUMS` file downloaded from the same place as the script is integrity
  information only. It is never accepted as authentication.
- **This build pins no key.** The project has no release-signing key yet, and
  Stage F deliberately does not invent one. `manager-update` without `--sha256`
  therefore refuses before downloading anything:
  `UPDATE_REFUSED reason=no-trust-anchor`. Automatic updates stay disabled until
  the publishing requirements below are met.

## What `manager-update` does

1. Options: `--force` (also install a version that is not newer), `--sha256 HEX`.
   Anything else: `UPDATE_REFUSED reason=usage`.
2. Update lock `/run/lock/twebproxy-manager-update.lock` (flock). Another update,
   offline rollback or manager-copy synchronisation is waited for at most
   `TWEBPROXY_UPDATE_LOCK_WAIT` seconds (default 30), then the update is refused.
   The kernel releases the lock with its holder; the lock file is never
   deleted. The lock is released on every return (also inside the TUI). Only
   the updater holds it: no child inherits the lock descriptor (curl, health
   probes, helper checks) except the offline helper during a rollback, which
   restores under it. If the updater dies, even by SIGKILL during a download,
   the lock is free at once (Stage G).
3. Private staging `/var/lib/twebproxy/update-staging` (root, 0700). Staging and
   install temp files left by a killed update are removed here, under the lock.
4. The offline restore helper is verified and refreshed to the running
   manager's rendering (an unsafe or invalid helper is never replaced: the
   update is refused).
5. Preflight: both installed copies identical, root-owned 0755, healthy. A mixed
   state (for example after a killed update) is refused with the recovery
   command.
6. Latest stable release, version comparison.
7. Trust:
   - signed: `twebproxy-manager-release.json` and `.sig` from
     `https://github.com/Lazarev33/twebproxy-manager/releases/download/<tag>/`
     (HTTP 200; at most 3 redirects, only to `objects.githubusercontent.com` or
     `release-assets.githubusercontent.com`; 64 KiB / 4 KiB), Ed25519 signature
     with a pinned key, strict manifest validation (below). The artifact is then
     fetched by the signed **commit**:
     `https://raw.githubusercontent.com/Lazarev33/twebproxy-manager/<commit>/twebproxy-manager.sh`;
   - operator-pinned: the artifact is fetched by the release tag.
8. Artifact: HTTPS, no redirect, at most 8 MiB; SHA-256 (and, signed, size) equal
   to the trusted value; `bash -n`; exactly one `MANAGER_VERSION="X.Y.Z"` equal to
   the release; exactly one `MANAGER_RELEASE_VERSION` equal to `X.Y.Z` or
   `X.Y.Z-<label>` (signed: equal to the manifest's `release_version`). The
   candidate has not run at this point.
9. Verified pre-update backup (format `twebproxy.update-backup.v1`, unchanged).
10. Both copies are installed (each by an atomic rename) and the bounded health
    gate runs (`--help`, `--json overview`; 15/20 s, SIGKILL 5 s later, no stdin,
    no lock descriptor). Probe output goes to a size-capped file (4 MiB), not a
    pipe, and the probe's process group is killed after each probe, so a
    descendant that keeps stdout open cannot extend the gate (Stage G). From
    the first copy until a verified outcome, SIGINT,
    SIGTERM, SIGHUP and SIGPIPE are ignored, so an interruption cannot leave the
    copies mixed. SIGKILL or power loss can; see Recovery.
11. Result lines:

| Line | Meaning |
| --- | --- |
| `UPDATE_SUCCESS backup_id=…` | both copies verified by SHA-256 and health gate |
| `UPDATE_FAILED_UNCHANGED backup_id=…` | nothing was installed (copies verified unchanged) |
| `UPDATE_FAILED_ROLLBACK_SUCCESS backup_id=…` | previous manager restored, verified by the manager itself (not only the helper's status) |
| `UPDATE_FAILED_ROLLBACK_FAILED backup_id=…` (stderr) | not verified; the offline recovery command is printed; older backups are not pruned |
| `UPDATE_REFUSED reason=…` (stderr) | refused before any change: `usage`, `release`, `no-trust-anchor`, `download`, `signature`, `manifest`, `digest`, `identity` |

After success, `MANAGER_VERSION` in `global.env` is updated atomically (a failed
write leaves the old file intact and is reported; `repair` rewrites it), the
update cache is removed and verified backups are pruned to 4.

## Release-publishing requirements (owner)

Automatic updates need all of the following. None of it exists yet.

1. **Create an Ed25519 release-signing key offline** and keep the private key
   off the repository and off servers:
   `openssl genpkey -algorithm ed25519 -out twebproxy-release-signing.pem`.
   Back it up securely.
2. **Pin the public key** in the manager source through a reviewed commit:
   `openssl pkey -in twebproxy-release-signing.pem -pubout -outform DER | base64 -w0`
   becomes one entry of `MANAGER_UPDATE_TRUSTED_KEYS=( "…" )`. Installations
   trust it only once they run a build that contains it, so that first build is
   installed out of band (manually, or with `--sha256`).
3. **For every stable release `X.Y.Z`:**
   - set `VERSION` and `MANAGER_VERSION` to `X.Y.Z` and `MANAGER_RELEASE_VERSION`
     to `X.Y.Z` or `X.Y.Z-<label>`; commit; note the 40-hex commit id `C`;
   - tag `vX.Y.Z` at `C` and publish a GitHub Release from it, neither draft nor
     prerelease; enable GitHub immutable releases if available, so tag and
     assets cannot change afterwards;
   - write `twebproxy-manager-release.json` with exactly these keys:
     ```json
     {"format":"twebproxy.manager-release.v1","repository":"Lazarev33/twebproxy-manager","channel":"stable","version":"X.Y.Z","release_version":"X.Y.Z-beta","tag":"vX.Y.Z","commit":"C","artifact":{"name":"twebproxy-manager.sh","size":12345,"sha256":"…"}}
     ```
     `size` and `sha256` are those of `twebproxy-manager.sh` at commit `C`;
   - sign the exact file bytes:
     `openssl pkeyutl -sign -inkey twebproxy-release-signing.pem -rawin -in twebproxy-manager-release.json -out sig.bin`
     and `base64 -w0 sig.bin > twebproxy-manager-release.json.sig`;
   - verify before uploading (`openssl pkeyutl -verify -pubin -inkey pub.pem -rawin -in twebproxy-manager-release.json -sigfile sig.bin`;
     compare `sha256sum` / `stat -c %s` of the script fetched from
     `raw.githubusercontent.com/…/C/twebproxy-manager.sh`);
   - upload `twebproxy-manager-release.json` and
     `twebproxy-manager-release.json.sig` as release assets with exactly these
     names.
4. **Development checkpoints stay separate:** stage branches are never published
   as stable releases (a draft or prerelease is ignored by the updater) and
   never get a signed stable manifest.
5. **Rotation:** pin the new key in a release signed with the old key, and drop
   the old key in a later release. A compromised key stays trusted by an
   installation until it runs a release that no longer pins it.

## Operator use

```sh
sudo twebproxy check-update                  # latest stable release and trust status
sudo twebproxy manager-update                # signed release (once a key is pinned)
sudo twebproxy manager-update --sha256 HEX   # while no key is pinned: independent digest
sudo twebproxy manager-backup-list
sudo twebproxy manager-rollback [latest|<id>]
sudo /usr/local/libexec/twebproxy/restore-update-backup list|restore-latest|restore <id>   # offline
```

## Recovery

- `UPDATE_FAILED_ROLLBACK_FAILED`, or a killed update that left the two copies
  different: run the offline helper,
  `/usr/local/libexec/twebproxy/restore-update-backup restore-latest` (or
  `restore <id>`). It needs no network and does not use the installed manager.
  It also sets `MANAGER_VERSION` in `global.env` to the restored version (only
  that line; a symlinked or unsafe `global.env` is left alone and reported).
  Outcomes (v0.2.23): `RESTORE_SUCCESS` (status 0) only when the executables
  and the metadata agree; `RESTORE_PARTIAL … metadata=stale` (status 3) when the
  executables were restored but `global.env` could not be written (for example
  immutable or read-only) - make it writable and run `twebproxy repair`.
  `twebproxy manager-rollback` prints `ROLLBACK_NOT_PERFORMED reason=declined`
  (status 1) or `reason=eof` (status 130) when nothing was restored.
  The next `manager-update` then works again; it removes the stale staging and
  temp files itself.
- A busy lock after a crash cannot happen (flock); a lock file with a wrong
  owner or mode is refused and must be fixed by the administrator.

## Limitations

- No protection against freeze or replay of an older signed "latest" release
  (no timestamp service); `--force` can deliberately reinstall an older signed
  release.
- The trust anchor is the installed manager build; the first build that pins a
  key must be installed out of band.
- A running TUI keeps executing the old in-memory code after a successful
  update; restart `twebproxy`.
- A probe descendant that leaves the probe's process group (for example with
  `setsid`) is not killed; it can no longer hold the update or the lock.
- Tested with models (`tests/stagef`, `tests/stageg`) and with real processes,
  locks and curl/TLS in sandboxes (`tests/stageg/real-process-oracle.py`); the
  real-VM gates are listed in the Stage G report.
