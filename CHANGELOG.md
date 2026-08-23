# Changelog

## 0.2.5 — 2026-08-23 — first E2E cleanup / isolation audit

- Зафиксирован первый реальный E2E PASS: Telegram Desktop native WEB -> Caddy/HTTPS -> tproxy-server -> official MTProxy.
- Fresh core install закреплён на E2E-проверенном `tproxy-server` commit `2873a08806d6e4d84830b9b5c4b0ec0f46af91f8`; переход на новый upstream `master` теперь происходит только через явный `twebproxy update`.
- В MTProxy systemd unit добавлен `AF_NETLINK`; исправляет наблюдавшийся `getifaddrs(): Address family not supported by protocol`.
- В runner stock MTProxy добавлен `--http-stats`, чтобы manager `stats`/`audit` работали с реальным HTTP `/stats`, а не только с зарезервированным локальным портом.
- Caddy block теперь форматируется отдельно до вставки; manager не форматирует целиком пользовательский Caddyfile.
- Caddy add/remove переведены на candidate/validate/backup/rollback flow.
- Добавлена команда `audit [hostname]` для проверки loopback relay/admin, backend services и nftables coverage.
- `add` и `repair` завершаются isolation audit.
- `repair` теперь обновляет runtime helper scripts и systemd templates текущей версии manager.
- `write_global_env` сохраняет известный `TPROXY_UPSTREAM_COMMIT`, если команда не выполняла новый upstream sync.
- Safe log sanitizer дополнительно скрывает MTProxy secret в process/status output вида `-S <secret>`.
- Current runtime report использует journal текущей активации unit вместо большого хвоста старых restart loops.
- Добавлен bounded history snapshot за 24 часа.
- Shareable bundle разделён на `current/` и `history/`; полная persistent history остаётся на сервере.
- В diagnostic bundle добавлен `MANIFEST.sha256`.
- README разделяет реально проверенный baseline и ещё не подтверждённые carrier/frontend комбинации.

## 0.2.4 — runtime permissions + repair

- Исправлен `permission denied` relay на root-only `/etc/twebproxy`: `config.json` и `profiles.json` передаются через `systemd LoadCredential`.
- Исправлен `status=126` MTProxy: runtime binary устанавливается в `/usr/local/libexec/twebproxy/mtproto-proxy` mode `0755`.
- `proxy-secret` и `proxy-multi.conf` передаются MTProxy через systemd credentials.
- Backend readiness проверяется до запуска relay.
- Добавлен `repair [hostname]`.
- Ограничен restart loop через `StartLimitIntervalSec/StartLimitBurst`.

## 0.2.3 — 2026-08-23

- Upstream Go tests/build больше не наследуют manager `umask 077`; локально используется `umask 022`.
- Исправлена коллизия `VERSION` с `/etc/os-release`: manager использует `MANAGER_VERSION`.
- Улучшены сообщения upstream test/build failures.

## 0.2.2 — 2026-08-22

- Добавлен `report` / FULL TEST REPORT.
- Добавлены full snapshots с systemd/network/DNS/TLS/config context.
- Root passwords, `/etc/shadow`, SSH/TLS private key bytes не собираются.
- Добавлен automatic failure snapshot.

## 0.2.1 — 2026-08-22

- Persistent manager transcripts в `/opt/twebproxy-manager/logs/`.
- `logs`, `logs-tail`, `logs-collect`, `logs-pack`.
- Safe redaction secrets.

## 0.2.0 — 2026-08-22

- Multi-host / multi-profile architecture.
- Caddy / Nginx LE / Nginx custom / Manual frontend.
- Four WEB carrier modes.
- Dynamic ports, nftables, systemd templates, daily MTProxy config refresh.
- Relay update candidate validation + rollback.
