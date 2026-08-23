# Security model

## Secrets

Normal transcripts and safe snapshots redact WEB/MTProxy secrets. FULL reports may retain them for controlled test-server debugging.

Even FULL mode intentionally does not collect:

- root/sudo passwords;
- `/etc/shadow`;
- SSH private keys;
- TLS private key contents.

## systemd credentials

Relay receives `config.json` and `profiles.json` via `LoadCredential`.

MTProxy receives Telegram `proxy-secret` and `proxy-multi.conf` via `LoadCredential`.

This keeps `/etc/twebproxy` root-only rather than widening directory permissions to service accounts.

## Address families

Relay allows only `AF_INET AF_INET6` and is restricted to localhost connections by systemd IP policy.

MTProxy allows `AF_INET AF_INET6 AF_NETLINK`. `AF_NETLINK` is required by the real Ubuntu/glibc runtime path used by `getifaddrs()`; omitting it produced an observed runtime warning while the backend otherwise continued working.

## Backend exposure

The stock MTProxy baseline is treated as potentially wildcard-bound. nftables is therefore a required boundary, not optional decoration.

`twebproxy audit` checks that every registered backend/stats port is present in the manager-owned nftables table. This is a structural local audit; it does not replace an external scan from another host.

## Reverse proxy

Managed Caddy/Nginx access logs are disabled for the WEB hostname. Do not add raw URI, authorization or bearer logging without understanding what the WEB transport carries.

For Manual mode, forward the complete hostname to `tproxy-server`; splitting special locations around the relay changes the public surface and is unsupported by this manager.
## Manager self-update

`manager-update` downloads only over HTTPS from the configured GitHub repository, requires a SHA-256 entry from `SHA256SUMS`, validates Bash syntax and checks that the embedded manager version matches the remote release metadata before installation. The previous installed manager is retained as `/opt/twebproxy-manager/twebproxy-manager.previous.sh`.

The checksum protects against transfer/caching corruption; it does not protect against compromise of the GitHub repository itself.

