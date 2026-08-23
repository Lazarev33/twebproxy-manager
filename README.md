# TWebProxy Manager

**TWebProxy Manager** — installer и manager для self-hosted Telegram **WEB Proxy** на Debian/Ubuntu.

Репозиторий: https://github.com/Lazarev33/twebproxy-manager

Текущая версия: **0.2.6 beta**.

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
- Nginx + Let's Encrypt;
- Nginx + custom certificate;
- manual frontend для существующего Caddy/Nginx;
- systemd services и autostart;
- systemd credentials для конфигурации и секретов;
- nftables isolation backend-портов;
- диагностика, audit, repair и diagnostic reports;
- безопасное обновление `tproxy-server` с test/build/health-check/rollback;
- проверка и обновление самого TWebProxy Manager через GitHub.

## Требования

- Debian 12+ или Ubuntu 22.04+;
- x86_64;
- systemd;
- root/sudo;
- публичный IPv4;
- hostname с `A`-записью на VPS;
- TCP 443;
- TCP 80 для автоматического выпуска TLS-сертификата.

## Установка

```bash
chmod +x twebproxy-manager.sh
sudo ./twebproxy-manager.sh
```

После установки:

```bash
sudo twebproxy
```

## Основные команды

```bash
# Instances
sudo twebproxy add
sudo twebproxy list
sudo twebproxy show [hostname]
sudo twebproxy status [hostname]
sudo twebproxy restart [hostname]
sudo twebproxy repair [hostname]
sudo twebproxy diagnose [hostname]
sudo twebproxy audit [hostname]

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
```

`twebproxy manager-update` обновляет сам manager из `Lazarev33/twebproxy-manager` и проверяет `SHA256SUMS`, синтаксис Bash и версию candidate перед установкой.

`twebproxy update` обновляет только upstream `tproxy-server` и использует config-check, health-check и rollback.

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

## Логи

```text
/opt/twebproxy-manager/logs/
```

Полный диагностический архив:

```bash
sudo twebproxy report
```

FULL report может содержать WEB/MTProxy secrets. SSH/TLS private keys, `/etc/shadow` и root/sudo credentials не собираются.

## Документация

Дополнительные детали находятся в `docs/`:

- `ARCHITECTURE.md`
- `SECURITY.md`
- `TESTING.md`
- `ROADMAP.md`
- `UPSTREAM.md`
