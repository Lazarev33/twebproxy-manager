# RC1 field acceptance continuation — 2026-11-02

This unpublished 0.9.0-rc1 correction continues source `c0d5ccee5895a475ff213fecb276fd29d4e6fc7e`.
The complete runtime SHA256 is
`31f2a553201535cc00c70573593c458eaf4ff4a4dc27aa8ceab6ce211a368912`;
Manager SHA256 is `c2f99fa6f7a1229daf27541b95246478c29938611ef79255d2a471ca9c27d7ea`.
The review handoff records the final Git commit, test matrix and sanitized evidence.
These are corrections within the owner-authorized unpublished RC1 checkpoint,
not mutation of an already published release or authorization for stable release.

## Reproduced platform blockers and corrections

1. Debian12 and Ubuntu22.04 jq1.6 reject the reserved binding `$if` in the
   strict backend table verifier. Rename the binding only; accepted/rejected
   table shapes, transaction and rollback behavior remain identical.
2. Ubuntu22.04 Bash5.1 serializes the function redirection `>&"$guard_fd"` as
   `&>"$guard_fd"` through `declare -f`, writing commands into a numeric file
   instead of the persistent nft owner pipe. Use `>"/dev/fd/$guard_fd"` for the
   same descriptor. Batch contents, owner lifetime and reload behavior are unchanged.
3. Ubuntu22.04 systemd249 rejects `%d` in the generated relay unit. Reference
   the same systemd-managed credential through `${CREDENTIALS_DIRECTORY}`.
   LoadCredential, the unprivileged service identity and all restrictions remain.
   This syntax is documented in [systemd.exec247](https://www.freedesktop.org/software/systemd/man/247/systemd.exec.html).

Executable RED/GREEN evidence uses actual Bash5.1/5.2, jq1.6 and nft1.0.2/1.0.6
in genuine Ubuntu22.04 and Debian12 KVM guests. The generated guard is exercised
in private kernel network namespaces: create, populate, clear, reject unexpected
rules, owner exit. A real unprivileged transient systemd unit reads a root-only
fixture through the generated credential path. No production secret is involved.

Only three Manager functions change relative to c0d5ccee. The template differs
by that single ExecStart argument; backend BPF/procfs policies are identical.
Bridge agent/controller, updater engine, topology, carriers, Anti-DPI methods,
credentials and website bundle are byte-preserved.

## Genuine infrastructure results

Both authorized public VPSs completed actual full OS reboots with independent
persistent collection from the development host. Foreign reboot recovered its
protected backend and unrelated services automatically. Entry reboot with a
temporarily unavailable peer withdrew the forward socket and restored fresh
connections when the peer recovered. A provider power-off/power-on was not tested.
Canonical files and IP policies were preserved; unprivileged secret reads failed.
Finite public probes observed zero backend opens, with positive443/negative65534
controls and explicitly retained host-down/control gaps. These are not universal
continuous exposure proofs or a repeat of the historical P1 campaign.

The corrected complete distribution subsequently returned UPDATE_SUCCESS on
both public hosts. All342 canonical files, selected service PIDs/start times/
restart counters, policy rules and routes were preserved (only dynamic IPv6 RA
expiry seconds are excluded from route equality). Public trusted HTTPS through
the actual Bridge returned nonce-matched resPQ. Synthetic probes are separate
from the operator's application tests; none run during the new client windows.

## Clean installation and platform limits

- Ubuntu24.04 fresh KVM: ordinary Quick Setup using domain plus explicit approval,
  official dependency downloads/builds, bundled site, installed diagnostics and
  genuine public Let's Encrypt issuance on the authorized disposable test domain.
  HTTP redirect and public HTTPS/site were checked independently from both VPSs.
- Debian12 fresh KVM: ordinary Advanced setup with an explicit private test CA,
  installed audit, real BPF and loopback-only checks; subsequent complete update
  and repair preserve the operator-edited site, profile/secret and TLS.
- Ubuntu22.04 fresh KVM after corrections: ordinary Advanced setup, private-CA
  HTTPS/site, isolation audit, full guest reboot, repair, deletion and core uninstall.
  Edited site/TLS/profile and an unrelated Nginx service are preserved as applicable.
- These are x86_64 local-mode tests, not broader Bridge support. Bridge's tested
  Ubuntu26.04 Entry / Ubuntu24.04 Exit matrix is not extended to Python3.10/3.11.
  ARM and other unadvertised variants remain out of supported scope.

The public Quick VM uses QEMU user networking. Its backend protocol probe did
not receive a Telegram response, and its self-audit during repair cannot hairpin
through the public forwarded address. Do not call this a fully successful fresh
public proxy journey. The precise RPC failure cause is not established.
An additional native-network systemd-nspawn control could not enforce per-unit
BPF accounting; the normal start gate correctly refused every backend. No
protection was bypassed. Container support and native-control application success
are not claimed. All original failures and fixture mistakes remain in the handoff.

Production Caddy certificate management/contact/configuration were inspected.
A separate genuine public Certbot standalone staging challenge passed without
replacing the Quick VM's working Caddy certificate. A prior webroot attempt was
an invalid fixture assumption (hidden challenge files were not routed there).
This does not prove a future Caddy renewal event or Manager's Nginx renewal path.

## Application evidence and remaining acceptance

The handoff's client matrix records operator reports for each carrier/device
separately, corroborated by aggregate relay/WireGuard counters and service states.
Keep prior iOS HTTPS VPN/mobile acceptance separate from this Wi-Fi/PC LAN window.
Exact application builds, byte-exact file hashes and unreported actions are not
invented. The same private Manager-generated connection link is used across
carrier selections; no secret/link or message content is archived.

First-RC independent review, a fully functional clean public-IP installation,
unavailable client/network combinations and an actual future renewal event remain
explicit gates. Consult the delivered RESULTS.json, REPORT.md and remaining
acceptance matrix for the final GO/CONDITIONAL GO/NO-GO recommendation. PR1 stays
draft: no main merge, tag, GitHub Release or1.0 publication is authorized.

## Focused reproduction

On a marked disposable system with root and real kernel/systemd access:

```sh
python3 tests/final-rc/platform_firewall_compat.py /absolute/source/twebproxy-manager.sh
python3 tests/final-rc/credential_unit_compat.py /absolute/source/twebproxy-manager.sh
bash tests/tui-smart-defaults/run-local.sh
```

The first test unshares the network namespace before any nft operation. The
second only generates templates privately and executes an independent transient
credential fixture. Image preparation, trusted SSH identities, exact installation
inputs, raw sanitized evidence, cleanup and historical RED reproduction are in
the all-in-one handoff. Root-only VM disks, keys, transcripts and recovery archives
remain outside every deliverable.
