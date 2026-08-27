# TWebProxy Manager

**TWebProxy Manager** — installer и manager для self-hosted Telegram **WEB Proxy** на Debian/Ubuntu.

Репозиторий: https://github.com/Lazarev33/twebproxy-manager

Текущий выпуск: **0.2.8-dpi-beta**. Машиночитаемый `VERSION` — **0.2.8**:
это строгий semver, совместимый с уже принятой Stage 4 update/rollback-проверкой;
beta-метка хранится отдельно в `MANAGER_RELEASE_VERSION` и используется в UI.

## Архитектура

```text
Telegram Desktop
    ↓ HTTPS / WSS :443
Caddy / Nginx
    ↓ loopback
tproxy-server
    ↓
MTProxy
    ↓
Telegram
```

WEB relay — официальный `telegramdesktop/tproxy-server`.  
Backend — официальный `TelegramMessenger/MTProxy`.

## Возможности

- несколько hostname на одном VPS;
- несколько profiles / secrets;
- carriers: `https`, `https-lanes`, `websocket`, `websocket-lanes`;
- Caddy + automatic TLS;
- Nginx + Let's Encrypt с автоматическим продлением;
- Nginx + custom certificate;
- manual frontend для существующего Caddy/Nginx;
- проверка срока действия и состояния TLS-сертификатов;
- systemd services и autostart;
- systemd credentials для конфигурации и секретов;
- nftables isolation backend-портов;
- диагностика, audit, repair и diagnostic reports;
- безопасное обновление `tproxy-server` с test/build/health-check/rollback;
- проверка и обновление самого TWebProxy Manager через GitHub.
- дополнительный IPv4-режим совместимости сети; по умолчанию остаётся `STOCK`.

## Требования

- Debian 12+ или Ubuntu 22.04+;
- x86_64;
- systemd;
- root/sudo;
- публичный IPv4;
- hostname с `A`-записью на VPS;
- TCP 443;
- TCP 80 для автоматического выпуска/продления Let's Encrypt.

## Установка

```bash
chmod +x twebproxy-manager.sh
sudo ./twebproxy-manager.sh
```

После установки:

```bash
sudo twebproxy
```

### Язык и новое меню

При первой интерактивной установке Manager один раз предлагает выбрать
`English` или `Русский` и сохраняет выбор в `/etc/twebproxy/ui-language`.
Существующие установки без этого файла продолжают работать на русском: команды
обновления, repair и любой неинтерактивный запуск не получают нового prompt.
Язык можно сменить в `Settings → Language` / `Настройки → Язык`.

Главное меню сгруппировано по задачам: инстансы, профили, статус и статистика,
обслуживание, диагностика и логи, настройки. Обычные `status` и `stats` теперь
показывают краткую операторскую сводку. Прежние подробные данные доступны через
`status [hostname] --verbose`, `stats [hostname] --verbose` и раздел диагностики.
Машинные форматы `--json` и `--raw` не локализуются и сохраняют стабильную схему.
Переменная окружения `NO_COLOR` и флаг `--no-color` отключают ANSI-цвета.

## Основные команды

```bash
# Instances
sudo twebproxy add
sudo twebproxy list
sudo twebproxy show [hostname]
sudo twebproxy status [hostname]
sudo twebproxy status [hostname] --verbose
sudo twebproxy restart [hostname]
sudo twebproxy repair [hostname]
sudo twebproxy diagnose [hostname]
sudo twebproxy audit [hostname]
sudo twebproxy stats [hostname]
sudo twebproxy stats [hostname] --verbose

# TLS certificates
sudo twebproxy cert-status [hostname]
sudo twebproxy cert-renew [hostname]
sudo twebproxy cert-renew [hostname] --dry-run
sudo twebproxy cert-renew [hostname] --force

# Profiles
sudo twebproxy profile-list [hostname]
sudo twebproxy profile-add [hostname]
sudo twebproxy profile-rotate [hostname] [profile]
sudo twebproxy profile-carrier [hostname] [profile]
sudo twebproxy profile-delete [hostname] [profile]

# Updates
sudo twebproxy check-update
sudo twebproxy manager-update
sudo twebproxy update

# Logs
sudo twebproxy logs
sudo twebproxy report

# Optional IPv4 network compatibility / Anti-DPI
sudo twebproxy dpi status [hostname]
sudo twebproxy dpi list-methods
sudo twebproxy dpi set HOST MODE --accept-shared-scope
sudo twebproxy dpi disable HOST
```

## Дополнительная совместимость сети / Anti-DPI

Функция необязательна. После установки действует `STOCK`: Manager не создаёт
DPI-таблицу nftables, не устанавливает `nfqws` и не запускает дополнительный
процесс. Выбор carrier (`https`, `https-lanes`, `websocket`,
`websocket-lanes`) остаётся независимым от DPI-режима.

Доступны шесть режимов:

| Режим | Зрелость и действие |
|---|---|
| `stock` | Принятый производственный путь без изменения TCP-трафика. |
| `window1152` | Экспериментально: окно приёма TCP 1152 в исходящем IPv4 SYN+ACK с `:443`. |
| `mss88` | Агрессивно/экспериментально: объявление MSS 88 в исходящем SYN+ACK; увеличивает число сегментов и накладные расходы. |
| `nfqws` | Экспериментально: первые ответные пакеты сервера обрабатывает закреплённая стратегия `nfqws`. |
| `window1152_nfqws` | Экспериментальная комбинация Window 1152, затем `nfqws`. |
| `mss88_nfqws` | Наиболее агрессивная комбинация MSS 88, затем `nfqws`; возможны заметные накладные расходы. |

В beta-версии обработка ограничена IPv4. IPv6 всегда остаётся `STOCK`.
Состояние привязано к фактическому публичному IPv4, а не к hostname: правило
затрагивает весь исходящий HTTPS-трафик с этого адреса и TCP-порта 443.
Рекомендуется отдельный IPv4. Если один адрес обслуживает несколько hostname
или сторонние HTTPS-службы, все они попадут в ту же область. Поэтому включение
требует явного подтверждения `--accept-shared-scope`; Manager не утверждает,
что смог автоматически доказать выделенность адреса.

Пример:

```bash
sudo twebproxy dpi status proxy.example
sudo twebproxy dpi set proxy.example window1152 --accept-shared-scope
sudo twebproxy dpi set proxy.example nfqws --accept-shared-scope
sudo twebproxy dpi disable proxy.example
```

`nfqws` поставляется из upstream
[`bol-van/zapret`](https://github.com/bol-van/zapret), tag `v72.13`, commit
`87e058624c72863db53bdaf7fb6f16576dddb6ab`; бинарник проверяется по закреплённому
SHA-256 перед установкой и каждым запуском службы. Если команда выполняется из
распакованного release-tree, используется вложенный `assets/nfqws-linux-x86_64`.
После обычной установки или script-only manager-update соседнего `assets/` нет,
поэтому при первом явном включении одного из трёх nfqws-режимов Manager загружает
официальный архив строго закреплённого `v72.13`, извлекает только ожидаемый
x86_64 member и до первого исполнения проверяет точный размер и SHA-256. Затем
отдельно проверяются строка version/commit и утверждённые аргументы `--dry-run`.
Непроверенные байты никогда не публикуются в runtime-путь
`/usr/local/libexec/twebproxy/twebproxy-nfqws`. Возврат в `STOCK` удаляет бинарник,
checksum, unit, документацию и DPI-состояние, поэтому исходный zero-artifact
инвариант сохраняется, даже если установленный бинарник повреждён: он не
исполняется, а удаляется только по фиксированному пути TWebProxy; следующее
явное включение повторяет полную проверяемую установку. Сторонние установки
`nfqws` не затрагиваются. Это режимы совместимости для контролируемой
инфраструктуры, а не обещание универсального обхода фильтрации.

## TLS и автопродление

- **Caddy** сам выпускает и продлевает сертификаты; manager проверяет публичный сертификат и состояние Caddy.
- **Nginx + Let's Encrypt** использует Certbot. Manager включает `certbot.timer`, а если системного timer нет — создаёт `twebproxy-cert-renew.timer`.
- После успешного продления Nginx проходит `nginx -t` и выполняет graceful reload.
- **Custom certificate** только контролируется; автоматический перевыпуск manager не выполняет.
- **Manual frontend** полностью оставляет lifecycle сертификата внешнему frontend.

`audit` проверяет срок сертификата, strict HTTPS и для managed Nginx сравнивает локальный certificate с реально отдаваемым на `:443`.

## Проверенный baseline

```text
Ubuntu 24.04
Caddy
https carrier
official MTProxy
Telegram Desktop native WEB Proxy
reboot/autostart: PASS
```

Fresh install использует проверенный commit `tproxy-server`:

```text
2873a08806d6e4d84830b9b5c4b0ec0f46af91f8
```

## Изменения по версиям

### 0.2.8-dpi-beta

- добавлена необязательная IPv4-подсистема совместимости с шестью режимами;
- сохранён неизменный по умолчанию `STOCK`;
- состояние и nftables-правила привязаны к точному публичному IPv4;
- добавлены EN/RU-интерфейс, статус, аудит, repair и диагностический отчёт;
- добавлены транзакционное переключение, точный откат и безопасный возврат в STOCK;
- закреплён и атрибутирован `nfqws v72.13` с проверкой SHA-256;
- добавлено проверяемое provisioning-получение nfqws после relocation/script-only
  update, не зависящее от сохранения исходной распаковки;
- исправлена очистка повреждённого TWebProxy-owned nfqws с последующим
  проверяемым повторным получением;
- `VERSION=0.2.8` оставлен строгим Stage 4 semver, а beta-label отделён в
  `MANAGER_RELEASE_VERSION=0.2.8-dpi-beta`.

### 0.2.7

- добавлен certificate lifecycle management;
- Nginx + Let's Encrypt получил автоматическое продление через Certbot timer;
- добавлены `cert-status` и `cert-renew`;
- добавлен безопасный renewal `--dry-run` и явный `--force`;
- `status` показывает краткое состояние TLS;
- `audit` проверяет срок сертификата, auto-renew и local/public certificate match;
- FULL report включает certificate status.

### 0.2.6

- добавлены `check-update` и `manager-update` через GitHub;
- добавлена проверка `SHA256SUMS` перед self-update;
- исправлен audit нескольких listener sockets;
- усилена strict TLS-проверка.

### 0.2.5

- добавлен `audit`;
- исправлен MTProxy systemd sandbox (`AF_NETLINK`);
- включён HTTP stats MTProxy;
- улучшены diagnostic reports и Caddy rollback.

Полная история: [`CHANGELOG.md`](CHANGELOG.md).

## Логи

```text
/opt/twebproxy-manager/logs/
```

Полный диагностический архив:

```bash
sudo twebproxy report
```

FULL report может содержать WEB/MTProxy secrets. SSH/TLS private keys, `/etc/shadow` и root/sudo credentials не собираются.
