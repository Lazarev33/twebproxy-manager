# Bridge Gate3 development checkpoint — operating guide

Baseline Gate2: 3375c4a9d5057bab453ce3fdc41b688a06b6ab77.
Security baseline: 83e001ed49bfe210dc4d79aaccd15d72e406045d.
Version: 0.2.25-beta; source published in GitHub main on 2026-10-31. No stable Release or production authorization. The installed lab system may differ from published patches.

## Install the complete distribution

Verify the outer archive SHA and its SHA256SUMS before executing code. From the
unpacked `source/` directory run `sudo ./twebproxy-manager.sh menu`. Keep bridge/
and sites/ beside the script: the complete distribution includes pinned offline
SSH dependencies and the fixed default website. The complete GitHub main source now contains this development checkpoint. Existing custom static/upstream options remain.
The tested Bridge platforms are x86_64 Ubuntu 26.04 entry and Ubuntu 24.04 exit.
Debian 12/Ubuntu 22.04/ARM have not been tested for this checkpoint.

First Run -> Quick setup installs official pinned relay/MTProxy builds and their
normal dependencies. Select the bundled cultural site, enter a domain pointing
to the entry, choose Caddy and provide the ACME email, then approve. There is no
manual website upload. Public 80/443 must be available; inspect before deployment.
Caddy retains unrelated configuration blocks, proxies the whole hostname through
the existing relay, issues via Let's Encrypt and manages renewal natively.
Supply the ACME contact email privately. Do not include personal addresses in public source documentation. No TLS verification bypass is used.

Official Telegram public material downloads use authenticated HTTPS, IPv4,
8-second connect/20-second attempt limits, three retries and bounded retry time.
Payload validation happens before installation. A failed second fetch leaves
both existing materials intact; a failed second publish restores the first.
The refresh service uses the same bounded policy. These are dynamic official
server materials, not a fixed checksum-pinned binary release. Go archives retain
their upstream checksum verification; both server source commits remain pinned.
No manually prepared server material or unverified replacement binary is needed.

## Automatic foreign node workflow

On the installed Manager open Foreign Nodes -> Add Foreign Node, or use
`sudo twebproxy foreign-node add`. Enter foreign host/SSH port/user, independently
verify the ED25519 fingerprint, choose password or existing protected key, review
both inspections/change plan, and approve. Root or preexisting NOPASSWD sudo is
required. A separate sudo password is unsupported. Passwords/passphrases are
hidden, memory-only and have no CLI flag. Entry active swap is refused.

One node and one profile per Bridge instance remain the Gate2 MVP boundary.
The canonical profile secret is reused. Unique WG keys remain on their original
host. Management switches to a restricted per-node key/account with forced typed
commands, no PTY/forwarding and an exact sudo target. No public management API.
Other foreign services/instances are allowed if their ports/routes/owned resources
do not conflict. Authoritative old backend port reservations are checked even
when a neighboring service is stopped. No foreign profile needs to be parked.

Use `sudo twebproxy foreign-node status`, `diagnose`, `repair`, `remove`.
Installed `restart HOST` and `repair HOST` dispatch to Bridge recovery when
attached. The dashboard checks the forwarder, not the deliberately stopped local
MTProxy. TCP/kernel status is distinct from genuine Telegram application proof.
A real lost-route after interface down/up is now reconciled by the watcher only
for the owned exact /32, with its blackhole fallback, an UP interface, matching
WG public identity and a live guard. It preserves competing operator routes.
The final measured real outage stopped forwarding then recovered automatically
when the interface returned, without Manager repair. Existing streams may close;
the application must reconnect. No claim of seamless TCP-stream migration.

Manager executable updates/rollback and profile add/delete/rotation remain
blocked while attached. No fleet/managed release-upgrade mechanism was added.
Repair is repeatable. Removal restores the previous local port/profile only
after the old protected backend is ready. Unreachable exit cleanup remains
PARTIAL with identity/tombstone retained; restore connectivity and retry repair.

## Client validation status

The operator reported successful Telegram for iOS 13.1.2 text, photo, video
message, large-file and Wi-Fi/LTE reconnect behavior over the RU-facing link.
Server counters corroborate traffic, but independent file hash/content validation
was not performed. Desktop runtime and other clients are NOT_EXECUTED.
See [CLIENT-VALIDATION.md](CLIENT-VALIDATION.md).

## Bundled default site and operator changes

See DEFAULT-SITE.md. The live public deployment is https://martins.ortositi.ru/.
It uses the same bundled/default path as a newly configured arbitrary domain.
A source path/custom website fixture is not required for this final deployment.
Custom static directories and numeric loopback upstream websites are still options.

## Current lab deployment and cleanup

Authorized RU Entry and Foreign Exit lab VPSs only. Production is excluded. The final
Bridge/site/TLS and their managed credentials intentionally stay installed for the
operator. Existing foreign Manager, global.env, Caddyfile and profile files are
preserved and its original four services remain active. New apt test/build
packages are retained rather than purging shared dependencies. The isolated VM,
password-bootstrap fixture account/config and temporary administrative SSH keys
are separate test resources; their cleanup is documented in the final report.
Never remove the active node's managed key or WG private key as test cleanup.

Explicit application removal: run `sudo twebproxy foreign-node remove` first,
then `sudo twebproxy delete martins.ortositi.ru` and approve deletion if desired.
That deletion intentionally removes the instance's live website; it is distinct
from a nondestructive update/repair/reinstall. Core-uninstall requires no
remaining hostnames. It retains Manager and the verified default-site cache so
future first-run setup works from the installed Manager without a source upload.
No server reboot was performed or certified. Cold-boot compatibility is not
inferred from service recovery or a disposable VM installation.
