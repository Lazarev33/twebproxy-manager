# TWebProxy Manager — Development Roadmap

Updated: 2026-10-31. This document tracks **development checkpoints, active work and plans**, not production-release authorization.

## Repository publication and evidence status

- **GitHub `main` source remains v0.2.22-beta Stage H** as of this roadmap revision. Documentation updates do not publish later implementation code.
- **v0.2.24-beta** is an independently **ACCEPTED focused correction** for the two reproduced v0.2.23 P1 security defects (nftables/guard loss backend exposure; MTProxy argv/procfs protection on failure). Accepted *for this correction scope*, **not RC- or production-ready**. Exact handoff commit: `83e001ed49bfe210dc4d79aaccd15d72e406045d`. Its source is in verified handoff artifacts, not `main`.
- **Bridge Gate 1: CONDITIONAL GO.** A genuine two-disposable-VPS lab passed WireGuard/TCP transport, a 4 MiB integrity transfer, stock MTProxy protocol/authentication, a server-side Telegram DC response and recovery checks. **A genuine WEB-capable Telegram client has not yet been tested**; neither censorship resistance nor user-facing operation is established by synthetic probes.
- **Bridge Gate 2: IN PROGRESS with Codex.** Automated SSH provisioning and Manager integration are under implementation and real-host debugging. Observed individual deployment, repair and removal runs are *not* a final independent Gate 2 acceptance; wait for the final self-contained ZIP and evidence before declaring completion.
- Keep production/live VPS isolated. Work on explicitly authorized disposable systems; do not automatically merge, install, release, or replace the original single-VPS mode.

## Product goal

A dependable, easy-to-operate manager for Telegram native WEB Proxy: official `telegramdesktop/tproxy-server` + stock MTProxy, HTTPS/WebSocket transports, Caddy/Nginx, a real public website on the same hostname, optional carefully scoped anti-DPI methods, secure updates and meaningful diagnostics.

Two supported user journeys:
- **Quick setup:** domain → HTTPS → real website → WEB proxy → client connection information, with safe defaults.
- **Advanced administration:** instances, profiles, keys, carriers, backend isolation, diagnostics, certificates, optional anti-DPI and rollback.

Keep the public website genuinely functional; do not claim that HTML alone can hide the server's IP, SNI, TLS fingerprint or traffic characteristics. Do not promise complete DPI invisibility.

## Current checkpoints and release status

| Checkpoint | Status | Notes |
| --- | --- | --- |
| v0.2.9 | Historical published baseline | Superseded by published v0.2.22-beta Stage H |
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
| v0.2.22 Stage H | **DEVELOPMENT_ACCEPTED; published on `main`** | Independent 98/98 Stage H UX PASS; source on GitHub is development-only, not production-ready |
| v0.2.23 pre-RC | **REJECTED — superseded** | Focused independent testing reproduced two security P1 defects; do not use as accepted baseline |
| v0.2.24 pre-RC correction | **FOCUSED P1 ACCEPTED** | Independent disposable-Linux acceptance of both corrections; other release/client/platform checks remain pending; code not published to `main` |
| Bridge Gate 1 — network PoC | **CONDITIONAL GO** | Real two-VPS transport and MTProxy protocol proven; genuine Telegram WEB client NOT_EXECUTED |
| Bridge Gate 2 — automated provisioning | **IN PROGRESS** | Remote SSH setup, entry/exit orchestration, integration, repair/removal and failure tests underway; not accepted yet |
| Client-validation stage after Gate 2 | **PLANNED** | One RU-facing client link, real Telegram test, valid ACME TLS and small static RU website |
| Full RC integration | **PENDING** | Real clients, cross-platform, ACME/site, hardening, upgrade/rollback, provenance and release approval are separate gates |

**Current activity: Bridge Gate 2 automated provisioning, while full RC readiness remains pending.** The historical Stage G/Pre-RC defects must not be presented as still-open blockers after their focused v0.2.24 acceptance. The correction does not establish full release readiness.

Development handoffs and Bridge lab artifacts are **not authorized for production deployment**. The authoritative working files are versioned ZIPs, reports, SHA manifests and matching source commits/branches. Never infer that uploading documentation to `main` promotes newer code to a release.

## Non-negotiable engineering constraints

- **Delivery discipline:** accept only reproduced, stage-relevant P0/P1 as blockers. Put P2/P3 and unrelated improvements in a bounded backlog. Test the actual stage contract, not a new full-project audit after every fix.
- **Developer handoff:** each completed stage gets exactly one independently usable all-in-one ZIP with the complete changed sources, SHA256SUMS, evidence, environment identity, honest PASS/FAIL/NOT_EXECUTED and clear next gate. Prefer source and real reproducibility over formatting/polish.
- **Operator-facing design:** make complex backend networking a guided workflow; the end user should not manually configure WireGuard, proxying, firewall or systemd when using managed Bridge. Passwords, private SSH keys, tunnel keys and MTProxy secrets must not go into Git, stdout logs, public links or evidence archives.
- **Scope:** research and proof of concept may precede unrelated release tasks on isolated lab hosts. A focused security correction must be accepted before integrating with affected Manager paths, but unrelated RC checks do not automatically block a separate lab PoC.

- No production VPS changes during development, audits or fault injection.
- No resurrection of rejected advanced Stage 3 recovery, LKG, journal or generic exact-state engine. Use bounded, operation-local transactions and the simple backup-before-update / rollback-to-previous-version approach.
- Preserve stock MTProxy as the backend baseline; Caddy is the recommended greenfield frontend, Nginx remains supported for existing setups.
- The six existing DPI mode IDs and pinned nfqws binary remain stable until a separately approved change.
- Anti-DPI on local outgoing IPv4 TCP:443 may affect unrelated services on the same IP. STOCK default; explicit shared-scope consent; no automatic aggressive DPI changes.
- Keep protected Stage 4 functions unchanged until updater/supply-chain work is specifically authorized.
- Any production manager code change bumps machine-readable `VERSION`, `MANAGER_VERSION` and release label coherently; refresh SHA manifests and relevant fixtures.
- Every stage requires its own source checkpoint, targeted tests, error-path evidence and honest PASS / FAIL / NOT_EXECUTED reporting. No claim of kernel behavior from mocks alone.
- No unreviewed merge, push to `main`, automatic deployment or release from an engineering checkpoint.

## Immediate work: Bridge Gate 2 → controlled real-client trial → RC preparation

The core A/B/C/D/E/F/G/H history below remains historical. Current `main` publishes v0.2.22, whereas the independently accepted **v0.2.24 P1-corrected baseline** is a separate artifact. Do not promote a ZIP to GitHub `main` or a production release merely because its targeted checks pass.

**v0.2.24 focused closure:** prior independent v0.2.23 testing reproduced (1) backend-port exposure after loss of an nftables guard and (2) MTProxy `-S` secret exposure if procfs protection failed. The corrective implementation uses additional per-service systemd network restrictions and fail-closed procfs pre-start checks. Both received independent focused acceptance on real disposable Linux. Limitations and untested OS/real-client coverage remain documented for RC; do not reopen the same defects without a real reproducer.

**Bridge Gate 1 — completed, CONDITIONAL GO:** real two-host WireGuard/TCP forwarding, binary data integrity, MTProxy protocol/server response and recovery were demonstrated, distinct from earlier namespace simulations. The results do **not** include successful end-user Telegram client sessions or proof that Russian-network censorship can be bypassed.

**Bridge Gate 2 — current active engineering:** finish automated install and Manager `foreign-node` integration on the two authorized disposable VPSs. Verify SSH bootstrap and key handoff, foreign-only MTProxy binding, constrained `IPAddressAllow`, existing-site/profile preservation, AppArmor-compatible WireGuard credentials, accurate status, repair, uninstall, rollback and failure paths. The observed Ubuntu 26.04 `wg` AppArmor key-path issue was addressed during active development; await packaged evidence, regression tests and verdict before marking it accepted. Preserve the pre-existing local profile on failure and clean up only owned resources.

**Next, only after the Gate 2 ZIP has been reviewed:** run a **separate client-validation task** with the operator; publish a single public RU endpoint over correct DNS/ACME TLS, a real static informational landing page and a genuine supported Telegram WEB client link. Capture consented, sanitized diagnostics on both servers; prove connect, messaging, media, reconnect and failure cases. Do not substitute synthetic MTProxy probes for successful real-client use.

**Separate later gates:** finalize release-candidate validation on authorized disposable systems; test actual Telegram clients, TLS renewals, OS compatibility, upgrade/rollback and provenance. Publish an exact accepted source branch before any merge/release. No changes to the production VPS.

**Historical issue note:** the Stage H unquoted-heredoc incident and earlier Stage G findings motivated bounded safeguards; these are not grounds for indefinite repeat audits. An unavailable test is NOT_EXECUTED, not PASS.

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

## Optional RU-entry → foreign-exit Bridge — approved development track, not a released feature

**Product decision:** implement a managed **single-entry / one-foreign-exit** mode as an optional TWebProxy Manager feature. This is **not** a manual two-VPS recipe. The normal single-VPS install stays the default. Integration and deployment must retain all accepted v0.2.24 security invariants; the bridge is independent of the six DPI mode IDs. The proposed "post-RC only" research restriction has been superseded by the owner's authorization of isolated Bridge Gate 1 and Gate 2 development; this does not authorize RC or production rollout.

**One public client endpoint — no second foreign-client URL:**

```text
Telegram WEB-capable client
  -> ONE RU-facing hostname (lab: martins.ortositi.ru):443 HTTPS/WSS
  -> Caddy/Nginx, genuine static website on /, WEB proxy on compatible routes
  -> local official tproxy-server relay, loopback-only backend contract
  -> local TCP forwarder / socket proxy
  -> authenticated WireGuard tunnel
  -> foreign VPS stock MTProxy, private tunnel listener only
  -> Telegram DC
```

The end user sees only the RU hostname. The foreign VPS must not expose a public client-facing MTProxy or issue a second user proxy link. A separate foreign test hostname (lab proposal: `codex.ortositi.ru`) is **not required** for this design and may be used for authorized private diagnostics only, not as a second connection URL.

**One-click managed node user journey:**

1. Install TWebProxy Manager on the RU entry VPS and open its existing RU/EN menu.
2. Select **Foreign Nodes → Add Foreign Node**; enter foreign IP/hostname, SSH port, username and password **or** SSH-key authentication.
3. Independently verify/approve the remote SSH host key and show a non-destructive preflight plan: OS, privileges, service/port conflicts, existing profile/site and intended firewall changes.
4. On approval, bootstrap the minimum required restricted management access and provision both servers automatically: keys, WireGuard, bounded routes, scoped firewall/systemd controls, stock foreign MTProxy, entry forwarder and WEB profile.
5. Validate the complete path before switching traffic. Display one client connection link for the RU hostname, not instructions for manual WG/MTProxy setup.
6. Provide truthful node status, diagnostics, idempotent repair and safe removal/rollback. Preserve unrelated services, original local profiles, certificates and website, even on failure or repeated installation.

Prefer an **SSH/agentless management workflow** without a new publicly reachable management API. Never embed passwords in a prompt, URL, shell arguments, long-term config or ZIP; use constrained keys and revoke temporary lab credentials after testing. Scope the first MVP to one foreign node; leave multi-node balancing and remote fleet orchestration to a later optional stage.

**Security/compatibility requirements:**

- Preserve the relay's local backend requirement; do not expand it to arbitrary public IPs. Keep foreign backend tunnel-only and fail closed when tunnel, forwarding, peer or backend fails.
- Preserve nftables + systemd cgroup/IPAddressDeny protection. Add only explicit tunnel peer addresses to the allowed traffic; do **not** switch protections off to make Bridge work.
- Handle Ubuntu 26.04 WireGuard/AppArmor key path restrictions with protected `/etc/wireguard/` locations and restrictive permissions rather than disabling AppArmor; verify on each supported OS.
- Re-run provisioning safely, detect occupied ports and service conflicts, roll back partial changes and uninstall only owned services/users/routes/files. Do not delete remote management accounts from their own active sessions.
- Record precise evidence for the 4 MiB real-host transfer, MTProto/Telegram DC replies and failure/recovery; do not overgeneralize a lab MTU value (1280 worked where 1420 failed) as universal.
- A Russian-hosted IP alone does not prove accessibility under censorship. Check client→RU and RU→foreign paths independently and document limitations/cost/latency.

**Delivery gates (distinct, not one never-ending audit):**

| Gate | Objective | Current status |
| --- | --- | --- |
| **Gate 1 — Network PoC** | Two disposable VPSs, WG, binary TCP, stock MTProxy protocol, failure/recovery, real evidence | **CONDITIONAL GO**: server path proven; real Telegram WEB client NOT_EXECUTED |
| **Gate 2 — Auto Provisioning MVP** | Existing Manager TUI/CLI, SSH bootstrap, remote + local deployment, status, repair, rollback and removal | **IN PROGRESS**; judge only the final complete ZIP and targeted real-host tests |
| **Gate 3 — Real-client validation + site/TLS** | One RU public endpoint, valid cert, static website, compatible client link, real client messaging/media/reconnect logs | **PLANNED** after Gate 2 handoff review |
| **Later operational hardening** | Compatibility matrix, multiple optional foreign nodes if justified, updates/key rotation, broader RC tests | **BACKLOG**; not Gate 2 blockers absent reproduced impact |

**Gate 3 lab example (not deployed by this roadmap):**
- RU entry: `martins.ortositi.ru` — sole public TLS/WEB proxy hostname; existing lab RU test VPS.
- Foreign exit: existing authorized nonproduction test VPS; reachable through WireGuard, private backend only. `codex.ortositi.ru` is not a second client endpoint.
- ACME: verify RU DNS, ports 80/443, existing web-server conflicts and obtain a valid certificate using the **operator-supplied ACME contact address** in the private run-time configuration (do not commit personal addresses).
- Static website on `/`: **«Культурные маршруты Подмосковья»** — a substantive Russian-language informational landing page about Kolomna, Sergiev Posad, Zaraysk, architecture and crafts; accessible mobile-first design, licensed locally served assets, no trackers or false official affiliation.
- Preserve WEB transport routes and WebSocket Upgrade semantics next to the site. Do not invent a `wss://` or `tg://` link: derive **one real connection link** from the actually supported WEB-capable client protocol and live configuration.
- Operator runs a real Telegram session on their device. Collect timestamps, handshake and connection outcomes, message/media/reconnect timings and sanitized system logs from entry and exit; **never** log chat content, tokens, passwords, or private keys. Report PASS/FAIL/NOT_EXECUTED separately for supported clients.
- Do **not** begin Gate 3, ACME issuance, or website deployment until the owner supplies/reviews the Gate 2 report and explicitly starts the new task.

**Success principle:** a person installs Manager on the RU VPS, supplies foreign SSH details, approves the plan and gets a functioning RU-facing WEB proxy without manually assembling the tunnel. Verify actual client functionality and measurable network benefit before broader rollout; if there is no benefit, remain with the normal single-VPS mode.

## Public website / Decoy Site Manager — dedicated future stage

**Near-term, narrowly scoped Gate 3 deliverable:** deploy one real, maintainable static site **«Культурные маршруты Подмосковья»** on the RU lab hostname alongside WEB transport with valid HTTPS. This is not a license to expand Gate 2 or a requirement to implement the full site generator. ACME contact is supplied privately at deployment.

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
