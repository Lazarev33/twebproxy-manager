<div align="center">

# TWebProxy Manager

**Telegram WEB Proxy на своём сервере. Настоящий HTTPS, понятное управление.**

Самостоятельное размещение · Несколько доменов и профилей · Caddy / Nginx · RU / EN

![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-252a34?style=flat-square)
![Shell](https://img.shields.io/badge/Bash-Linux-353b48?style=flat-square)
![Version](https://img.shields.io/badge/latest%20checkpoint-v0.2.22--beta-3673ba?style=flat-square)
![Status](https://img.shields.io/badge/status-pre--RC%20testing-e7a53b?style=flat-square)

[Возможности](#возможности) · [Как работает](#как-это-работает) · [Начало работы](#начало-работы) · [Команды](#управление) · [Статус разработки](#статус-и-известные-риски)

</div>

---

> [!WARNING]
> **Пока не production-ready.** Последний проверенный checkpoint — **v0.2.22-beta (Stage H)**. В GitHub \`main\` пока опубликован **старый код v0.2.9**, а полный исходный коммит Stage H хранится в проверенном Git bundle. Предрелизные испытания выявили открытые P1, включая потерю изоляции backend после отдельных операций с \`nftables.service\`. Не используйте эту версию как подтверждённый безопасный production-релиз.

## Зачем нужен TWebProxy

TWebProxy Manager — Bash-менеджер для собственного **Telegram WEB Proxy** на Debian/Ubuntu. Он объединяет веб-фронтенд с обычным HTTPS, Telegram relay, штатный MTProxy, сертификаты, профили, firewall и диагностику.

**Это именно WEB Proxy**, а не VLESS/Xray, VPN-туннель или замена Telegram-клиента. Основа — [официальный tproxy-server](https://github.com/telegramdesktop/tproxy-server) и [stock MTProxy](https://github.com/TelegramMessenger/MTProxy).

### Возможности

| 🌐 HTTPS и сайт | 🔑 Пользователи и профили |
| :--- | :--- |
| Caddy или Nginx; Let's Encrypt или собственный сертификат; обычный сайт на том же hostname | Несколько инстансов, независимые профили и secret, ротация доступа |
| **🛡️ Изоляция и диагностика** | **🧰 Обслуживание** |
| nftables, проверка портов и служб, диагностика TLS, безопасные отчёты | Проверяемое обновление, локальный backup, откат, управление службами |

В checkpoint **v0.2.22-beta** также реализованы пошаговый мастер настройки, первое включение RU/EN, короткие сводки, подсказки к ошибкам и помощь с Telegram-ссылками. Важно: эти новые функции ещё **не соответствуют коду, опубликованному в \`main\`**.

## Как это работает

\`\`\`mermaid
flowchart TB
    A["Telegram · WEB Proxy"] -->|"HTTPS / WebSocket :443"| B["Caddy / Nginx"]
    U["Обычный браузер"] -->|"HTTPS :443"| B
    B -->|"Сайт / приложение"| W["Публичный сайт"]
    B -->|"WEB Proxy endpoint"| R["tproxy-server · loopback"]
    R --> M["MTProxy · stock"]
    M --> T["Telegram network"]

    classDef public fill:#e9f3ff,stroke:#528ed1,color:#19395c;
    classDef internal fill:#f2f4f7,stroke:#a5aeba,color:#252a32;
    class A,U,B public;
    class W,R,M,T internal;
\`\`\`

Запросы к сайту обслуживаются как обычный HTTPS. WEB Proxy проходит через отдельный маршрут к relay и MTProxy. Backend не должен быть доступен напрямую из интернета — именно поэтому проверка firewall входит в обязательные предрелизные испытания.

## Начало работы

**Требования:** Debian 12+ / Ubuntu 22.04+, x86_64, systemd, root, публичный IPv4, доменное имя с правильной DNS \`A\`-записью. Для HTTPS нужен TCP 443, для автоматических сертификатов обычно также TCP 80.

Для **отдельной тестовой VM**:

\`\`\`bash
git clone https://github.com/Lazarev33/twebproxy-manager.git
cd twebproxy-manager
chmod +x twebproxy-manager.sh
sudo ./twebproxy-manager.sh
\`\`\`

> [!IMPORTANT]
> Эта команда пока получает **v0.2.9 из \`main\`**, а не checkpoint v0.2.22. Мы не предлагаем \`curl | bash\` и не выдаём старую ветку за актуальный релиз. После публикации проверенного исходного дерева эта секция будет переключена на конкретный тег и контрольную сумму.

### Рекомендуемый сценарий в v0.2.22-beta

\`\`\`text
1. Выбрать язык → RU / EN
2. Быстрая настройка → hostname
3. Выбрать сайт → временная страница, static или local app
4. HTTPS → Caddy (рекомендуется)
5. Сетевой режим → STOCK
6. Проверить план → подтвердить
7. Получить Telegram WEB Proxy ссылки
\`\`\`

Реальный сайт на том же hostname можно подключить из статического каталога или локального приложения. **Конструктора сайтов пока нет.**

## Управление

Основные команды для checkpoint v0.2.22 (после установки менеджера в систему):

\`\`\`bash
sudo twebproxy                   # Интерактивное меню
sudo twebproxy add               # Создать инстанс
sudo twebproxy list              # Список инстансов
sudo twebproxy show HOST         # Ссылки для Telegram (содержат secret)
sudo twebproxy status HOST       # Краткое состояние
sudo twebproxy diagnose HOST     # Диагностика
sudo twebproxy audit HOST        # Проверка конфигурации и изоляции
sudo twebproxy repair HOST       # Восстановление конфигурации
sudo twebproxy cert-status HOST  # Проверка сертификата
sudo twebproxy profile-list HOST # Профили
sudo twebproxy dpi list-methods  # Сетевые режимы
\`\`\`

Для машинного вывода есть \`--json\` и \`--raw\`; для отключения цветовых последовательностей — \`--no-color\`. Ссылки WEB Proxy и secret не публикуйте в логах, issue и скриншотах.

## Совместимость сети / Anti-DPI

**По умолчанию — STOCK.** Менеджер не должен без необходимости изменять сетевой трафик. Остальные режимы — расширенные экспериментальные настройки; ни один не гарантирует доступность в любой сети.

| Режим | Назначение |
| :--- | :--- |
| \`stock\` | Без вмешательства в TCP; рекомендуемый baseline |
| \`window1152\` | Объявляет уменьшенное TCP-окно в SYN+ACK |
| \`mss88\` | Объявляет MSS 88; возможны высокие накладные расходы |
| \`nfqws\` | Обработка первых ответных пакетов через pinned nfqws |
| \`window1152_nfqws\` | Комбинация двух механизмов |
| \`mss88_nfqws\` | Более агрессивная комбинация |

> [!CAUTION]
> Режимы относятся к **IPv4 TCP/443 на публичном IP сервера**, а не только к одному Telegram hostname. На общем IP они могут затронуть другие HTTPS-службы. Поэтому включение требует явного \`--accept-shared-scope\`. При проблемах сначала проверьте DNS, сертификат, маршрут и доступность backend — не включайте все режимы подряд.

## Статус и известные риски

| Этап | Состояние |
| :--- | :--- |
| Stage A–H | Разработка завершена; Stage H независимо проверен как development checkpoint |
| Linux-интеграция | Проверялись реальные обновления, откаты, systemd, nftables, Nginx и Caddy/ACME |
| Предрелизная готовность | **BLOCKED** — подтверждённые дефекты ещё не исправлены |
| Production release | **Не опубликован** |

**Открытые проблемы перед RC:**

1. **Firewall / P1:** операции с \`nftables.service\` могут удалять правила изоляции backend или останавливать обе ноды.
2. **Rollback / P1:** при отказе записи \`global.env\` возможно ложное сообщение об успешном восстановлении.
3. **Локальные секреты / P1:** stock MTProxy передаёт \`-S\` в аргументах процесса, видимых некоторым локальным пользователям.
4. **DPI / P2:** после ENOSPC сохранённое состояние и реальная таблица ядра могут расходиться.

Сценарии с реальными клиентами Telegram и подписанным GitHub-релизом также ещё требуют отдельной проверки. **Не воспринимайте успешные модельные тесты как доказательство production-ready.**

Полная история и план исправлений — в [ROADMAP](docs/ROADMAP.md).

## Документация

| Документ | Для чего |
| :--- | :--- |
| [Architecture](docs/ARCHITECTURE.md) | Компоненты, маршруты и разделение ответственности |
| [Roadmap](docs/ROADMAP.md) | Этапы, статус и условия RC |
| [Security](docs/SECURITY.md) | Секреты, права и границы безопасности |
| [Testing](docs/TESTING.md) | Лабораторные наборы и пределы тестового покрытия |
| [Updates](docs/UPDATES.md) | Проверка обновлений, backup и rollback |
| [Upstream](docs/UPSTREAM.md) | Исходные компоненты и их происхождение |

---

<details>
<summary><strong>English — short overview</strong></summary>

**TWebProxy Manager** is a self-hosted Telegram WEB Proxy manager for Debian/Ubuntu. It combines Caddy/Nginx HTTPS, a real public website, the official \`tproxy-server\`, stock MTProxy, multiple instances/profiles, nftables isolation, diagnostics and verified update workflows.

The latest independently checked development checkpoint is **v0.2.22-beta (Stage H)**. Its guided RU/EN setup recommends **Caddy + HTTPS + STOCK**. The \`main\` branch currently still contains the older **v0.2.9** code. Known P1 defects block a production Release Candidate. **Do not deploy as production-ready software.**

See the roadmap and security documentation above before experimenting on a disposable VPS.

</details>

<div align="center">

**Open source · Self-hosted · Development beta**

Built around official Telegram components. No claims of invisible traffic, unblockable IPs, or guaranteed DPI circumvention.

</div>
