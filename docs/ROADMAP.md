# TWebProxy Manager — Development Roadmap

Updated: 2026-10-31. Restored to the pre-Gemini release roadmap; nonessential architectural experiments are parked.

## Repository publication and evidence

**Stable-first decision:** preserve the existing Gate 3 topology and security invariants. No live-server experiments or route/backend rewrites are authorized by this document. Experimental topics are postponed to [roadmap-test.md](../roadmap-test.md).


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
| Smart Defaults / TUI | UNPUBLISHED v0.2.26-beta CANDIDATE | Safe defaults/presets implemented; focused confirmation/localization/ERR corrections; no live deployment |
| RC / stable Release | NOT AUTHORIZED | Platform/client matrix, cold boot, security, verified distribution |

Current tasks: finish focused CLI/TUI fixes, Smart Defaults and Gate 3 acceptance on the **existing** data path; then validate and publish a stable release. Defer structural changes to [roadmap-test.md](../roadmap-test.md). See [ARCHITECTURE.md](ARCHITECTURE.md) and [CLIENT-VALIDATION.md](bridge-gate3/CLIENT-VALIDATION.md).

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
- **Release-first freeze:** do not move MTProxy between Entry/Exit, change WireGuard paths, add policy routing/NAT, change backend/firewall/procfs/SSH trust model, add Multi-Profile or Multi-Exit, or replace transports before the first accepted stable release. Experimental designs: [roadmap-test.md](../roadmap-test.md).

## Immediate work: Bridge Gate 3, TUI and RC

Actual Bridge route: RU HTTPS front end → tproxy-server → loopback TCP forwarder → WireGuard → private stock MTProxy on Foreign Exit → Telegram DC. The website and one client link remain on RU Entry. The local single-VPS mode is retained.

Next: verify clean installs, two-host cold boot, safe recovery and removal, TLS/renewal, external backend exposure, supported clients including Desktop and non-tested OS/CPU combinations. Keep synthetic protocol evidence distinct from genuine application tests and operator reports.

Smart Defaults is implemented in the unpublished v0.2.26-beta candidate: input inventory, safe defaults/presets, Advanced mode and explicit security/destructive approvals. The focused correction pass fixes restore affirmatives, localization audit, CLI ERR handling and standalone test dependencies. Existing six DPI methods/defaults and the working network path are unchanged. Public Quick TLS, a new two-VPS deployment and application tests are not claimed for this candidate.

Do not conflate a GitHub development source commit with a stable signed Release or trusted automatic update. Prior accepted P1 corrections need a new reproducer before reopening.

## v0.2.26 bounded integration result

The corrected Smart Defaults candidate is integrated for review; it is not in
main or a stable Release. Actual isolated Linux validation reproduced open
PRERC-UPDATE-01: script-only self-update leaves the newly pinned Bridge bundle
absent. Complete-distribution repair recovers it but does not close the updater
compatibility blocker. No runtime/update redesign is introduced; merge/release
readiness is withheld. See [pre-RC evidence scope](PRERC-v0.2.26.md). The release-first
network/security freeze and deferred roadmap-test remain unchanged.

## Immediate low-risk corrections — no network architecture changes

Only focused work that preserves the existing RU Entry → loopback TCP forwarder → WireGuard → stock MTProxy on Foreign Exit path, as well as local single-VPS mode, may be implemented before stable release:

- Align explicit `yes`/`да` confirmation handling without changing safe default-no and EOF behavior.
- Fix user-facing RU/EN localization errors and require `tests/localization-static-audit.sh` PASS.
- Eliminate the reproduced `pop_var_context` CLI error-trap noise without changing real exit codes, structured outputs or the tested Bridge menu recovery.
- Make Bridge menu tests reproducible from a clean source checkout with isolated, verified dependencies or narrowly scoped test doubles; do not require global `pip install`.
- Correct misleading manager-update guidance, while retaining signing/key/SHA verification requirements.
- Complete authorized **TUI & Smart Defaults**: fewer unnecessary inputs, safe presets, preserved Advanced path, explicit SSH host-key verification, approval and STOCK/default-no behavior.
- Improve **read-only compatibility preflight** messages for Python ABI, active swap, systemd/BPF/procfs, DNS/TLS and occupied ports. Do not relax security, switch off swap, install new backend stacks or silently broaden OS support.
- Finish existing real-client, TLS, reboot, site preservation and backend-exposure acceptance on isolated approved hosts. Report PASS/FAIL/NOT_EXECUTED exactly.

**Acceptance:** bounded RED/GREEN regressions, no changed runtime topology, no lost profiles or settings, no changed firewall/routing/daemon policy, one complete tested source ZIP and SHA-256 manifests. Cosmetics do not block the release. An actual new safety/state regression requires reproduction before correction.

## Mandatory disposable Linux validation (before RC; prioritize after B.1)

Use a separate sacrificial Linux VM/host with an isolated firewall/network, root test privileges and controlled test filesystems. **Never use the live Telegram proxy VPS.**

- Actual nft kernel transactions: valid replacement, invalid candidate, deliberately failed batch, initial install, zero/one/multiple backends, foreign table invariance, restart/reload/uninstall behavior, postconditions.
- Actual systemd unit lifecycle: normal start/reload/restart/stop and dependency propagation; no unexpected service disruption during routine firewall rebuilds.
- Actual DPI verifier with nft JSON and rendered rules (F12); six existing modes and scope collisions.
- Actual ENOSPC interruption using an isolated filesystem or mount namespace; state preservation and truthful test result.
- Negative control: prove test runner refuses unsafe environments.

Record commands, pre/post states, exit codes and exact environment. An unavailable test is NOT_EXECUTED, not PASS. Real-kernel validation may run while later development proceeds in isolation, but it is a hard release gate.

## Historical core implementation stages (from the earlier B.1 plan)

| Stage | Scope | Acceptance principle |
| --- | --- | --- |
| **C1 — state and profiles** | Correct profile selection/clobbered globals, atomic profile/backend persistence, rotation races, local lifecycle locks, port allocation | No wrong target, lost secret, partial state or false success |
| **C2 — relay lifecycle** | Relay binary update, restart/health failure rollback, instance lifecycle failure propagation | Previous working binary/state retained on failure |
| **D — frontend / TLS** | Transactional Caddy managed markers, safe Nginx LE issuance/renewal, candidate validation, rollback | Existing website and TLS survive failed changes |
| **E — operations / diagnostics** | TUI EOF/default-no, read-only diagnostic timeouts, truthful status, logs/report handling | No false-green output, hangs or accidental yes |
| **F — updater / supply chain** | Explicitly authorized Stage 4 updater changes, lock cleanup, provenance/signatures or strong pinned artifact verification, rollback | Trusted, verifiable update with prior-version recovery |
| **G — hardening** | Privilege boundaries, config validation, ownership, bounded resources, remaining confirmed audit backlog | Safe defaults and predictable degradation |
| **H — user experience** | Main-menu Anti-DPI, guided quick setup, advanced controls, actionable statuses, RU/EN, desktop/mobile guidance | Novice usability without bypassing safety gates |

Historical stage IDs and acceptance criteria are retained as reference, not authorization to reopen completed stages. Only reproducible new blockers justify further changes before stable.

## Existing WEB transport and Anti-DPI acceptance

Validate **existing** `https`, `https-lanes`, `websocket`, `websocket-lanes` and the six shipped Anti-DPI modes without replacing their code or defaults. STOCK remains default and shared-IP consent remains mandatory. Run real Telegram Desktop/Android/iOS connection, media, sleep/reconnect and failure-path tests. Distinguish systemd/TLS/relay readiness from genuine client success; mark unexecuted cases NOT_EXECUTED.

New carrier/protocol experiments, alternate backends, `base_path`, CDN changes, nfqws2 and aggressive DPI redesign are archived in [roadmap-test.md](../roadmap-test.md) until after stable release and a separate authorization.

## Website: bundled default and future Site Manager

**Implemented:** `sites/podmoskovye/` provides the fixed default «Культурные маршруты Подмосковья»; Quick Setup uses it, and repair preserves edited deployed sites. Custom directories and loopback upstream sites remain available. [DEFAULT-SITE.md](bridge-gate3/DEFAULT-SITE.md).

**Before stable:** preserve the installed bundled site, custom sites and existing edits; only low-risk UI/docs corrections. New templates, upload/edit/generator and broader site lifecycle are deferred to [roadmap-test.md](../roadmap-test.md). HTML does not hide IP, SNI or TLS characteristics or guarantee DPI bypass.

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
