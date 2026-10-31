# v0.2.26-beta — integration and bounded pre-RC

Unpublished development candidate integrated on a dedicated branch from
main4049dee7d0f9a0cc19da896d1ca9ccf4bb4abc9c. The accepted archive SHA256 is
c778aac536c1e5aae334880d6d795ef5681b3c6245fbc07585bfa72fa99cf733.
Its CRC, both manifests and workspace identity passed before integration.

Accepted runtime source/assets remain unchanged. Newer published setup/testing/
Bridge documentation is retained. Historical archive evidence is not restored
into Git; existing published evidence and the original worktree remain intact.

## Open release blocker: PRERC-UPDATE-01

On an actual isolated Ubuntu24.04 installation, published v0.2.25's unchanged
script-only updater installs the exact v0.2.26 script and reports UPDATE_SUCCESS.
Local profile status works, but installed `foreign-node status` returns1 because
the newly pinned Bridge bundle is absent. Only the old component directory exists.
Baseline Bridge status0 → update success → Bridge status1 was reproduced twice.

CLI rollback restores v0.2.25. Running `repair HOST` from the **complete verified
v0.2.26 distribution** installs its verified auxiliary bundle and restores
installed Bridge status; profile/secret/site/TLS configuration survives. This is
a recovery path, not closure of the automatic update defect.

The updater is deliberately unchanged. Authenticated auxiliary-component delivery
and rollback requires separately scoped distribution work; silently accepting a
mismatched bundle or downloading unverified code is unacceptable. Do not present
this integration as merge-ready or stable while this blocker remains open.

## Evidence and limits

The handoff ZIP contains current REPORT/RESULTS, an RC matrix, exact commit and
reproduction scripts/logs. Models, actual KVM guests, trusted loopback-TLS updater
fixtures and non-loopback veth probes are distinguished from real application tests.

The working path is unchanged: RU HTTPS frontend → tproxy-server → loopback TCP
forwarder → WireGuard → private stock MTProxy on Foreign Exit → Telegram DC.
Normal local mode, four carriers, six DPI methods/STOCK default, frontend, procfs/
cgroup-BPF/nft/systemd/SSH policies and simple rollback remain. No roadmap-test
experiment is implemented. No live Entry/Exit/production access, deployment,
main push, merge, Release or VPS reboot is authorized by this integration.

Public Quick/ACME, actual clients/carriers, real two-VPS upgrade/repair, other
platforms and cold boot remain separate RC gates. The earlier operator iOS13.1.2
report remains historical. [Test fixtures](../tests/prerc-v026/README.md).
