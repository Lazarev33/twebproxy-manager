# Stage B.1 (v0.2.13-beta) — технический план

Baseline — `project/` v0.2.12. Manager `805a5749…`, ZIP `642ae3fc…`, проверено по SHA. Работа ведётся в отдельном git-репозитории `/root/twebproxy-dev/work`, baseline-коммит `4f87f41`. Хост — production: только код и тесты на моделях, реальных nft/systemd/mount/ENOSPC-испытаний нет.

## Факты, установленные до правок

1. **F1.** Единственное место, где LIBEXEC_DIR получает режим, отличный от `root:root 0755`, — `rebuild_firewall` (3137). Все остальные создатели — `prepare_users_and_dirs` (2624), `dpi_*` (1448, 1479), Stage 4 restore helper — используют 0755. В A.1 этой строки не было.
2. **F1, родители.** И в coreutils 8.32, и в 9.1 `install` делает `umask(0)` и создаёт предков с 0755. Поэтому `install -d` безопасен на чистой ОС, где нет `/usr/local/libexec`. А вот `mkdir -p -m` создаёт предков с 0700 — его использовать нельзя.
3. **F1, symlink.** `install -d` на symlink меняет режим цели. Helper уже отвергает symlink, но позже, чем выполняется chmod.
4. **R5.** Реальные привилегированные пути есть в шести скриптах: Stage B `real-nft-validation` и `real-systemd-validation`, A.1 `sa1-real-nft-validation`, секция 1 SA3 (tmpfs в host mount ns), fieldgate `tg1` (`nft -c` на ядре хоста) и `tg3` (`unshare -m` + tmpfs поверх `/usr/local/sbin` и `/opt/twebproxy-manager`; через `TG3_INNER=1` монтирование идёт без namespace). Раннеры Stage A, Stage B и fieldgate запускают их по умолчанию. Fieldgate к тому же не понимает код 77.
5. **R1** (CONFIRMED_STATIC). Пакет nftables: `ExecReload=nft -f /etc/nftables.conf`, а конфиг начинается с `flush ruleset`. В systemd 249/252/255 у `PartOf` → `CONSISTS_OF` есть только `PROPAGATE_STOP` и `PROPAGATE_RESTART`, reload не передаётся. `ReloadPropagatedFrom=` создаёт `TRY_RELOAD` с `matters=false`. По `job_compare` вместе с `After=` наш reload выполняется после reload nftables, и его отказ не останавливает unit.
6. **R2** (CONFIRMED_STATIC). `RequiredBy` → `PROPAGATE_STOP` и `RESTART`, рекурсивно. Значит, restart или stop nftables (в том числе `try-restart` в postinst пакета) перезапускает или останавливает все relay и бэкенды. Это fail-closed, с кратким простоем.
7. **R3.** После неудачного `nft -f` helper возвращает 1, не читая live. Если timeout сработал после commit, live новый, canonical старый, а сообщение об этом молчит.

## Изменения

- **F1.** В `rebuild_firewall`: отказ, если `BASE_DIR` или `LIBEXEC_DIR` — symlink; `install -d -m 0700 BASE_DIR`; отдельно `install -d -o root -g root -m 0755 LIBEXEC_DIR`. Режим совпадает с каноническим контрактом, и хосты, повреждённые v0.2.12, лечатся первым же rebuild. Другие функции не трогаются.
- **R1.** Добавить `ReloadPropagatedFrom=nftables.service` в генерируемый backend firewall unit. Восстановление на реальном systemd — NEEDS_VM, не заявляется. Для DPI unit — только запись в backlog (anti-DPI вне scope).
- **R3.** Новая функция `backend_fw_apply_failed`: после отказа `nft -f` прочитать live, правдиво классифицировать (без изменений / commit, несмотря на ошибку / неизвестно) и сойтись так же, как остальные пути отказа (откат к прежней таблице или сохранение изоляции при первой установке). Всегда возвращать 1. Укладывается в бюджет `TimeoutStartSec`.
- **R2.** Код не меняется: переделка топологии зависимостей задевает relay lifecycle (C2) и ослабляет fail-closed. Документировать, внести в backlog, NEEDS_VM.
- **R5.** `tests/lib/lab-gate.sh`. Привилегированное действие разрешено только при выполнении всех условий: `TWEBPROXY_LAB_MODE=disposable-vm`; root; маркер `/etc/twebproxy-disposable-lab` — обычный root-файл, содержащий `/etc/machine-id`; на хосте нет ни одного отпечатка TWebProxy (`/etc/twebproxy`, `/usr/local/libexec/twebproxy`, `/usr/local/sbin/twebproxy`, `/opt/twebproxy-manager`, `/srv/twebproxy`, `/etc/systemd/system/twebproxy*`). Иначе — NOT_EXECUTED и exit 77, до любого вызова unshare/nft/mount. Шлюз включается в 6 скриптов. SA3 делает re-exec в `unshare --mount --propagation private` и проверяет, что mount ns отличается; добавлен контрольный прогон ENOSPC. `tg3` получает явный `--propagation private` и проверку ns. Fieldgate-раннер переходит на протокол 0/1/77.
- **Тесты.** Модельная тестовая обвязка создаёт LIBEXEC_DIR так же, как production (0755). Новые fixtures: права LIBEXEC_DIR, включая запуск от непривилегированного аккаунта; гейт с PATH-заглушками и подменённым корнем ФС; R3 commit-then-fail; содержимое unit. Scope-тест B.1 против v0.2.12.
- **Метаданные.** 0.2.13 / 0.2.13-beta, CHANGELOG, документация тестов, `SHA256SUMS`, коммит, ZIP.

## Проверка

Сначала RED на v0.2.12, затем GREEN. Перед запуском раннеров на этом хосте — проверка их скриптов и PATH-заглушки для опасных бинарников; если заглушка вызвана, это провал. Привилегированные испытания — NOT_EXECUTED, план лаборатории приложен. Stage C не начинается.
