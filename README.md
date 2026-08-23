# TWebProxy Manager

`TWebProxy Manager` — интерактивный installer/manager для self-hosted Telegram **WEB Proxy** на Linux. Репозиторий использует официальный `telegramdesktop/tproxy-server` как WEB relay и официальный `TelegramMessenger/MTProxy` как backend.

Рекомендуемое имя GitHub-репозитория: **`twebproxy-manager`**.

Короткое описание для GitHub:

> Self-hosted Telegram WEB Proxy installer and manager with systemd isolation, TLS frontends, multi-profile support, diagnostics and rollback.

Текущая версия: **0.2.5**. Статус: **beta / first E2E baseline validated**.

Для воспроизводимости fresh install не тянет произвольный сегодняшний `master`: relay закреплён на commit `2873a08806d6e4d84830b9b5c4b0ec0f46af91f8`, который использовался в первом успешном полевом E2E. Обновление на более свежий upstream выполняется отдельно через `twebproxy update`.

## Проверенный baseline

На реальном Ubuntu 24.04 VPS подтверждена цепочка:

```text
Telegram Desktop
    -> native WEB proxy
    -> HTTPS/443
    -> Caddy
    -> tproxy-server on loopback
    -> official MTProxy backend
    -> Telegram
```

Проверенная комбинация на момент выпуска этого архива:

```text
Frontend: Caddy
Carrier:  https
Backend:  official MTProxy
Client:   Telegram Desktop native WEB proxy
Result:   CONNECTED
```

`https-lanes`, `websocket`, `websocket-lanes` и managed Nginx остаются в матрице последующих E2E-тестов; наличие этих режимов в manager не означает, что все они уже прошли одинаковый полевой прогон.

## Что изменено в 0.2.5

0.2.5 — cleanup/hardening release после первого успешного E2E:

- MTProxy systemd sandbox теперь разрешает `AF_NETLINK` вместе с `AF_INET/AF_INET6`. Это устраняет наблюдавшийся на Ubuntu 24.04 `getifaddrs(): Address family not supported by protocol` без ослабления остальной модели запуска.
- stock MTProxy запускается с `--http-stats`, поэтому выделенный stats port действительно отдаёт HTTP `/stats`; раньше manager резервировал/проверял stats port, но не включал HTTP exporter.
- Caddy block форматируется **отдельно до вставки**. Manager не запускает `caddy fmt` над всем пользовательским Caddyfile и поэтому не переписывает чужие блоки ради косметики.
- изменение managed Caddyfile стало transactional: candidate сначала проходит `caddy validate`; при неуспешном reload manager возвращает предыдущий файл.
- добавлена команда `twebproxy audit [hostname]`;
- audit проверяет loopback binding relay/admin, состояние backend/firewall, наличие backend/stats ports в nftables и доступность локальной статистики;
- `add` и `repair` теперь завершаются обязательным isolation audit;
- `repair` регенерирует helper scripts и systemd templates текущей версии manager, поэтому подходит для применения runtime-fix после замены manager script;
- FULL/safe report разделён на **current state** и ограниченную **history**, вместо бесконтрольного копирования всей накопленной истории;
- current journals ограничиваются текущей активацией systemd unit;
- history содержит ограниченный 24-часовой контекст и последние manager/runtime snapshots;
- bundle получает `MANIFEST.sha256`;
- safe redaction дополнительно скрывает MTProxy secret, если он попал в вывод процесса как аргумент `-S <secret>`;
- при перезаписи `global.env` сохраняется известный upstream commit, если текущая команда не выполняла новый `git fetch`.

## Архитектура

```text
                         Internet
                            |
                         TCP/443
                            |
                   +----------------+
                   | Caddy / Nginx  |
                   +----------------+
                            |
                   127.0.0.1:relay
                            |
                   +----------------+
                   | tproxy-server  |
                   +----------------+
                      |          |
                profile A    profile B
                      |          |
               127.0.0.1  127.0.0.1
                      |          |
                  MTProxy     MTProxy
                      \          /
                         Telegram
```

Один hostname имеет отдельный `tproxy-server` process. Один hostname может иметь несколько profiles/secrets. На текущем backend implementation каждому profile соответствует отдельный stock MTProxy service.

Подробности: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Политика фиксации upstream и воспроизводимости: [`docs/UPSTREAM.md`](docs/UPSTREAM.md).

## Возможности

- multi-hostname;
- multi-profile / multi-secret;
- carriers `https`, `https-lanes`, `websocket`, `websocket-lanes`;
- автоматический или ручной выбор внутренних портов;
- Caddy с automatic TLS;
- Nginx + Let's Encrypt;
- Nginx + пользовательский certificate/key;
- Manual frontend для существующего Caddy/Nginx/Remnawave/3x-ui окружения;
- systemd template services;
- `LoadCredential` для relay config/profiles и MTProxy routing material;
- nftables isolation backend/stats ports;
- daily refresh Telegram `proxy-multi.conf`;
- fresh install закреплён на реально E2E-проверенном `tproxy-server` commit `2873a08806d6e4d84830b9b5c4b0ec0f46af91f8`;
- `twebproxy update` — отдельный явный opt-in на свежий upstream `master`, с Go tests, config-check, health-check и binary rollback;
- persistent installer/manager transcripts;
- failure snapshots;
- safe report и FULL TEST REPORT;
- `status`, `stats`, `diagnose`, `audit`, `repair`;
- HTTP stats stock MTProxy включён явно через `--http-stats` и остаётся закрыт manager-owned nftables от внешнего доступа;
- secret rotation и carrier switching.

## Требования

Поддерживаемая цель текущей ветки:

- Debian 12+ или Ubuntu 22.04+;
- x86_64;
- systemd;
- root/sudo;
- публичный IPv4;
- для managed TLS: доступные снаружи TCP 80/443.

Для чистого первого теста рекомендуется сначала использовать только `A` record. `AAAA` имеет смысл добавлять после отдельной проверки публичного IPv6.

## DNS

Пример:

```text
A  webproxy.example.com  -> 203.0.113.10
```

В manager вводится только:

```text
webproxy.example.com
```

Без `https://`, без `:443`, без path.

## Установка

```bash
chmod +x twebproxy-manager.sh
sudo ./twebproxy-manager.sh
```

После установки manager копируется в:

```text
/usr/local/sbin/twebproxy
```

и дальше запускается:

```bash
sudo twebproxy
```

CLI-вариант:

```bash
sudo ./twebproxy-manager.sh core-install
sudo twebproxy add
```

## Обновление с 0.2.4 до 0.2.5

Для уже работающего тестового hostname не требуется сносить сервер или пересоздавать secret.

1. Загрузи новый `twebproxy-manager.sh`.
2. Сделай его executable.
3. Запусти `repair` нужного hostname новым скриптом:

```bash
chmod +x twebproxy-manager.sh
sudo ./twebproxy-manager.sh repair webproxy.example.com
```

`repair` в 0.2.5 регенерирует helper scripts/systemd templates, пересобирает generated config, перезапускает backend/relay, применяет frontend и выполняет isolation audit. После успешного `repair` новая версия также устанавливается как `/usr/local/sbin/twebproxy`.

## CLI

```text
twebproxy core-install
twebproxy update
twebproxy core-uninstall

twebproxy add
twebproxy list
twebproxy show [hostname]
twebproxy manual-snippet [hostname]
twebproxy restart [hostname]
twebproxy repair [hostname]
twebproxy status [hostname]
twebproxy stats [hostname]
twebproxy diagnose [hostname]
twebproxy audit [hostname]
twebproxy delete [hostname]

twebproxy profile-list [hostname]
twebproxy profile-add [hostname]
twebproxy profile-show [hostname] [profile]
twebproxy profile-rotate [hostname] [profile]
twebproxy profile-carrier [hostname] [profile]
twebproxy profile-delete [hostname] [profile]

twebproxy logs
twebproxy logs-tail [lines]
twebproxy logs-collect [--full]
twebproxy logs-pack [--full]
twebproxy report

twebproxy menu
```

## `audit`

```bash
sudo twebproxy audit webproxy.example.com
```

Проверяет структурную изоляцию процесса:

- relay service active;
- relay/admin действительно слушают loopback;
- backend services active;
- manager-owned nftables table active;
- каждый backend/stats port присутствует в nftables rule;
- MTProxy stats отвечает через loopback;
- managed HTTPS доступен с VPS.

Важно: это **не внешний port-scan**. Stock MTProxy может создавать wildcard listener для `-H/-p`; manager поэтому рассматривает nftables как обязательную security boundary. Для окончательной проверки внешней экспозиции используй внешний host или security scanner.

Официальный MTProxy CLI документирует `-H` как client port и `-p` как stats/local port, но отдельный bind-host параметр в базовом documented launch path отсутствует. Поэтому 0.2.5 не внедряет недокументированный bind workaround, а проверяет и поддерживает firewall isolation.

## TLS frontends

### Caddy

Manager добавляет только собственный отмеченный block:

```text
# BEGIN TWEBPROXY host
...
# END TWEBPROXY host
```

В 0.2.5 этот block форматируется во временном файле перед вставкой. Существующий пользовательский Caddyfile целиком не реформатируется.

### Nginx + Let's Encrypt

Manager создаёт отдельный vhost и получает сертификат через `certbot --webroot`.

### Manual

Используй, если 443 уже принадлежит существующему frontend:

```bash
sudo twebproxy manual-snippet webproxy.example.com
```

Весь hostname должен проксироваться на relay. Не выноси отдельный `/ws` или static location мимо `tproxy-server`.

## Логи

Постоянные логи остаются на сервере:

```text
/opt/twebproxy-manager/logs/
├── manager/
├── runtime/
├── full/
└── bundles/
```

Manager transcript начинается до install/build, поэтому ранний `apt`, `git`, `go test`, `go build` или systemd failure остаётся в журнале.

### Safe bundle

```bash
sudo twebproxy logs-pack
```

Secrets редактируются. В 0.2.5 sanitizer также закрывает `-S <32hex>`, который может появляться в process/status output stock MTProxy.

### FULL TEST REPORT

```bash
sudo twebproxy report
```

FULL report предназначен для тестовых VPS и может содержать WEB/MTProxy secrets. Root/sudo password, `/etc/shadow`, SSH private keys и содержимое TLS private key намеренно не собираются.

Новая структура bundle:

```text
current/
├── runtime.log
└── manager.log
history/
├── service-history.log
├── manager/       # последние transcripts
├── runtime/       # последние safe snapshots
└── full/          # только FULL mode, ограниченное число старых full snapshots
REPORT-META.txt
SECURITY-NOTICE.txt
MANIFEST.sha256
```

Полная persistent history остаётся в `/opt/twebproxy-manager/logs`; shareable archive больше не тащит её бесконечно целиком.

## Security model

Ключевые решения:

- manager state/secrets: root-only;
- service accounts не получают traversal по `/etc/twebproxy`;
- нужные файлы передаются через systemd credentials;
- relay доступен frontend только через loopback;
- relay process сам разрешён только к localhost backend через systemd IP sandbox;
- MTProxy backend/stats ports защищаются manager-owned nftables chain;
- access logs managed Caddy/Nginx выключены;
- private key bytes не добавляются в diagnostic bundle.

Подробнее: [`docs/SECURITY.md`](docs/SECURITY.md).

## Тестирование

После каждого изменения carrier/frontend/backend меняй **один фактор за раз**.

Рекомендуемая матрица:

```text
[ ] text messages
[ ] photo
[ ] voice
[ ] video
[ ] 100–500 MB file
[ ] Telegram restart
[ ] network reconnect
[ ] relay restart
[ ] backend restart
[ ] VPS reboot/autostart
[ ] https
[ ] https-lanes
[ ] websocket
[ ] websocket-lanes
[ ] Caddy
[ ] Nginx LE
```

Перед отправкой отчёта:

```bash
sudo twebproxy audit webproxy.example.com
sudo twebproxy report
```

Подробнее: [`docs/TESTING.md`](docs/TESTING.md).

## Upstream / scope

- `telegramdesktop/tproxy-server` остаётся upstream WEB relay;
- `TelegramMessenger/MTProxy` остаётся baseline backend;
- Telemt рассматривается как отдельный будущий backend experiment, но **не включён в 0.2.5**, чтобы не менять одновременно WEB transport и backend;
- MEKO-style fixes для direct public MTProto не включаются автоматически в WEB path: сначала должна быть доказана необходимость на соответствующем сетевом слое.

## Лицензия

В этот тестовый архив отдельная лицензия проекта намеренно не добавлена. Перед публичной публикацией репозитория нужно выбрать лицензию для manager-кода и отдельно проверить требования лицензий upstream-компонентов, которые manager скачивает/собирает.
