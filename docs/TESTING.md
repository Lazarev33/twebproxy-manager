# Test plan

## Rule

Change one variable at a time. Keep a known-good baseline so a failure can be assigned to frontend, carrier or backend instead of all three.

## Known-good baseline

```text
Ubuntu 24.04 x86_64
Caddy
carrier=https
official MTProxy
Telegram Desktop native WEB proxy
```

## Functional tests

1. Connect proxy in Telegram.
2. Send/receive text.
3. Photo upload/download.
4. Voice message.
5. Video.
6. 100–500 MB file.
7. Close/reopen Telegram.
8. Network reconnect.
9. Restart relay.
10. Restart MTProxy backend.
11. Reboot VPS and verify autostart without manual commands.

## Carrier matrix

Run against the same hostname/network/backend where possible:

```text
https
https-lanes
websocket
websocket-lanes
```

## Frontend matrix

```text
Caddy managed
Nginx + Let's Encrypt
Nginx custom certificate
Manual existing frontend
```

## Failure handling

Do not manually repair a failing beta install before collecting evidence.

```bash
sudo twebproxy audit <hostname> || true
sudo twebproxy report
```

Share the generated bundle from:

```text
/opt/twebproxy-manager/logs/bundles/
```

## External isolation check

From a different host, verify that only intended public services are reachable. Backend/stats ports chosen by the manager must not be externally reachable even though stock MTProxy may show wildcard listeners locally.

## Bridge Gate 2/3 coverage and outstanding checks

Gate 2: conditional acceptance, 17 PASS / 0 FAIL / 8 NOT_EXECUTED. Gate 3
has an authorized real RU Entry/Foreign Exit deployment, public TLS/site
and operator-reported Telegram for iOS 13.1.2 messaging/media/reconnect.
Server counters corroborate traffic but do not establish independent file
integrity. Telegram Desktop runtime, other clients, dual-server cold boot
and broader OS matrix remain unverified. Do not label synthetic MTProto
responses or operator reports as independent client PASS. See
[CLIENT-VALIDATION.md](bridge-gate3/CLIENT-VALIDATION.md).

## v0.2.26 bounded integration

See [pre-RC fixtures](../tests/prerc-v026/README.md) and the all-in-one handoff's
REPORT/RESULTS/RC matrix. Actual KVM and trusted loopback-TLS updater measurements
are separate from models and genuine Telegram application tests. An observed
script-only auxiliary-bundle upgrade defect remains PRERC-UPDATE-01; do not count
state preservation or recovery as closure. Public/client/two-VPS/cold-boot gates
are not inferred from local success. The historical overview model accepts
TWEBPROXY_GATE2_BASELINE pointing to verified old source when rewritten Git
history lacks commit3375c4a; absence is NOT_EXECUTED77, not a product failure.
