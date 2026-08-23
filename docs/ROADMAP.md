# Roadmap

## 0.2.6 — current beta

Goal: preserve the first known-good E2E baseline and remove issues observed in the successful report.

Done:

- Caddy + `https` + stock MTProxy baseline;
- systemd credential permission model;
- MTProxy `AF_NETLINK` correction;
- isolation audit;
- compact current/history reports;
- transactional managed Caddy changes;
- reboot/autostart validated on the field VPS;
- GitHub manager update channel with checksum validation;
- strict TLS and all-listener audit improvements.

## Next field tests

Do not add a second backend implementation before these tests are separated cleanly:

1. `https-lanes`.
2. `websocket`.
3. `websocket-lanes`.
4. Nginx + Let's Encrypt.
5. large media/file transfer.
6. reconnect after client sleep/network switch.
7. intentional backend crash and relay crash recovery.
8. external scan proving backend/stats ports are unreachable.

## 0.2.x cleanup after field matrix

Candidates:

- make managed Nginx configuration changes transactional with rollback, matching the Caddy path;
- collect concise per-test metrics without enabling raw request logging;
- add an explicit noninteractive preflight command suitable for CI/VPS smoke testing;
- document restore/backup semantics before introducing automated migration.

## 0.3 experiment branch

Introduce backend abstraction only after stock MTProxy remains a stable baseline:

```text
backend=stock-mtproxy
backend=telemt-direct
backend=telemt-middle-end
```

Telemt should be evaluated by changing only the backend while keeping hostname, carrier and client test constant.

## RC / external audit

Before 1.0:

1. clean-install E2E on at least two fresh VPS images;
2. upgrade from previous manager release without recreating profiles;
3. static architecture/security review;
4. hostile review of partial-install, rollback, port collision and existing-frontend cases;
5. rerun every accepted finding on a real VPS;
6. freeze a reproducible release artifact with checksums.
