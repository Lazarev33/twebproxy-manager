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

v0.2.23: the boundary is held by `inet twebproxy_guard`, created with `flags owner` by the long-running `twebproxy-firewall` service (`firewall-guard hold`). The kernel skips owned tables in a foreign `flush ruleset` and refuses foreign deletion or modification, so starting, reloading, restarting or stopping `nftables.service` cannot open the backend ports. The table exists exactly as long as the service; backends are `BindsTo=` it and stop first. `twebproxy_backend` remains as a second, ordinary table (re-applied after nftables transitions by a `nftables.service.d` drop-in) and is checked by the audit together with the guard.

v0.2.24 (P1-A): the owned table disappears the instant its owning `nft -i` process dies, and an independent acceptance run showed that an unrelated `flush ruleset` in that window exposed the still-running backends before systemd stopped them. Backend isolation therefore no longer depends on any long-running process. **Invariant:** every socket of an MTProxy backend belongs to the cgroup of its `twebproxy-mtproxy@` unit, and PID 1 attaches that cgroup's BPF ingress/egress filter (`IPAddressDeny=any`, `IPAddressAllow=` loopback plus Telegram's published DC networks) before any process of the unit runs; it stays attached until the cgroup is gone, i.e. until the backend is gone. A packet whose remote address is outside the allowlist never reaches a backend socket, regardless of nftables state, the guard session or the order of service transitions. `ExecStartPre=+backend-start-check` refuses the start when PID 1 does not enforce the filter for the unit (no cgroup-BPF support, or the deny list overridden), so the invariant cannot silently degrade. The nftables guard and `twebproxy_backend` stay as a second layer. Remaining exposure by design: hosts inside Telegram's DC networks are allowed to reach the backend ports (needed for the DC connections; reaching them still requires the client secret). The audit checks `profile.backend.socket_filter` (unit properties plus an active connection attempt through the host's own non-loopback IPv4, which the nftables rule does not see) and `backend.egress.dc_coverage` (every `proxy_for` address of the routing config is inside the allowlist).

`twebproxy audit` checks that every registered backend/stats port is present in the manager-owned nftables table. This is a structural local audit; it does not replace an external scan from another host.

## Reverse proxy

Managed Caddy/Nginx access logs are disabled for the WEB hostname. Do not add raw URI, authorization or bearer logging without understanding what the WEB transport carries.

For Manual mode, forward the complete hostname to `tproxy-server`; splitting special locations around the relay changes the public surface and is unsupported by this manager.
## Manager self-update

`manager-update` considers only the latest stable GitHub Release (never a development branch) and installs it only when its signed release manifest verifies against an Ed25519 key pinned in the manager, or, while no key is pinned, when the operator passes the expected SHA-256 from an independent channel (`--sha256`). A `SHA256SUMS` file from the same source is not authentication. No release-signing key exists yet, so this build pins none and automatic updates fail closed. Downloads are HTTPS-only, size-bounded, and redirects are refused except from GitHub release downloads to GitHub asset hosts; the artifact's SHA-256, Bash syntax and embedded version identity are checked before a verified backup is taken and before the candidate ever runs.

Installation replaces both manager copies atomically under the update lock, with signals deferred until a verified outcome: success, unchanged, or rollback to the verified backup (also restorable offline with `/usr/local/libexec/twebproxy/restore-update-backup`). Policy, result lines and the release-publishing requirements: [UPDATES.md](UPDATES.md).

Stage G: health probes are bounded even when a candidate leaves a process holding stdout (file capture, process-group cleanup), and the update lock is held only by the updater (and by the offline helper during a rollback), so a killed updater never leaves it with a surviving `curl`. Mutating commands that take a hostname (`restart`, `cert-renew`, `dpi set|disable`, `field-report`) validate it before it reaches any path.

Stock MTProxy takes the client secret as `-S <secret>`, so `/proc/<pid>/cmdline` exposes it to every local account on a default procfs. A service's own `ProtectProc=` does not hide it from other users. v0.2.23 applies a host policy: `/proc` with `hidepid=invisible,gid=<twebproxy-procview>` (runtime remount plus `/etc/fstab`, which `systemd-remount-fs` applies at boot). Unprivileged accounts then cannot see other users' processes at all; root and members of `twebproxy-procview` still can. Managed with `twebproxy proc-hardening status|enable|disable`; the audit reports `procfs.secret.protection` (ERROR when exposed, WARNING when explicitly disabled). Consequence: monitoring agents that run unprivileged and need the full process list must be added to the exempt group.

v0.2.24 (P1-B): a backend never runs because of a manager operation while the effective `/proc` exposes command lines. `add`, `repair` and `core-install` apply the policy before any backend starts; when that fails, every TWebProxy backend is stopped (and proven stopped) and the command fails. Every start path (`start_profile_backend`, and systemd's own starts through `ExecStartPre=+backend-start-check` in PID 1's mount namespace) refuses unless `/proc` is protected or the operator opted out explicitly. Protection is judged on the effective (topmost) `/proc` mount of `/proc/self/mountinfo` and confirmed behaviourally (an unprivileged `nobody` must not be able to read `/proc/1/cmdline`), so a stacked unprotected proc mount is no longer hidden by a protected lower one. The opt-out (`twebproxy proc-hardening disable`) asks for confirmation on a terminal, is recorded with time and user in `/etc/twebproxy/proc-policy`, is logged by every backend start and stays a WARNING in the audit. Limitation: a separate proc instance that root mounts elsewhere (another mount namespace or path) is outside the manager's view; the manager judges its own and PID 1's namespace.

