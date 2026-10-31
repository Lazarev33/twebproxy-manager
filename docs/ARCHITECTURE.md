# Architecture — v0.2.25-beta

Manager is the control plane, not part of the data path. Two runtime modes coexist.

## Single-VPS mode

```text
Telegram WEB client → HTTPS/WSS :443 → Caddy/Nginx → tproxy-server → local stock MTProxy → Telegram DC
Browser             → HTTPS :443     → Caddy/Nginx → static site / loopback application
```

The local relay/backend uses loopback and protected service ports. No WireGuard or remote SSH is needed.

## RU Entry / Foreign Exit Bridge

```text
Telegram WEB client -- HTTPS/WSS:443 --+
Browser             -- HTTPS:443 -----+--- [RU Entry VPS]
                                            |
                                        Caddy/Nginx
                                         /       \
                                  static site   WEB route
                                                   |
                                              tproxy-server
                                                   |
                                              loopback TCP
                                                   |
                                            systemd-socket-proxyd
                                                   |
                                              WireGuard RU
                                                   |
                                      encrypted private tunnel
                                                   |
                                              WireGuard Exit
                                                   |
                                          stock MTProxy (private)
                                                   |
                                               Telegram DC
                                             [Foreign Exit VPS]
```

The **only** client connection link points to RU Entry. Exit is not another public proxy. The Entry forwarder listens on loopback and sends TCP to the foreign MTProxy over WireGuard. MTProxy stats are not forwarded. The bridged instance's previous local backend is stopped after cutover; unrelated instances can remain local.

Current MVP: one foreign node attached to one existing hostname with exactly one profile. There is no multi-exit load balancing or fleet-wide upgrades. The foreign root operator can recover the canonical profile secret; use only a trusted Exit.

## Automated provisioning and lifecycle

The Foreign Nodes workflow verifies the remote ED25519 host fingerprint, reviews an installation plan, configures both WireGuard peers, a socket-activated loopback forwarder and the protected stock MTProxy, and switches the instance safely. Initial SSH passwords are not persisted. Dedicated keys use forced restricted commands and limited sudo; there is no public management API. Each host retains its own WireGuard private key.

`foreign-node status` and `diagnose` inspect private route, TCP, services and security. `repair` reconciles owned state; `remove` restores the local backend only after it is ready. Failed cleanup remains recorded as PARTIAL and cannot be bypassed by manually deleting state.

The data-path watcher stops forwarding after repeated failed TCP checks and restores it after verified private path recovery. Active streams can disconnect; automatic recovery does not imply seamless TCP migration.

## Security and state

- Public ingress: TLS TCP 443, and TCP 80 when ACME/redirect requires it.
- Relay/admin and Entry forwarder: loopback. MTProxy backend must not be publicly reachable.
- Local/foreign backend isolation: manager-owned nftables plus systemd IP restrictions; Bridge adds exact peer/interface rules and blackhole route fallback.
- Stock MTProxy's argv secret requires procfs hardening; failure of mandatory protection blocks backend startup.
- Local canonical configuration: root-owned `/etc/twebproxy`; Bridge state: `/etc/twebproxy/bridge` on Entry and `/var/lib/twebproxy-bridge/<uuid>` on both hosts.
- Default site: verified `sites/podmoskovye/` bundle; one deployed copy per hostname, existing edits preserved on repair.
- `STOCK` is default. Experimental Anti-DPI modes can affect shared IPv4 TCP/443; no guaranteed DPI invisibility.

## Validation and related documents

Bridge Gate 2: 17 PASS / 0 FAIL / 8 NOT_EXECUTED (conditional acceptance). Gate 3 operator reported successful Telegram for iOS 13.1.2 via RU Entry with server traffic corroboration; no independent file hash, full Desktop runtime test or dual-server cold boot test was recorded.

[Gate 2](BRIDGE-GATE2.md) · [Gate 3 operations](bridge-gate3/OPERATIONS.md) · [Client evidence](bridge-gate3/CLIENT-VALIDATION.md) · [Security](SECURITY.md) · [Updates](UPDATES.md)
