# Upstream policy

TWebProxy Manager is an orchestration layer. It does not reimplement Telegram WEB Proxy or MTProto.

## WEB relay

Upstream:

```text
https://github.com/telegramdesktop/tproxy-server
```

The first successful field E2E on 2026-08-23 used:

```text
2873a08806d6e4d84830b9b5c4b0ec0f46af91f8
```

Fresh `core-install` in release 0.2.6 checks out exactly this commit before running the upstream Go test suite and building the relay. This prevents a release archive from silently changing behaviour because upstream `master` moved after the release was tested.

`twebproxy update` is intentionally different: it fetches the current upstream `master`, runs upstream tests, builds a candidate, checks every local instance configuration, swaps the binary, then performs health checks. If the candidate fails the runtime health gate, the previous binary is restored.

## MTProxy backend

Upstream:

```text
https://github.com/TelegramMessenger/MTProxy
```

Pinned commit:

```text
f36d8af769ffaeac36978d38c2c0f6d1104c2137
```

The manager builds the backend from source, installs a separate runtime binary, and starts it through a hardened systemd template. HTTP statistics are explicitly enabled with `--http-stats`; backend and stats ports are protected by the manager-owned nftables boundary.

## Recorded provenance

Installed state records the manager version, WEB relay commit, and MTProxy commit in:

```text
/etc/twebproxy/global.env
```

Diagnostic reports copy this provenance into `REPORT-META.txt`, so a field report can be tied back to exact component revisions.

## Upgrade rule

Do not mix an upstream update with an unrelated backend/carrier/frontend migration when debugging a regression. Change one layer at a time and collect a report after each change.
## Manager release source

Manager updates are checked against:

```text
https://github.com/Lazarev33/twebproxy-manager
```

`check-update` prefers the latest stable GitHub Release and falls back to the repository `VERSION` file. `manager-update` requires a matching `SHA256SUMS` entry for `twebproxy-manager.sh` before replacing the installed manager.

