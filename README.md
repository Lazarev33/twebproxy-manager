# TWebProxy Manager

**TWebProxy Manager** — интерактивный установщик и менеджер self-hosted Telegram **WEB Proxy** для Linux.

Проект разворачивает официальный [`telegramdesktop/tproxy-server`](https://github.com/telegramdesktop/tproxy-server) как WEB relay и официальный [`TelegramMessenger/MTProxy`](https://github.com/TelegramMessenger/MTProxy) как backend.

> Статус: **beta**  
> Текущая версия: **0.2.5**

## Как это работает

```text
Telegram Desktop
        ↓
Telegram WEB Proxy
        ↓ HTTPS / WSS :443
Caddy / Nginx
        ↓
tproxy-server
        ↓
MTProxy
        ↓
Telegram
```

Внешний клиент подключается только к обычному HTTPS-порту `443`.  
Relay, admin-интерфейс и MTProxy backend управляются отдельно и изолируются от внешнего доступа.

## Возможности

- интерактивная установка и управление;
- несколько hostname на одном сервере;
- несколько profiles / secrets;
- carrier modes:
  - `https`
  - `https-lanes`
  - `websocket`
  - `websocket-lanes`
- автоматический подбор внутренних портов;
- Caddy + automatic TLS;
- Nginx + Let's Encrypt;
- Nginx + собственный сертификат;
- manual frontend для уже существующего Nginx/Caddy;
- systemd services и автоматический restart;
- systemd `LoadCredential` для конфигурации и секретов;
- nftables isolation backend-портов;
- обновление `tproxy-server` с тестами, health-check и rollback;
- смена secret и carrier без переустановки;
- диагностика, аудит и восстановление конфигурации;
- persistent installer/runtime logs;
- safe и FULL diagnostic reports.

## Требования

- Debian 12+ или Ubuntu 22.04+;
- x86_64;
- systemd;
- root/sudo;
- публичный IPv4;
- домен или поддомен с `A`-записью на сервер;
- TCP `443`;
- для автоматического получения сертификата также TCP `80`.

Пример DNS:

```text
A  webproxy.example.com  -> 203.0.113.10
```

В manager указывается только hostname:

```text
webproxy.example.com
```

без `https://`, порта и path.

## Установка

```bash
chmod +x twebproxy-manager.sh
sudo ./twebproxy-manager.sh
```

После установки доступна команда:

```bash
sudo twebproxy
```

CLI-вариант:

```bash
sudo ./twebproxy-manager.sh core-install
sudo twebproxy add
```

## Основные команды

```bash
twebproxy add
twebproxy list
twebproxy show [hostname]

twebproxy status [hostname]
twebproxy stats [hostname]
twebproxy diagnose [hostname]
twebproxy audit [hostname]
twebproxy repair [hostname]
twebproxy restart [hostname]

twebproxy profile-list [hostname]
twebproxy profile-add [hostname]
twebproxy profile-show [hostname] [profile]
twebproxy profile-rotate [hostname] [profile]
twebproxy profile-carrier [hostname] [profile]
twebproxy profile-delete [hostname] [profile]

twebproxy update
twebproxy report
twebproxy logs
twebproxy logs-tail [lines]
```

## Логи

Логи проекта сохраняются в:

```text
/opt/twebproxy-manager/logs/
```

Для обычного диагностического архива:

```bash
sudo twebproxy logs-pack
```

Для полного отчёта тестового сервера:

```bash
sudo twebproxy report
```

FULL report может содержать WEB/MTProxy secrets, но не собирает root/sudo password, `/etc/shadow`, SSH private keys и содержимое TLS private keys.

## Проверенный baseline

Первый подтверждённый E2E-сценарий:

```text
OS:       Ubuntu 24.04
Frontend: Caddy
Carrier:  https
Backend:  official MTProxy
Client:   Telegram Desktop native WEB proxy
Result:   CONNECTED
```

`https-lanes`, `websocket`, `websocket-lanes` и Nginx входят в дальнейшую тестовую матрицу.

## Безопасность

Основные меры:

- конфигурация и secrets хранятся с ограниченными правами;
- сервисы работают от отдельных системных пользователей;
- чувствительные файлы передаются сервисам через systemd credentials;
- relay/admin работают на loopback;
- backend/stats ports закрываются через nftables;
- managed HTTP access logs отключены;
- private keys не включаются в diagnostic bundles.

Подробнее: [`docs/SECURITY.md`](docs/SECURITY.md).

## Upstream

TWebProxy Manager не реализует Telegram WEB Proxy protocol самостоятельно.

Используются:

- `telegramdesktop/tproxy-server` — WEB relay;
- `TelegramMessenger/MTProxy` — baseline backend.

Fresh install закреплён на проверенном commit `tproxy-server`:

```text
2873a08806d6e4d84830b9b5c4b0ec0f46af91f8
```

Переход на более свежий upstream выполняется отдельно через:

```bash
sudo twebproxy update
```

## Документация

Дополнительные материалы находятся в `docs/`:

- `ARCHITECTURE.md`
- `SECURITY.md`
- `TESTING.md`
- `ROADMAP.md`
- `UPSTREAM.md`
