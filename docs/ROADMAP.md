# TWebProxy Manager — Development Roadmap

Updated: 2026-10-29. This document tracks **planned work**, not production release status.

## Product goal

A dependable, easy-to-operate manager for Telegram native WEB Proxy: official `telegramdesktop/tproxy-server` + stock MTProxy, HTTPS/WebSocket transports, Caddy/Nginx, a real public website on the same hostname, optional carefully scoped anti-DPI methods, secure updates and meaningful diagnostics.

Two supported user journeys:
- **Quick setup:** domain → HTTPS → real website → WEB proxy → client connection information, with safe defaults.
- **Advanced administration:** instances, profiles, keys, carriers, backend isolation, diagnostics, certificates, optional anti-DPI and rollback.

Keep the public website genuinely functional; do not claim that HTML alone can hide the server's IP, SNI, TLS fingerprint or traffic characteristics. Do not promise complete DPI invisibility.

## Current checkpoints and release status

| Checkpoint | Status | Notes |
| --- | --- | --- |
| v0.2.9 (`main`) | Published code baseline | Still the source shown on `main`; not the latest accepted development checkpoint |
| v0.2.10 Stage A | Development completed | DPI state/isolation model improvements |
| v0.2.11 Stage A.1 | Development checkpoint | Real nft and ENOSPC gates remain |
| v0.2.12 Stage B | Superseded by B.1 | Backend firewall and isolated test corrections |
| v0.2.13 Stage B.1 | Development checkpoint | Permission/test safety corrections; privileged gates outstanding |
| v0.2.14 Stage C1 | Superseded by C1.1/C1.2 | State, profile and port integrity |
| v0.2.15 Stage C1.1 | Superseded by C1.2 | Backend stop and orphan-repair corrections |
| v0.2.16 Stage C1.2 | Development accepted (model gates) | Backend identity/ownership fixed; lab gates remain |
| v0.2.17 Stage C2 | **Development accepted (model gates)** | Relay binary update, readiness checks, rollback and concurrency controls; separate checked ZIP, not yet uploaded as GitHub source branch |
| v0.2.18 Stage D | **Development accepted (model gates)** | Independent ZIP verification, Stage D 122/122 and C2 100/100; real Caddy/Nginx/systemd/ACME gates remain for RC; source still pending GitHub upload |
| v0.2.19 Stage E | **Development accepted (model gates)** | 48/48 independently repeated; TUI EOF/default-no, bounded probes, honest UNKNOWN/INCOMPLETE, redacted safe log bundles; pre-RC lab tests pending; source still pending GitHub branch publication |
| v0.2.20 Stage F | **Development accepted with backlog; 2 P1 failures** | Real Ubuntu integration: 24 REAL_HOST_PASS, 2 REAL_HOST_FAIL (health stdout and inherited curl lock), 4 MODEL_PASS, 3 NOT_EXECUTED; no confirmed P0; source ZIP/Git bundle verified, GitHub source branch still not published |
| v0.2.21 Stage G | **Codex ACCEPTED_WITH_BACKLOG (real Linux)** | RED Stage F 6 expected failures; Stage G oracle 18/18 PASS; real update/rollback/flock/SIGKILL/ENOSPC, Nginx & limited systemd PASS; 2 reproducible P1 in backlog, no confirmed P0; source ZIP/Git bundle not yet published to a branch |
| v0.2.22 Stage H | **DEVELOPMENT_ACCEPTED (model checks)** | Independent 98/98 Stage H UX PASS, 687/687 Git tree, RU/EN, guided setup and safer network-mode explanations; still untested real TLS/clients; GitHub source branch not yet published |
| Pre-RC integration | **NEXT — tests and two P1 fixes required** | Disposable real Linux, nft/systemd, Caddy/Nginx/ACME, genuine clients, source publication, signed artifact provenance and readiness criteria |

**Current activity: RC integration / pre-release validation.** Stage H has been independently accepted as a development checkpoint, not a production release. The previous Codex Stage G findings P1-G-01 and P1-INHERITED-01 remain open before RC.

All development checkpoints are **not authorized for production deployment**. The authoritative working files are versioned ZIPs, reports, SHA manifests and matching source commits/branches. Never infer that uploading documentation to `main` promotes newer code to a release.

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

## Immediate work: integrated pre-RC validation

**Stage H v0.2.22-beta DEVELOPMENT_ACCEPTED** after independently rerunning the Stage H suite: 98/98 model UX assertions, 0 failures, static heredoc guard PASS, RU/EN catalog PASS, exact Git source tree 687/687 and unchanged updater/protected function hashes. First-run/quick/advanced workflows, DNS refusal, cancel/EOF, site/TLS choices, client help, status hints, main-menu routing and Anti-DPI risk explanations are implemented.

**Scope is complete for A/B/C/D/E/F/G/H development, not yet proven for production.** Real Telegram clients and a production-like public HTTPS site have not been tested. Current quick setup can use a temporary placeholder, supplied static directory or local upstream; it does not implement a website builder.

**Confirmed P1 gates before production RC:**
- `P1-G-01`: offline restore may return `RESTORE_SUCCESS` / exit 0 despite failure to replace `global.env` version metadata.
- `P1-INHERITED-01`: stock MTProxy uses a `-S` secret in argv; local users may read `/proc/<pid>/cmdline` on permissive procfs.

**Development incident note:** During Stage H creation, unquoted heredoc help text containing backticks caused several noninteractive calls to the host's installed manager, leaving 18 log files. Host canary found no service/configuration changes. The final help text no longer executes commands and a static guard and dynamic sentinel tripwire check cover this.

**RC acceptance plan:** privileged disposable VM tests for nftables and systemd; genuine Caddy/Nginx with ACME and a public site over 80/443; end-to-end Telegram Desktop and mobile client connections; stock and targeted Anti-DPI behavior checks across controlled networks; trust bootstrap and an actually signed release; failure/recovery behavior and closure or explicitly approved mitigations of both P1. Record exact real vs model coverage, failures and NOT_EXECUTED truthfully. A failed test does not automatically require a new development stage unless it exposes a material blocker.

**GitHub source publication remains incomplete.** The verified history.bundle includes Stage D–H, but `main` remains v0.2.9 and no remote accepted source branches have been verified. Publish exact approved source commits to separate dev branches before release readiness; do not claim that README/roadmap changes published code, do not push to `main`, force-push or create a release.

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

## Public website / Decoy Site Manager — dedicated future stage

Bring the original product idea back: a real, maintainable HTTPS website on the same hostname as the WEB bridge rather than the current generic “Gateway / The service is online” page.

Candidate supported modes:
1. **Generated real site:** user-selected title, purpose, pages, content, assets, favicon, styling and basic accessibility; sensible template defaults, not an identical fingerprinted placeholder across hosts.
2. **Upload owned site:** HTML/CSS/JS/assets with path, ownership, symlink and content checks; publish transactionally.
3. **Use existing website:** explicit reverse proxy to user-managed `public_upstream` without disrupting routes or TLS.
4. **Authorized snapshot:** import only the operator's own website or content with permission; avoid deceptive copying of third-party branding.
5. **Redirect:** secondary/manual mode only; warn that it is not an equivalent public site and may impair bridge behavior.

Technical requirements: never expose relay secrets or local ports, validate/candidate-publish web configuration, keep a working site when edits fail, preserve user-managed files and Caddy/Nginx blocks, keep WEB transport paths compatible, and test base-path routing separately. The site's existence alone does not guarantee censorship resistance or transport indistinguishability.

UI: website creation and maintenance belong in quick setup and per-site management, with preview, certificate/status view, undo and clear failure messages.

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
