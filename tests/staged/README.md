# Stage D verification

Frontend and TLS lifecycle: managed Caddy blocks (strict ownership markers,
candidate validation next to the live Caddyfile, atomic swap, reload with
restore, never a restart), managed Nginx vhosts (atomic write, nginx -t,
reload/start with exact restore of file and link), Let's Encrypt issuance,
renewal and certificate preservation, custom certificate/key checks, and the
truthful handling of create, repair, delete and cert-renew. Model tests only:
safe on any Linux test workstation with Bash, jq, coreutils, util-linux and
openssl; no system state changes.

```sh
bash tests/staged/run-stage-d-suite.sh             # exit 0 PASS, 1 FAIL, 77 INCOMPLETE
bash tests/staged/frontend-tls-fixture.sh [<manager>]
bash tests/staged/d-scope-invariants.sh <v0.2.17 source tree>
bash tests/staged/rebind-baseline.sh <pre-D manager> <out>   # RED baseline copy
```

`frontend-harness.sh` extends the C2 relay harness. The frontend locations are
rebound into the sandbox (`CADDY_DIR`, `CADDYFILE`, `NGINX_DIR`, `LE_DIR`,
`ACME_WEBROOT`); a manager whose frontend functions still name the real paths
is refused. `caddy`, `nginx`, `certbot` and the caddy/nginx units are models
that keep what is *running* separately from what is *on disk*; certificates
are real self-signed openssl pairs. A pre-D manager has literal paths, so its
RED run uses `rebind-baseline.sh`, which replaces only those literals (and
verifies that nothing else changed).

None of this proves real Caddy, Nginx, certbot/ACME or systemd behaviour; those
remain disposable-VM gates before an RC.
