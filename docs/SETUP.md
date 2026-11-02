# Настройка TWebProxy Manager / Setting up TWebProxy Manager

Для неопубликованного v0.2.26 стандартный TUI выбирает параметры автоматически;
ручные поля остаются в Advanced. См. [TUI](TUI-SMART-DEFAULTS.md) и
[текущий pre-RC](PRERC-v0.2.26.md). Нижеследующие инструкции сохраняют
совместимость с опубликованным v0.2.25; кандидат ещё не находится в main.

Руководство актуализировано для опубликованной v0.2.25-beta (development, не стабильный Release). Полная установка включает `bridge/` и `sites/`; production не авторизован.
The English version follows the Russian one.

---

## Русский

### Что нужно заранее

- Debian 12+ или Ubuntu 22.04+, x86_64, systemd, права root.
- Публичный IPv4 и hostname, у которого DNS-запись `A` указывает на этот сервер.
- Свободный TCP 443 (HTTPS). Для автоматических сертификатов (Caddy или
  Nginx + Let's Encrypt) нужен ещё TCP 80.
- Telegram WEB Proxy всегда работает по HTTPS на порту 443; в клиенте порт не
  указывается.

### Быстрая настройка

1. Запустите `sudo ./twebproxy-manager.sh` (после установки — `sudo twebproxy`).
2. При первом интерактивном запуске выберите язык.
3. Выберите «Быстрая настройка». Manager установит основу (relay, MTProxy,
   службы) и спросит:
   - hostname;
   - тип настройки: «Быстрая (рекомендуется)» или «Расширенная»;
   - сайт на этом hostname (см. ниже);
   - TLS: рекомендуется Caddy с автоматическим HTTPS.
4. Проверьте план и подтвердите. В быстрой настройке порты подбираются
   автоматически; создаётся профиль `default` с новым secret и carrier `https`;
   MTProxy получает 1 worker и 4096 соединений. Сетевой режим — `STOCK`.
5. В конце Manager покажет ссылки для Telegram и шаги подключения.

Расширенная настройка задаёт те же вопросы, что и раньше: порты, имя профиля,
secret, carrier, workers и лимит соединений. `sudo twebproxy add` запускает тот
же мастер.

Конец ввода (Ctrl-D) на любом вопросе отменяет создание. Ответ «нет» на
подтверждении плана ничего не меняет. Если DNS не совпадает с адресом сервера,
по умолчанию создание прерывается. Неверный hostname можно ввести заново
(три попытки).

### Сайт на hostname

На том же hostname работает обычный сайт. Сейчас поддерживаются три варианта:

| Вариант | Что делает |
|---|---|
| Встроенный сайт по умолчанию | Разворачивает «Культурные маршруты Подмосковья» из `sites/podmoskovye/`. |
| Мой статический сайт | Копирует указанный каталог с `index.html`. |
| Моё веб-приложение | Проксирует адрес на loopback (например, `http://127.0.0.1:3000`). |

Конструктора сайтов, загрузки или снимков сайта в этой версии нет.

### TLS и фронтенд

| Режим | Когда выбирать |
|---|---|
| Caddy (рекомендуется) | Новый сервер: сертификат выпускается и продлевается автоматически; нужны порты 80 и 443. |
| Nginx + Let's Encrypt | На сервере уже используется Nginx; certbot продлевает сертификат, нужен порт 80. |
| Nginx + свой сертификат | Сертификат выпускается вне Manager; продлевать его нужно самостоятельно. |
| Вручную | Порт 443 уже обслуживает ваш веб-сервер; `twebproxy manual-snippet` покажет нужную конфигурацию. |

### Подключение Telegram

`twebproxy show <hostname>` (или пункт меню «Подключить Telegram») выводит для
каждого профиля «Ссылку» `https://t.me/webproxy?server=…&secret=…` и «Ссылку TG»
`tg://webproxy?…`.

1. Откройте ссылку на устройстве с Telegram или отправьте её себе в Telegram и
   нажмите.
2. Подтвердите добавление прокси. Порт и протокол вводить не нужно.
3. Выдавайте разным пользователям отдельные профили (`twebproxy profile-add`),
   чтобы менять или отзывать доступ по отдельности.

Нужен клиент Telegram с поддержкой WEB Proxy. Gate 3 содержит отчёт оператора об успешной работе Telegram для iOS 13.1.2; Desktop runtime и остальные клиенты — NOT_EXECUTED. [CLIENT-VALIDATION.md](bridge-gate3/CLIENT-VALIDATION.md).

### Управляемый Bridge

Откройте **Foreign Nodes → Add Foreign Node**. Введите зарубежный VPS и SSH-доступ,
независимо проверьте ED25519 fingerprint удалённого хоста и подтвердите план.
Менеджер настраивает WireGuard, локальный forwarder на RU Entry и stock MTProxy
на Foreign Exit. Клиентская ссылка остаётся на RU-домене. Exit должен быть
доверенным: его root-оператор может получить secret. MVP — одна нода/профиль.
Для работы: `sudo twebproxy foreign-node status|diagnose|repair|remove`.
[OPERATIONS.md](bridge-gate3/OPERATIONS.md).

### Совместимость сети / Anti-DPI

По умолчанию действует `STOCK`: трафик не изменяется. С него и стоит начинать.
Пять дополнительных режимов (`window1152`, `mss88`, `nfqws`,
`window1152_nfqws`, `mss88_nfqws`) экспериментальны:

- они работают только для IPv4 и затрагивают все HTTPS-соединения с того же
  публичного IPv4 на порту 443, включая другие сайты и службы на этом адресе;
- включение требует явного подтверждения (`--accept-shared-scope` в CLI);
- ни один режим не гарантирует обход DPI; накладные расходы и направление
  каждого режима показывает `twebproxy dpi list-methods`;
- вернуть `STOCK`: `twebproxy dpi disable <hostname>`.

Меняйте режим только при реальных проблемах с подключением, по одному, и
проверяйте настоящим клиентом.

### Проверка и устранение неполадок

- `twebproxy status <hostname>` — краткий статус; у каждой проблемы указан
  следующий шаг.
- `https://<hostname>/` должен открываться в браузере с действительным
  сертификатом.
- `twebproxy diagnose <hostname>`, `twebproxy audit <hostname>` — подробности
  и проверка изоляции backend.
- `twebproxy cert-status <hostname>` — сертификат; `twebproxy repair <hostname>` —
  восстановить службы и конфигурацию.
- Частые причины: запись `A` указывает не на этот сервер; порт 80 или 443 занят
  другим веб-сервером; закрыт межсетевой экран провайдера.

### Безопасность хоста (v0.2.25)

В v0.2.24 исправлены и целево проверены P1 по backend-изоляции и fail-closed
procfs. В дополнение к nftables используется systemd IP socket policy, а при
неработающей обязательной защите /proc небезопасный MTProxy не запускается.
Bridge использует точные WireGuard peer/interface/route ограничения.
Не публикуйте process argv, приватные ссылки и секреты. [SECURITY.md](SECURITY.md).

---

## English

### Prerequisites

- Debian 12+ or Ubuntu 22.04+, x86_64, systemd, root.
- A public IPv4 and a hostname whose DNS `A` record points to this server.
- TCP 443 free for HTTPS. Automatic certificates (Caddy, or Nginx with Let's
  Encrypt) also need TCP 80.
- Telegram WEB Proxy always uses HTTPS on port 443; clients never enter a port.

### Quick setup

1. Run `sudo ./twebproxy-manager.sh` (after installation: `sudo twebproxy`).
2. On the first interactive start, choose the language.
3. Choose "Quick setup". The manager installs the core (relay, MTProxy,
   services) and asks for:
   - the hostname;
   - the setup type: "Quick (recommended)" or "Advanced";
   - the website on that hostname (below);
   - TLS: Caddy with automatic HTTPS is recommended.
4. Review the plan and confirm. Quick setup picks ports automatically and
   creates the profile `default` with a new secret and the `https` carrier;
   MTProxy gets 1 worker and 4096 connections. The network mode is `STOCK`.
5. At the end the manager prints the Telegram links and connection steps.

Advanced setup asks the full set of questions as before: ports, profile name,
secret, carrier, workers and connection limit. `sudo twebproxy add` runs the
same wizard.

End of input (Ctrl-D) at any question cancels the creation. Answering "no" to
the plan changes nothing. If DNS does not match the server address, the
default answer stops the creation. A mistyped hostname can be entered again
(three attempts).

### The website on the hostname

The hostname also serves an ordinary website. Three options exist today:

| Option | What it does |
|---|---|
| Bundled default website | Deploys «Культурные маршруты Подмосковья» from `sites/podmoskovye/`. |
| My static website | Copies a directory with `index.html`. |
| My web application | Reverse-proxies a loopback URL (for example `http://127.0.0.1:3000`). |

There is no website builder, upload or snapshot feature in this version.

### TLS and frontend

| Mode | When to choose it |
|---|---|
| Caddy (recommended) | New servers. The certificate is issued and renewed automatically; ports 80 and 443 are needed. |
| Nginx + Let's Encrypt | Nginx is already in use. certbot renews the certificate; port 80 is needed. |
| Nginx + own certificate | The certificate is issued outside the manager, and you renew it yourself. |
| Manual | Port 443 is already served by your web server; `twebproxy manual-snippet` prints the configuration to add. |

### Connecting Telegram

`twebproxy show <hostname>` (or the menu item "Connect Telegram") prints two
links for every profile: the Link `https://t.me/webproxy?server=…&secret=…` and
the TG link `tg://webproxy?…`.

1. Open the link on the device with Telegram, or send it to yourself in
   Telegram and tap it.
2. Accept the new proxy. No port or protocol has to be entered.
3. Give separate users their own profiles (`twebproxy profile-add`), so access
   can be changed or revoked individually.

A Telegram client with WEB Proxy support is required. The manager does not
check client versions; real desktop and mobile clients are verified during
pre-release testing.

### Managed foreign Bridge

Open **Foreign Nodes → Add Foreign Node**, supply foreign SSH details,
independently verify the ED25519 host fingerprint, and approve the plan.
The Manager provisions WireGuard, Entry loopback forwarder and private stock
MTProxy on trusted Exit. The client link remains on RU Entry only.
Gate 2/3 MVP: one node/profile. [OPERATIONS.md](bridge-gate3/OPERATIONS.md).

### Network compatibility / Anti-DPI

The default is `STOCK`, which leaves traffic unchanged. Start there. The five
other modes (`window1152`, `mss88`, `nfqws`, `window1152_nfqws`,
`mss88_nfqws`) are experimental:

- They work on IPv4 only. They affect every HTTPS connection from the same
  public IPv4 on port 443, including other sites and services on that address.
- Enabling one needs explicit confirmation (`--accept-shared-scope` on the
  command line).
- None guarantees getting past DPI. `twebproxy dpi list-methods` shows each
  mode's direction and overhead.
- Return to `STOCK` with `twebproxy dpi disable <hostname>`.

Change the mode only for real connection problems, one mode at a time, and test
with a real client.

### Validation and troubleshooting

- `twebproxy status <hostname>`: compact status; every problem comes with the
  next step to take.
- `https://<hostname>/` must open in a browser with a valid certificate.
- `twebproxy diagnose <hostname>` and `twebproxy audit <hostname>`: details and
  the backend isolation check.
- `twebproxy cert-status <hostname>`: the certificate. `twebproxy repair <hostname>`:
  restores services and configuration.
- Common causes: the `A` record points elsewhere; another web server holds
  port 80 or 443; the provider's firewall blocks them.

### Host security (v0.2.25)

Focused v0.2.24 P1 acceptance covered backend systemd socket isolation and
procfs fail-closed startup. Bridge adds exact WireGuard peer/interface/route
restrictions. Do not publish process argv, private links or secrets.
[SECURITY.md](SECURITY.md).
