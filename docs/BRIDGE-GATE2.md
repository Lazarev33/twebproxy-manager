# Bridge Gate 2 MVP

This historical Gate 2 MVP extends accepted v0.2.24 commit
83e001ed49bfe210dc4d79aaccd15d72e406045d. It received CONDITIONAL
ACCEPTANCE (17 PASS, 0 FAIL, 8 NOT_EXECUTED). The Gate 3 v0.2.25-beta source
is now in GitHub main, but no stable Release exists.
See [architecture](ARCHITECTURE.md) and [Gate 3 operations](bridge-gate3/OPERATIONS.md).
One entry, one trusted foreign node, one existing hostname with exactly one
profile. This whole instance becomes a Bridge. Other instances remain local.
The exit operator/root can recover the canonical MTProxy secret. Enroll only
an exit you trust. SSH authentication is verified against an independently
obtained ED25519 fingerprint before credentials are sent.

## Install and use

Keep `twebproxy-manager.sh` adjacent to the complete `bridge/` directory from
this archive. Run the normal Manager installation/domain setup on the entry.
Normal local-only use does not load Bridge Python dependencies. Then use the
Foreign Nodes menu, or:

```
sudo ./twebproxy-manager.sh foreign-node add
sudo twebproxy foreign-node status
sudo twebproxy foreign-node diagnose
sudo twebproxy foreign-node repair
sudo twebproxy foreign-node remove
```

The Add workflow asks for exit host, SSH user/port, authentication method,
independent SSH fingerprint, existing private key path or hidden password,
and approval after both inspections. Noninteractive fields are available via
`--host`, `--user`, `--port`, `--instance`, `--auth key|password`, `--identity`,
`--fingerprint`; `--approve` accepts the displayed installation plan.
Passwords and key passphrases have no command-line option. Initial accounts
must be root or have existing passwordless sudo. A separate sudo password,
hardware SSH agent, proxy jumps and non-Ed25519 host keys are unsupported.
An operator-supplied private key is never copied or changed.

The controller installs a dedicated key, root-owned AuthorizedKeysFile,
forced typed command and exact sudo target. It verifies a second restricted
connection before discarding the initial authenticated session. There is no
remote API daemon. Subsequent checks do not require the initial password.
Both hosts generate their own WG private key; only public keys cross SSH.
The canonical profile remains the source for client credentials. Client links
are deliberately printed by the normal Manager show command; treat these as
secrets. Do not redirect Add/show output into a public log.

## Resources and lifecycle

Owned state is root-only `/etc/twebproxy/bridge` on the entry and
`/var/lib/twebproxy-bridge/<uuid>` on each host. A journal/owner marker is
written before remote changes and cutover. Mapping is restored only after
the original local backend is running. Incomplete cleanup retains identity
and state, blocks enrollment of another node, and reports PARTIAL. Retry
repair. If enrollment failed before the dedicated connection became usable,
repair accepts `--identity <initial-key>` or `--auth password --user <initial>`
for cleanup; it does not silently adopt an unknown remote installation.
Repair of an interrupted Add compensates/removes it; run Add again.

Owned unit prefix `twb-<uuid12>-`, device `twb<uuid8>`, owned nft table
`twb_<uuid12>`, key `/etc/wireguard/twb-<uuid>.key`, management user
`twb<uuid10>`. SSH, Caddy, firewall policy and packages unrelated to the
node are retained. Dependencies installed via apt are not removed during
rollback. Proc hidepid is host-wide and may affect monitoring; installation
approval includes this change. Removal restores visibility only if this
node introduced hardening and no other MTProxy process remains. Cold boot
has not been tested. Never remove credential/state directories manually to
work around cleanup debt.

Private forwarding is one systemd-socket-proxyd with loopback ListenStream,
4096-backend connection budget (forwarder maximum 4160), FD limit 65536,
IPAddressDeny=any preserved, localhost and exact peer /32 allowed. No stats
port is tunneled. Foreign stock MTProxy allows localhost, documented DC
ranges and only the exact entry inner /32. Own nft rules enforce interface,
source and destination. Guard precedes WG; blackhole fallback prevents
private-peer traffic escaping through the public default route.

A 10-second local data-path watcher stops the forward socket then service
after three failed TCP checks; two successes permit socket activation again.
No readiness claim is based solely on a WG handshake. Diagnose separates
route/TCP/service/security from MTProto and genuine client results, which
remain UNKNOWN unless separately measured. Owned Telegram public materials
refresh every seven hours; a failed refresh preserves previous files.

## Scope and compatibility

Real tests: Ubuntu 26.04 x86_64 entry / Python 3.14 and Ubuntu 24.04 x86_64
exit / Python 3.12. Vendored offline wheels support only these Python/CPU
combinations. Active swap is refused for credential handling. No general
Ubuntu compatibility claim follows from one tested installation.
Debian 12, Ubuntu 22.04, ARM, cold boot, genuine Telegram application login,
message/media transfer and constrained-network comparison are NOT_EXECUTED.
A valid public DNS/TLS frontend remains the existing Manager's responsibility.
The lab used an existing managed frontend fixture and a pinned self-signed
certificate. An initial clean core install hit a Telegram material download
timeout; complete from-zero novice installation is not a demonstrated PASS.
Manager executable update/rollback and profile add/delete/rotation are
blocked while a Bridge is attached. Remove the node before these operations.
Fleet upgrades, rotations and multiple nodes/balancing were excluded from Gate 2. Gate 3 was developed separately; see its operations and client evidence.
