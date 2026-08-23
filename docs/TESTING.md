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
