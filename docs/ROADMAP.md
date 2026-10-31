# TWebProxy Manager — Development Roadmap

Updated: 2026-10-31. This documents actual development checkpoints and remaining RC gates.

## Repository publication and evidence

GitHub `main` now contains **v0.2.25-beta** with `bridge/`, `sites/` and the Bridge TUI refusal correction; it is development source, not a stable Release. The focused v0.2.24 backend isolation/procfs P1 fixes were accepted independently for their scope; v0.2.23 was rejected. Bridge Gate 1 was CONDITIONAL GO, Gate 2 CONDITIONAL ACCEPTANCE (17 PASS / 0 FAIL / 8 NOT_EXECUTED). Gate 3 includes a public test site/TLS and operator-reported iOS 13.1.2 connection with server-side corroboration, not independent end-to-end file integrity proof or full client acceptance.

## Product goal

A dependable, easy-to-operate manager for Telegram native WEB Proxy: official `telegramdesktop/tproxy-server` + stock MTProxy, HTTPS/WebSocket transports, Caddy/Nginx, a real public website on the same hostname, optional carefully scoped anti-DPI methods, secure updates and meaningful diagnostics.

Two supported user journeys:
- **Quick setup:** domain → HTTPS → real website → WEB proxy → client connection information, with safe defaults.
- **Advanced administration:** instances, profiles, keys, carriers, backend isolation, diagnostics, certificates, optional anti-DPI and rollback.

Keep the public website genuinely functional; do not claim that HTML alone can hide the server's IP, SNI, TLS fingerprint or traffic characteristics. Do not promise complete DPI invisibility.

## Current checkpoints and release status

| Stage | Status | Remaining limitations |
| --- | --- | --- |
| v0.2.9–v0.2.22 / A–H | Historical development | Stage H 98/98 model UX checks |
| v0.2.23 | REJECTED | Two reproduced P1 issues |
| v0.2.24 | FOCUSED ACCEPTANCE | Both P1 corrections, not full RC |
| Bridge Gate 1 | CONDITIONAL GO | Two-VPS WG/TCP and server protocol |
| Bridge Gate 2 | CONDITIONAL ACCEPTANCE | 17 PASS / 0 FAIL / 8 NOT_EXECUTED |
| Gate 3 / v0.2.25 | DEVELOPMENT SOURCE IN MAIN | Default site, Bridge and operator-reported iOS test |
| Bridge menu fix | LOCAL REGRESSION PASS | Not confirmed deployed on RU Entry |
| CLI/TUI correction + Smart Defaults | PRIORITY; NOT YET ACCEPTED | Confirmed discrepancies, then safe defaults and preset UX; not shipped in 0.2.25 |
| RC / stable Release | NOT AUTHORIZED | Platform/client matrix, cold boot, security, verified distribution |

Current priorities: targeted CLI/TUI correction, Smart Defaults, Bridge compatibility and multi-profile support, followed by bundled site choices and separately authorized Multi-Exit research. Do not assume completed implementation from this plan. See [ARCHITECTURE.md](ARCHITECTURE.md) and [CLIENT-VALIDATION.md](bridge-gate3/CLIENT-VALIDATION.md).

## Non-negotiable engineering constraints

- No production VPS changes during development, audits or fault injection.
- No resurrection of rejected advanced Stage 3 recovery, LKG, journal or generic exact-state engine. Use bounded, operation-local transactions and the simple backup-before-update / rollback-to-previous-version approach.
- Preserve stock MTProxy as the backend baseline; Caddy is the recommended greenfield frontend, Nginx remains supported for existing setups.
- The six existing DPI mode IDs and pinned nfqws binary remain stable until a separately approved change.
- Anti-DPI on local outgoing IPv4 TCP:443 may affect unrelated services on the same IP. STOCK default; explicit shared-scope consent; no automatic aggressive DPI changes.
- Keep protected Stage 4 functions unchanged until updater/supply-chain work is specifically authorized.
- Any production manager code change bumps machine-readable `VERSION`, `MANAGER_VERSION` and release label coherently; refresh SHA manifests and relevant fixtures.
- Every stage requires its own source checkpoint, targeted tests, error-path evidence and honest PASS / FAIL / NOT_EXECUTED reporting. No claim of kernel behavior from mocks alone.
- No unreviewed merge, push to `main`, automatic deployment or release from an engineering checkpoint.
- Retain security fail-closed requirements (procfs, systemd IP policy, SSH host verification, explicit destructive approval). A compatibility failure is not evidence that a security refusal should be disabled.
- Never weaken verified manager-update trust to make an automatic update appear to work; development `main` is not a stable, signed update channel.

## Immediate work: Bridge Gate 3, TUI and RC

Actual Bridge route: RU HTTPS front end → tproxy-server → loopback TCP forwarder → WireGuard → private stock MTProxy on Foreign Exit → Telegram DC. The website and one client link remain on RU Entry. The local single-VPS mode is retained.

Next: verify clean installs, two-host cold boot, safe recovery and removal, TLS/renewal, external backend exposure, supported clients including Desktop and non-tested OS/CPU combinations. Keep synthetic protocol evidence distinct from genuine application tests and operator reports.

Smart Defaults follows a focused CLI/TUI correction. See the priority gates below: retain Advanced/manual paths, security approvals, all six DPI modes and STOCK by default; do not automatically enable aggressive DPI methods.

Do not conflate a GitHub development source commit with a stable signed Release or trusted automatic update. Prior accepted P1 corrections need a new reproducer before reopening.

## Prioritized post-Gate 3 development — findings of 31 October 2026

**This is a plan, not an acceptance report.** The authoritative published baseline is v0.2.25-beta in GitHub `main`. Work already delegated to Codex must be reconciled before editing; do not overwrite in-progress UI changes. Do not preassign a new version number or silently promote a development checkpoint to RC.

### Priority 0: focused CLI/TUI correction before approving Smart Defaults

The following are grounded in current code or reported local test evidence. Each implementation change still needs a bounded RED/GREEN reproduction against the exact source commit.

| Finding | Evidence / source | Required correction |
| --- | --- | --- |
| RU/EN confirmations inconsistent | Bash `yesno()` and `stage4_confirm_restore()` accept only one character `[YyДд]`; Bridge Python `confirmed()` accepts `yes` and `да` | Accept explicit RU/EN answers consistently. Preserve each existing default; destructive/restore operations remain default-no; EOF never means approval |
| Localization regression | Direct English `die` strings in `bridge_internal_cmd` and Bridge CLI. `tests/localization-static-audit.sh` reported FAIL | Move user-visible errors through the catalog/translation path; test complete RU/EN output, including failures |
| Standalone Bridge test lacks isolated dependencies | `tests/bridge-gate3/test_bridge_menu.py` imports `controller.py` directly; its `import paramiko` fails with bare Python, though launcher has verified offline wheels | Provide a clean reproducible test environment using the verified bundle or scoped test doubles; no global pip installation |
| Bash error-trap context on noninteractive `foreign-node` failure | Reported `pop_var_context` messages with ERR trap during failed CLI calls; interactive menu already has a focused correction | Reproduce actual error control flow, fix only the failing path, retain nonzero exit code and clean machine-readable output |
| Misleading update hint | `manager-update` can reject when signature trust anchors are unset and independently verified `--sha256` has not been provided | Explain the trust prerequisite in help/TUI; **never** bypass verification or silently trust unsigned updates |

**Acceptance:** `bash -n`, bilingual static localization audit PASS; all Bridge-menu/CLI tests PASS from an isolated fresh environment; correct RU/EN confirmation, negative/EOF behavior, exact CLI exit codes, no `pop_var_context`, no state mutation after refusal; updated error/hint documentation. Only label a defect a release **BLOCKER** when it demonstrably affects security, state integrity, availability or a required workflow; keep P2/P3 cosmetic findings outside the critical path.

### Priority 1: complete TUI Usability & Smart Defaults

Audit every interactive prompt in first run, quick/advanced setup, profiles, Anti-DPI, Bridge, diagnostics, TLS, updates and maintenance. Produce a source-located inventory with four classifications: `AUTOMATIC`, `PRESET`, `REQUIRED`, `CONFIRMATION`.

- Automatically generate secrets, pick verified free internal ports, reuse unambiguous existing profiles/instances, select the bundled default site and suitable documented TLS defaults; do not re-ask known values.
- Replace avoidable raw numerical/text parameters with numbered descriptive presets. Keep Advanced/manual access and existing noninteractive CLI semantics.
- Anti-DPI: preserve all **six** IDs, `STOCK` default, explicit shared-IPv4 scope approval, real diagnostics and rollback. Never claim the VPS can determine an ISP's client-side DPI method without evidence.
- Bridge: request only essential foreign SSH information and independent host-key verification; display a plan before provisioning. Normal operational refusal must return to TUI, not exit the whole manager.
- **Read-only preflight before mutation:** effective Python ABI/architecture, offline wheel availability, swap status, cgroup-BPF/systemd IP filtering, procfs policy, DNS/TLS/ports. Show exact unsupported conditions and the next safe action without turning off safeguards.

**Acceptance:** visibly reduced normal-flow manual inputs; complete input inventory; TUI RU/EN and 40/80/120-column test coverage; clean local and Bridge setup fixtures; cancel/EOF, conflicts, missing credentials and failing security preflight; regression of current CLI and Gate 3 Bridge menu behavior. Produce one self-contained ZIP with tests/evidence and SHA-256 manifest. This priority does not assert that the work is already shipped.

### Priority 2: Bridge platform compatibility and multi-profile on one Exit

**Compatibility first.** The bundled Bridge launcher currently admits only **x86_64 Python 3.12 or 3.14**, while the core/local Manager declares a wider Debian/Ubuntu baseline. These are *different* support matrices. The known Bridge lab was Ubuntu 26.04 Entry and Ubuntu 24.04 Exit; Debian 12 / Ubuntu 22.04 are not proven Bridge PASS.

- Add/test **complete transitive offline dependencies** for Python 3.10 (Ubuntu 22.04) and 3.11 (Debian 12) where feasible, rather than assuming a `cffi` wheel alone suffices. Exercise full install/repair/remove on real isolated supported hosts. ARM64 is a separate optional compatibility gate.
- Review the **active-swap refusal** as a documented security tradeoff, not an arbitrary crash. Keep fail-closed handling until a tested threat model supports an alternative. `mlock` applied to one Python buffer is not proof every copy of a password/key is swap-safe; never disable user swap automatically.
- Preserve effective systemd per-unit IP filtering, nftables isolation and procfs protection. Unsupported LXC/OpenVZ or kernels without effective enforcement remain explicit limitations unless equivalent safety is demonstrated and independently tested.
- Support **at least two independent profiles on one bridged instance and one foreign Exit**: distinct secrets, link generation, add/rotate/revoke, per-profile backend routing, status, repair, rollback and removal. Preserve other local instances and recover safely from partially completed operations.
- **Do not add a second foreign node in this milestone.** One Exit with multiple profiles and Multi-Exit failover are different product changes.

**Acceptance:** supported OS/Python matrix with real results (PASS/FAIL/NOT_EXECUTED), safe rejection of unsupported hosts before any mutation, two-or-more-profile tests, isolation checks, simulated failure and remote cleanup, no lost credentials or accidentally public backend port. Document any unsupported versions rather than implying universal Debian/Ubuntu compatibility.

### Priority 3: a small site catalogue (without DPI folklore)

Keep `sites/podmoskovye/` as the existing default and `placeholder` compatibility for older instances. Add several substantial, user-selectable static websites with previews and deterministic integrity manifests. Preserve existing operator site edits during repair/upgrade and support custom static directories/loopback applications.

Distinct pages may avoid identical **content under active inspection**, but passive observers cannot ordinarily read HTTPS HTML/CSS as plaintext; changing markup is **not** a proven way to hide public IP, SNI or TLS fingerprints. Do not claim camouflage, guaranteed censorship bypass, or automatically generated uniqueness without measurements.

**Acceptance:** a bounded site library with verified assets/licensing, no runtime analytics/CDN dependencies by default, mobile usability, integrity and safe-path checks, repairs that preserve custom content, deterministic tests for legacy `placeholder`, existing sites and explicit deletion. A full website generator/editor is separate optional work.

### Later research gate: Multi-Exit, failover, modularity and packaging

Compare two or more foreign Exit nodes and a single RU-facing client link with a measured failure/recovery matrix. As a reference, inspect the tunnel-pool ideas of [mtproto.zig](https://github.com/sleep3r/mtproto.zig), but do not assume its route-switch approach can be copied into our socket-proxyd/WireGuard/MTProxy system. Study per-Exit secrets and trust, health beyond a WireGuard handshake, route ownership, failover flapping, stream interruptions, cleanup and rollback.

Separately evaluate signed/prebuilt artifacts, smaller dependencies and modular Bash/Python boundaries. The current 10k+ line Bash manager imposes maintenance cost, but **a full Go/Zig rewrite, new backend, Docker or container support is not authorized by this comparison**. Require a measured benefit and a migration path retaining CLI/state/security invariants.

**Deliver research first:** comparable alternatives, threat model, measurable performance, disposable-host PoC, failure injection, client reconnection evidence and explicit GO/NO-GO. Do not automatically enable Multi-Exit or describe it as delivered.

### Discipline and release gates for every priority

1. Freeze the current source hash and reconcile active Codex work. Avoid destructive resets, force-pushes, unnecessary full-project audits and unapproved production changes.
2. Prove each material defect with focused reproduction and targeted regression. Distinguish BLOCKER, P2/P3 and compatibility/research items. Do not reopen independently accepted v0.2.24 P1 fixes without new evidence.
3. Keep exact files, automated tests, actual PASS/FAIL/NOT_EXECUTED evidence and **one all-in-one ZIP + SHA-256 manifest**. Validate a fresh extraction.
4. Test real kernel/network/client effects on explicitly authorized isolated hosts; synthetic tests alone do not establish client support or censorship resistance.
5. Update README, SETUP, SECURITY, ARCHITECTURE, compatibility information and CHANGELOG **only as behavior changes**. Promote to GitHub `main` only from a completed, verified development checkpoint without rewriting history.

## Mandatory disposable Linux validation (before RC; prioritize after B.1)

Use a separate sacrificial Linux VM/host with an isolated firewall/network, root test privileges and controlled test filesystems. **Never use the live Telegram proxy VPS.**

- Actual nft kernel transactions: valid replacement, invalid candidate, deliberately failed batch, initial install, zero/one/multiple backends, foreign table invariance, restart/reload/uninstall behavior, postconditions.
- Actual systemd unit lifecycle: normal start/reload/restart/stop and dependency propagation; no unexpected service disruption during routine firewall rebuilds.
- Actual DPI verifier with nft JSON and rendered rules (F12); six existing modes and scope collisions.
- Actual ENOSPC interruption using an isolated filesystem or mount namespace; state preservation and truthful test result.
- Negative control: prove test runner refuses unsafe environments.

Record commands, pre/post states, exit codes and exact environment. An unavailable test is NOT_EXECUTED, not PASS. Real-kernel validation may run while later development proceeds in isolation, but it is a hard release gate.

## Core implementation stages (after B.1)

| Stage | Scope | Acceptance principle |
| --- | --- | --- |
| **C1 — state and profiles** | Correct profile selection/clobbered globals, atomic profile/backend persistence, rotation races, local lifecycle locks, port allocation | No wrong target, lost secret, partial state or false success |
| **C2 — relay lifecycle** | Relay binary update, restart/health failure rollback, instance lifecycle failure propagation | Previous working binary/state retained on failure |
| **D — frontend / TLS** | Transactional Caddy managed markers, safe Nginx LE issuance/renewal, candidate validation, rollback | Existing website and TLS survive failed changes |
| **E — operations / diagnostics** | TUI EOF/default-no, read-only diagnostic timeouts, truthful status, logs/report handling | No false-green output, hangs or accidental yes |
| **F — updater / supply chain** | Explicitly authorized Stage 4 updater changes, lock cleanup, provenance/signatures or strong pinned artifact verification, rollback | Trusted, verifiable update with prior-version recovery |
| **G — hardening** | Privilege boundaries, config validation, ownership, bounded resources, remaining confirmed audit backlog | Safe defaults and predictable degradation |
| **H — user experience** | Main-menu Anti-DPI, guided quick setup, advanced controls, actionable statuses, RU/EN, desktop/mobile guidance | Novice usability without bypassing safety gates |

Stage identifiers are fixed planning names; exact `0.2.x` version numbers after B.1 are **TBD** and must be assigned sequentially at implementation time. Keep work bounded; do not turn each stage into a full release audit.

## WEB transport, compatibility and anti-DPI research

Create an evidence-backed **research / design gate before implementation**. Do not blend it into B.1 or the core reliability corrections.

- Re-evaluate pinned official `tproxy-server` versus the current upstream commit/protocol and the third-party `tgwebproxy` implementation. Review license, support, session token signing and `token_key_file` migration, config compatibility, release pinning and client requirements.
- Compare `https`, `https-lanes`, `websocket`, `websocket-lanes` under consistent network conditions, with throughput, connection survival, background/resume behavior, large media and actual Telegram handshakes. WebSocket is a candidate, **not** a proven universal default.
- Research official `base_path` capability and routing behind a genuine existing website; it requires matching client capability, frontend rules and safe migration.
- Compare existing STOCK/Window1152/MSS88/nfqws combinations with current zapret/zapret2 (`nfqws2`) server modes. Assess directionality, nft scope, side effects, overhead and reproducible benefit. Research is not authorization to install or change the pinned anti-DPI binary.
- Assess CDN only against actual WebView, long-poll and WebSocket behavior; JS challenges and origin routing can break the bridge.
- Maintain an explicit Desktop / Android / iOS client-version matrix including foreground, background, network switching, reconnect and media tests. Avoid claiming client compatibility from `/readyz` alone.
- Separate `systemd running`, `TLS valid`, `relay ready`, `WEB handshake proven` and `Telegram client confirmed` in the product status model.

Output: candidate matrix, measured results, threat/compatibility assumptions, implementation design, migration gates and non-goals. Implement only approved, proved improvements in a separate post-core stage.

## Website: bundled default and future Site Manager

**Implemented:** `sites/podmoskovye/` provides the fixed default «Культурные маршруты Подмосковья»; Quick Setup uses it, and repair preserves edited deployed sites. Custom directories and loopback upstream sites remain available. [DEFAULT-SITE.md](bridge-gate3/DEFAULT-SITE.md).

**Priority 3:** a selectable set of useful, maintained static site templates with previews and preservation of custom site edits. Retain legacy `placeholder` state for compatibility. A full site generator, upload/editor, and site backups require separate acceptance. HTML does not hide IP, SNI or TLS characteristics or guarantee DPI bypass.

## Release candidate and v1.0 gates

After implementation milestones, perform an **integrated validation campaign** instead of repeated all-project audit loops after every small stage:

- Fresh Debian/Ubuntu installs and safe upgrades preserving existing profiles and sites.
- Disposable kernel nft/systemd/ENOSPC failure injection and reproducible test isolation.
- Independent code/security review of real candidate artifacts; every confirmed blocker has a reproducer and a regression test.
- Four WEB carriers, desktop and eligible mobile client matrix, sleep/reconnect, media transfer, firewall external scans, cert renewal and restart/crash behavior.
- Real website and WEB bridge coexistence on a single hostname, no secrets in publicly served content.
- TUI RU/EN, 40/80/120-column terminal behavior, installation, logs, errors and rollback.
- Supply-chain and artifact checks: exact pinned dependencies, manifests, reproducible version identity, rollback.
- Versioned RC checkpoint (proposal `0.9.0-rc1`), then `1.0.0` only with explicit acceptance.

## Historical roadmap notes (kept for continuity)

The earlier v0.2.6–v0.2.9 baseline delivered Caddy + HTTPS + stock MTProxy, systemd credential/AF_NETLINK fixes, isolation audit, compact diagnostics, field reboot/autostart checks, manager update channel and TLS/listener checks.

Earlier planned field tests remain relevant: `https-lanes`, `websocket`, `websocket-lanes`, Nginx + Let's Encrypt, large transfers, sleep/network switch, backend/relay crash, and external backend-port scans. These are incorporated into the client/lab matrix above.

The earlier `0.3 experiment branch` idea (`stock-mtproxy`, `telemt-direct`, `telemt-middle-end`) is **deferred research**, not an approved additional backend for the current 1.0 path. Only evaluate after the stock baseline and WEB/decoy roadmap are proven.
