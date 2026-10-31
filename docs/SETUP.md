# Настройка TWebProxy Manager / Setting up TWebProxy Manager

Руководство относится к v0.2.22 (Stage H). Это development-checkpoint, а не
релиз: не ставьте его на рабочий VPS до предрелизных испытаний.
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
| Временная страница-заглушка | Генерирует простую страницу. Подходит, чтобы проверить HTTPS; позже замените её настоящим сайтом. |
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

Нужен клиент Telegram с поддержкой WEB Proxy. Manager не проверяет версии
клиентов; работа настоящих клиентов на компьютере и телефоне проверяется на
предрелизных испытаниях.

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

### Известные ограничения (предрелизный backlog)

- P1-G-01: офлайн-восстановление (`restore-update-backup`) сообщает
  `RESTORE_SUCCESS`, даже если обновить `MANAGER_VERSION` в `global.env` не
  удалось (например, файл неизменяемый). Исполняемые файлы при этом
  восстановлены. Сообщение об этом выводится в stderr; `twebproxy repair`
  переписывает метаданные.
- P1-INHERITED-01: stock MTProxy получает secret клиента через `-S`; локальные
  пользователи сервера могут прочитать его в `/proc`. Не используйте сервер с
  недоверенными локальными учётными записями либо смонтируйте `/proc` с
  `hidepid=2`.

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
| Temporary placeholder page | Generates a simple page. Good for checking HTTPS; replace it with a real site later. |
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

### Known limitations (pre-release backlog)

- P1-G-01: the offline restore (`restore-update-backup`) prints
  `RESTORE_SUCCESS` even when it could not update `MANAGER_VERSION` in
  `global.env` (for example, an immutable file). The executables are restored;
  the problem is reported on stderr, and `twebproxy repair` rewrites the
  metadata.
- P1-INHERITED-01: stock MTProxy receives the client secret with `-S`, so local
  users of the server can read it in `/proc`. Do not run the proxy on a host
  with untrusted local accounts, or mount `/proc` with `hidepid=2`.
