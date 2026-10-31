# TWebProxy Manager — roadmap-test (parked engineering ideas)

**Status: deferred until after the first accepted stable release. NOT AUTHORIZED for implementation or live deployment.**

This file preserves the Gemini/Argon-inspired ideas and our subsequent analysis without changing the current release plan. Main release plan: [docs/ROADMAP.md](docs/ROADMAP.md). Existing Gate 3 Bridge is the baseline, not an experiment to dismantle.

The owner must **explicitly authorize** any individual research gate after stable release. Until then: do not change the working RU Entry → WireGuard → Foreign Exit MTProxy path; do not interrupt Codex TUI Smart Defaults; do not use live Entry/Exit for experiments. No promise of a 2–5-second install, seamless failover, unlimited profiles or universal Linux support is established.

## High-risk ideas to revisit later

- **Lightweight Foreign Exit:** keep MTProxy and client secrets on RU Entry, send process-scoped outbound traffic to Telegram DC via WireGuard and restricted NAT on a foreign gateway. Must verify stock MTProxy NAT behavior, including `--nat-info` and real Middle-End connections, changing Exit IP, IPv6, IP routes, fail-closed packet capture, DNS and local service isolation.
- **Multi-Profile:** several independent secrets/profiles on one Bridge, with add/revoke/rotation, secret isolation, correct backend/service mapping and full rollback. Do not expand the existing one-profile implementation yet.
- **Multi-Exit / failover:** several foreign nodes, NAT and session state, health, routing, SSH trust, controlled switching and proof that established TCP streams can disconnect. Not a current production guarantee.
- **Broader OS/Python support:** test supported Debian/Ubuntu ABIs, offline dependencies, ARM64/containers separately; no blanket "any Linux" claim. Do not weaken no-swap, procfs, systemd IP filtering, cgroup-BPF or other mandatory protections without separate tests and a threat model.
- **Network runtime redesign:** dynamic foreign ports, MTProxy material refresh strategy, moving backend roles, WireGuard policy routing, new server implementations, transport variants, alternative Anti-DPI methods, CDN changes.
- **Site Manager:** multiple templates, generator, site upload and migration beyond the current bundled site; preserve operator modifications, avoid unsupported DPI camouflage claims.
- **Language/backend rewrite:** modularizing the Bash monolith or replacing it with Go/Zig, Docker-specific design, or a new micro-agent. Require a measured benefit and verified migration first.

## Archived proposals as written in the previous roadmap

The following design notes are preserved for context, **not as active priority numbers**:

### Priority 2: Lightweight Foreign Exit — independent architecture research and GO/NO-GO

**Status: RESEARCH ONLY, NOT APPROVED FOR IMPLEMENTATION.** Investigate the Gemini Argon proposal before extending the current one-profile Bridge. Do not change current Gate 3 servers, installed route, secrets, README architecture diagrams or code during this research.

**Proven current topology:** Telegram WEB client → RU HTTPS/Caddy/Nginx → `tproxy-server` → loopback `systemd-socket-proxyd` → WireGuard → stock MTProxy on Foreign Exit → Telegram DC. Gate 3 has an operator-reported real Telegram iOS test; do not discard that baseline.

**Candidate topology:** Telegram WEB client → RU HTTPS/Caddy/Nginx → `tproxy-server` → **local stock MTProxy on RU Entry** → narrowly marked outbound Telegram DC connections over WireGuard → **Foreign Exit with restricted NAT/routing, no MTProxy or client-secret storage** → Telegram DC. The client keeps exactly one RU-facing link. This is a technical hypothesis, not an established superior implementation.

**Concrete motivations confirmed in v0.2.25:**
- Foreign `bridge/agent.py` builds MTProxy from pinned source, provisions an SSH management user/sshd Match/sudo rule, requires procfs secret hardening and runs multiple owned services. A lighter Exit could reduce required packages and the blast radius of foreign-root access, but must retain secure management and rollback.
- `bridge/controller.py` currently fixes foreign WireGuard/client/stats ports at 51990/24990/29990. Existing preflight refuses collisions; automatic safe port allocation is a separate usability improvement, not a security failure.
- `bridge/agent.py` contains `forward(config)` without a discovered runtime caller; Entry actually uses `systemd-socket-proxyd`. Confirm dead-code status with tests before removal.
- Foreign official Telegram material refresh currently restarts MTProxy on successful update. Measure its real client-session impact before claiming all sessions always drop.
- Current Bridge requires one attached profile/node, x86_64 Python 3.12/3.14 launcher and only tested Ubuntu 24.04/26.04 on the agent. A new route topology might simplify restrictions but does not automatically support every distribution or unlimited profiles.

**Research a single preferred candidate:** stock WireGuard with **process-scoped policy routing** and constrained Exit NAT; do not simultaneously implement an unreviewed custom Go/mTLS/Noise transport.

**Required prototype and comparison on isolated disposable RU/Foreign VPSs:**
1. Independently verify MTProxy outbound packet behavior, Telegram DC address discovery/refresh, IPv4 **and IPv6**, connection types and DNS handling. A static subset of DC CIDRs is not proof of complete routing.
2. Model and test route ownership and isolation: nftables marks or cgroup/UID-bound rules, dedicated routing table, WireGuard allowed-ips, NAT/conntrack, firewall, systemd IPAddressDeny/Allow compatibility, local instances, SSH/front-end traffic and reverse-path behavior.
3. **Fail closed:** when WireGuard, Exit, route or DNS fails, the intended MTProxy egress must not escape directly via RU public IPv4/IPv6. Verify with actual packet captures, external probes and failure injection. No automatic fallback to direct egress without separately approved risk acceptance.
4. Demonstrate that the Exit does **not** store MTProxy client secrets, but keeps its own WG/private management credentials safely; independently verify SSH host identity, protect management permissions and evaluate system-wide NAT/sysctl side effects. The Exit is not truly stateless: conntrack/NAT has connection state.
5. Test **two distinct profiles through one candidate Exit**, preserving per-user secrets, exact links, isolation, metrics, revoke/rotate and rollback, with genuine Telegram application text/media/reconnect checks.
6. Compare against the **existing Gate 3 Bridge**, on similar real hosts: install/repair/removal time, dependencies/builds, CPU/RAM, throughput, latency, service count, MTProxy material refresh, session interruption, cold boot, recovery and partial cleanup.
7. Treat **2–5 second installation**, **80% less code**, **zero dependencies**, **any Linux**, **1-second failover** and **seamless migration of TCP connections** as unverified competitor claims, not targets already met. Changing Exit IP or NAT state normally interrupts established TCP; measure actual client recovery.
8. Produce a reversible migration design for existing Bridge owners: preserve hostname, website/TLS, profiles/secrets, existing local backend, old Exit state, firewall/route rules, interrupted operations and cleanup debt. **Do not migrate live Gate 3 Entry/Exit during the experiment.**

**GO:** real application traffic and multiple profiles work, no direct-route leaks, security boundaries meet or exceed baseline, operation is measurably simpler, repairs and rollback are reliable. **NO-GO:** retain remote MTProxy Bridge and fix selected problems such as fixed ports, refresh restart and profile support. **CONDITIONAL:** list precise blockers and remaining tests, do not deploy. Deliver actual PASS/FAIL/NOT_EXECUTED evidence, topology comparison, one self-contained handoff ZIP and a documented security/operational decision. The owner must separately authorize implementation after the research verdict.

### Priority 3: Bridge compatibility and Multi-Profile — after architecture decision

**Hard dependency: finish Priority 2 first.** Develop multiple profiles and broader OS support for **the selected topology**, not for both indefinitely. No Bridge rewrite follows automatically from an interesting design.



**Architecture decision first; compatibility support depends on it.** The **current** Bridge launcher admits only x86_64 Python 3.12/3.14, and its agent only Ubuntu 24.04/26.04. The core/local Manager has a different support matrix. If remote MTProxy remains the chosen design, extend and test its dependencies. If the lightweight Exit is accepted, validate the new controller/agent and OS support from scratch. Neither choice implies unrestricted Debian, Alpine, ARM or container support.

- For the **retained remote-MTProxy topology**, add/test complete offline dependencies for Python 3.10 (Ubuntu 22.04) and 3.11 (Debian 12) where feasible; a single `cffi` wheel is not enough. For an **accepted lightweight-Exit topology**, measure its actual bootstrap/runtime dependencies and test an independent matrix. ARM64 and container/Alpine support are separate optional gates.
- Review the **active-swap refusal** as a documented security tradeoff, not an arbitrary crash. Keep fail-closed handling until a tested threat model supports an alternative. `mlock` applied to one Python buffer is not proof every copy of a password/key is swap-safe; never disable user swap automatically.
- Preserve effective systemd per-unit IP filtering, nftables isolation and procfs protection. Unsupported LXC/OpenVZ or kernels without effective enforcement remain explicit limitations unless equivalent safety is demonstrated and independently tested.
- Support **at least two independent profiles on one bridged instance and one foreign Exit** in the **selected topology**, including separate secrets, link generation, add/rotate/revoke, backend routing, status, repair, rollback and removal. If lightweight Exit is chosen, MTProxy/secrets stay on RU Entry and only eligible egress is routed through Exit; if existing Bridge is retained, design the required protected remote profile-to-backend mappings. Preserve other local instances and safe recovery.
- **Do not add a second foreign node in this milestone.** One Exit with multiple profiles and Multi-Exit failover are different product changes.

**Acceptance:** supported OS/Python matrix with real results (PASS/FAIL/NOT_EXECUTED), safe rejection of unsupported hosts before any mutation, two-or-more-profile tests, isolation checks, simulated failure and remote cleanup, no lost credentials or accidentally public backend port. Document any unsupported versions rather than implying universal Debian/Ubuntu compatibility.

### Priority 4: a small site catalogue (without DPI folklore)

Keep `sites/podmoskovye/` as the existing default and `placeholder` compatibility for older instances. Add several substantial, user-selectable static websites with previews and deterministic integrity manifests. Preserve existing operator site edits during repair/upgrade and support custom static directories/loopback applications.

Distinct pages may avoid identical **content under active inspection**, but passive observers cannot ordinarily read HTTPS HTML/CSS as plaintext; changing markup is **not** a proven way to hide public IP, SNI or TLS fingerprints. Do not claim camouflage, guaranteed censorship bypass, or automatically generated uniqueness without measurements.

**Acceptance:** a bounded site library with verified assets/licensing, no runtime analytics/CDN dependencies by default, mobile usability, integrity and safe-path checks, repairs that preserve custom content, deterministic tests for legacy `placeholder`, existing sites and explicit deletion. A full website generator/editor is separate optional work.

### Later research gate: Multi-Exit, failover, modularity and packaging (after single-Exit topology decision)

Compare two or more foreign Exit nodes **only after the selected single-Exit architecture and multi-profile lifecycle are proven**. Use [mtproto.zig](https://github.com/sleep3r/mtproto.zig) as a research reference, not a drop-in design. Examine route/conntrack ownership, per-Exit trust, health beyond WireGuard handshakes, different foreign source IPs, failover flapping, inevitable TCP interruptions, fail-closed leak prevention, cleanup and rollback. No seamless failover claims without actual client evidence.

Separately evaluate signed/prebuilt artifacts, smaller dependencies and modular Bash/Python boundaries. The current 10k+ line Bash manager imposes maintenance cost, but **a full Go/Zig rewrite, new backend, Docker or container support is not authorized by this comparison**. Require a measured benefit and a migration path retaining CLI/state/security invariants.

**Deliver research first:** comparable alternatives, threat model, measurable performance, disposable-host PoC, failure injection, client reconnection evidence and explicit GO/NO-GO. Do not automatically enable Multi-Exit or describe it as delivered.



## Previously proposed WEB transport and Anti-DPI research

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



## Conditions for possible later work

Only after stable release and new authorization: frozen baseline, disposable isolated test hosts, reproducible before/after measurements, real Telegram client tests, kernel/network capture, fail-closed leak checks, restore/rollback, honest PASS/FAIL/NOT_EXECUTED and one self-contained evidence ZIP with SHA-256. A passing research POC does not authorize deployment.
