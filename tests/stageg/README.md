# Stage G verification

Security hardening. The two P1 defects that the independent Stage F campaign
reproduced on real Linux, plus the narrow items approved for Stage G:

| Check | What it proves | Evidence class |
|---|---|---|
| `process-fixture.sh` G1 | a health probe whose descendant keeps stdout open cannot extend the update or its lock; leftover probe processes are killed; a hanging probe still ends in a verified rollback | real updater, helper, pipes, flock, `/proc`; candidates and GitHub are models |
| `process-fixture.sh` G2 | only the updater holds the update lock during release query, download and health gate; a parent-only SIGKILL frees it at once; the rollback helper (the one child that needs it) keeps it | as above |
| `process-fixture.sh` G3 | an offline restore sets `MANAGER_VERSION` in `global.env` to the restored version, other lines byte-identical; a symlinked `global.env` is not written through | as above |
| `real-process-oracle.py` A–C | G1/G2 with the real manager CLI (main, logging, dispatch), a candidate built from the real manager, real curl and TLS against a loopback-only server, real flock/signals/`/proc` | REAL processes in sandboxes; path constants and release URLs of the test artifacts are rewritten into the sandbox |
| `acme-webroot-fixture.sh` G4 | with a pre-existing 0700 `/var/lib/twebproxy`, Nginx LE issuance and `cert-renew` leave the webroot readable by `www-data` (kernel check via `setpriv`); only search permission is added; a symlinked parent is not changed | real permission check; Nginx/certbot/systemd are Stage D models |
| `input-validation-fixture.sh` G5 | `restart`, `cert-renew`, `dpi set`, `dpi disable` and `field-report` refuse path-like or mixed-case hostnames before any path is touched | Stage E models |

```sh
bash tests/stageg/run-stage-g-suite.sh                 # exit 0 PASS, 1 FAIL, 77 INCOMPLETE
bash tests/stageg/process-fixture.sh [<manager>] [<case regex>]
bash tests/stageg/real-process-oracle.sh [<manager>] [A|B|C ...]
bash tests/stageg/acme-webroot-fixture.sh [<manager>]
bash tests/stageg/input-validation-fixture.sh [<manager>]
bash tests/stageg/g-scope-invariants.sh <v0.2.20 source tree>
```

All of them need root (sandboxed `chown`, `flock`, `setpriv`) and touch only
their temporary directories; the oracle's TLS server listens on 127.0.0.1.

Not proven here (disposable VM gates): ENOSPC and immutable files on a real
filesystem, live systemd units and the real installed paths, SSH loss and
power loss, a real GitHub release with a signed manifest.
