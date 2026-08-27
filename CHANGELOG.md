# Changelog

## 0.2.8-dpi-beta — 2026-08-25 — optional IPv4 network compatibility

- Добавлена единая необязательная DPI-подсистема с режимами `stock`,
  `window1152`, `mss88`, `nfqws`, `window1152_nfqws` и `mss88_nfqws`.
- `STOCK` остаётся режимом по умолчанию: до явного включения нет DPI-правил,
  бинарника, службы или дополнительного процесса.
- Window 1152 и MSS 88 ограничены точным исходящим IPv4 SYN+ACK с TCP/443;
  `nfqws` получает только первые ответные пакеты того же адресного scope.
- Состояние хранится на один фактический IPv4. Общий адрес требует явного
  подтверждения; IPv6 и carrier-конфигурация не меняются.
- Добавлены транзакционные set/switch/disable, проверка nft candidate,
  exact-state rollback и fail-closed возврат в STOCK при неудачном rollback.
- `nfqws v72.13` закреплён на commit
  `87e058624c72863db53bdaf7fb6f16576dddb6ab`; bundled binary и установленная
  копия проверяются по SHA-256.
- Исправлен lifecycle nfqws после normal install и script-only manager-update:
  при отсутствии соседнего release asset официальный архив закреплённого
  `v72.13` загружается по HTTPS, нужный x86_64 member проверяется по точному
  размеру/SHA-256 до исполнения, затем по version/commit и exact `--dry-run`.
- `STOCK` по-прежнему не хранит nfqws-артефакты; verified runtime появляется
  только при opt-in и удаляется при возврате в `stock`.
- Повреждённая установленная копия `nfqws` больше не блокирует восстановление:
  возврат в `STOCK` и полное удаление убирают только два фиксированных файла
  TWebProxy, не исполняя их и не затрагивая сторонние установки; повторное
  включение заново получает и проверяет закреплённый бинарник.
- Release metadata разделены без изменения Stage 4 parser: файл `VERSION`
  содержит строгий semver `0.2.8`, отображаемая beta-метка остаётся в
  `MANAGER_RELEASE_VERSION=0.2.8-dpi-beta` и имени архива.
- Добавлены EN/RU TUI/CLI, compact status/dashboard, audit, repair, delete,
  uninstall и safe/full report integration без изменения Stage 4.
- Добавлена обязательная failure-injection матрица для всех режимов, shared IP,
  отсутствующих/повреждённых компонентов, падения процесса и очистки STOCK.
- Добавлен relocation/install fixture без `TWEBPROXY_DPI_NFQWS_SOURCE`, который
  после удаления исходного release-tree включает `nfqws`, `window1152_nfqws`
  и `mss88_nfqws`, а также доказывает запрет исполнения повреждённой загрузки.

## Unreleased — Stage X-FixUI review candidate

- Добавлен единый встроенный EN/RU-каталог для интерактивной presentation layer.
- Первая интерактивная установка предлагает один выбор языка; настройка
  сохраняется в `/etc/twebproxy/ui-language`, а существующие и неинтерактивные
  сценарии безопасно используют русский fallback без prompt.
- Главное TUI сокращено до шести групп задач с единообразными `[0] Назад/Выход`.
- `status` и `stats` по умолчанию стали компактными; полный прежний вывод доступен
  через явный `--verbose` и раздел диагностики.
- Dashboard показывает версию, язык, общий health и краткий список инстансов,
  корректно переносит строки в узком терминале и учитывает `NO_COLOR`.
- CLI-команды, JSON/raw schema, networking/runtime и принятая Stage 4
  backup/update/rollback архитектура не изменены.

## 0.2.7 — 2026-08-23 — certificate lifecycle / automatic renewal

- Для `nginx-le` manager включает автоматическое продление через distro `certbot.timer`; если он недоступен, создаётся fallback `twebproxy-cert-renew.timer`.
- Добавлен deploy-hook Certbot: после успешного renewal выполняется `nginx -t` и graceful `systemctl reload nginx`.
- Initial Nginx LE issuance теперь задаёт явный `--cert-name <hostname>`, чтобы manager однозначно работал с `/etc/letsencrypt/live/<hostname>`.
- Добавлена команда `cert-status [hostname]`: срок действия, issuer/subject/serial, auto-renew source, strict HTTPS и local/public match.
- Добавлена команда `cert-renew [hostname] [--dry-run|--force]`. По умолчанию Certbot продлевает только если сертификат уже близок к expiry; `--dry-run` проверяет renewal через staging, `--force` требует явного действия.
- `status` показывает краткий TLS/certificate status.
- TUI получил отдельный раздел сертификатов.
- `audit` проверяет срок публичного сертификата: <30d info, <15d warning, <7d critical/fail, expired fail.
- Для `nginx-le` audit требует активный auto-renew timer и совпадение local/public SHA-256 fingerprint.
- Для `nginx-custom` audit проверяет local/public fingerprint, но не пытается автоматически перевыпускать пользовательский сертификат.
- Для Caddy manager не создаёт второй renewer: используется встроенный automatic TLS Caddy, audit контролирует публичный cert и состояние сервиса.
- FULL report дополнен certificate status.
- README обновлён кратким списком изменений по версиям согласно release policy проекта.

## 0.2.6 — 2026-08-23 — GitHub updates / stricter audit

- Добавлена проверка обновлений самого TWebProxy Manager из `Lazarev33/twebproxy-manager`.
- Добавлены команды `check-update` и `manager-update [--force]`.
- Проверка версии предпочитает latest stable GitHub Release и использует `VERSION` из репозитория как fallback.
- `manager-update` требует `SHA256SUMS`, проверяет SHA-256, `bash -n`, встроенную `MANAGER_VERSION` и self-smoke перед установкой.
- Предыдущая копия manager сохраняется в `/opt/twebproxy-manager/twebproxy-manager.previous.sh`.
- В TUI добавлена ненавязчивая проверка новой версии с кешем; недоступность GitHub не блокирует управление proxy.
- `audit` теперь анализирует все listener sockets на порту, а не только первую строку `ss`; это исключает ложное `loopback only` при нескольких worker sockets.
- Для managed frontend `audit` выполняет строгую HTTPS/TLS-проверку без `-k`; ошибка DNS/certificate chain/hostname/frontend считается critical failure.
- FULL report теперь отдельно пишет strict TLS PASS/FAIL и затем debug handshake с отключённой verification.
- В report metadata добавлен URL репозитория manager.
- README сокращён до описания проекта, установки и основных команд.
- Reboot/autostart baseline для `Caddy + https + stock MTProxy` подтверждён полевым тестом.

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
