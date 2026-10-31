# TWebProxy Manager — Stage A.1 Correction

Дата: 20 октября 2026 года.

**STATUS: PARTIAL**

Реализация шести разрешённых исправлений завершена; доступные целевые и связанные регрессии прошли. Полный engineering gate **не объявляется PASS**: обязательная реальная ENOSPC-проверка и real-nft kernel round-trip не выполнены из-за ограничений среды. Итог Stage A runner: **7 групп PASS, 0 FAIL, 2 NOT_EXECUTED; exit 77 / INCOMPLETE**.

Это development checkpoint, а не разрешение на production deployment и не объявление release accepted. Stage B не начат.

## 1. Исходные identities и checkpoint

Использован только supplied Stage A архив. Восстановление файла после очистки рабочего каталога выполнено по его прежнему идентификатору, а затем до любых implementation changes проверены оба заданных SHA-256.

| Объект | Фактическое значение |
| --- | --- |
| ZIP Stage A | `d5dfc292683e99931de7731256d68ad63a5d0fb585915039d96d05241061e76d` |
| Исходный manager | `5643680ce7bb2a92f8e38a31e90c0a36df1a06e1071972c142440fb6f00c5854` |
| Исходная machine version | `0.2.10` |
| Исходная release label | `0.2.10-dpi-beta` |
| Локальный baseline commit | `7a413ad19c723287babad135b1169d2df09dca97` |
| Новый manager | `91998dd80e019a5aed54043578b271b95fe6eb89f54e20084c307cab9c31a7b8` |
| VERSION / MANAGER_VERSION | `0.2.11` |
| MANAGER_RELEASE_VERSION | `0.2.11-dpi-beta` |
| Итоговый checkpoint commit | `3ab4c73e4b633a6508de55bbc4ab14b7278cfc49` |
| Commit message | `Stage A.1: correct DPI state and TUI confirmation` |

Исходный unpacked Stage A сохранён отдельно без изменений, с запрещённой записью. В доставленном ZIP есть побайтная копия исходного ZIP: `evidence/stageA1/baseline-stageA.zip`. Его hash повторно проверен после свежего извлечения.

В локальной истории есть implementation commit `0ba0d4fcb31f46c9411e1f666859b3ff106f3a48` и финальный checkpoint выше с упаковкой evidence. Оба локальные, без push/merge. Финальный checkpoint включает всё implementation tree.

## 2. Результат по каждому исправлению

| Дефект | Реализация | Доказательство | Ограничение |
| --- | --- | --- | --- |
| F01 | Исправлен | Отказы mkdir/cp и неполные копии с rc0; старые state/runtime hashes сохранены | Fault injection не называется real ENOSPC |
| F02 | Исправлен | Interrupted rename обрабатывается до чтения; отдельный новый Bash invocation сохраняет оба scopes | При неоднозначности — отказ, без автоматического выбора победителя |
| F11 | Исправлен в STOCK flow | Binary/checksum-only orphan, delete/query failure, CLI propagation, чужой symlink parent, сохранение других scopes | Real systemd/kernel cleanup не запускался |
| F12 | Исправлен; модельные тесты PASS | Exact rule semantics, отрицательные параметры, все пять активных modes, несколько scopes, большой output | Обязательный real-nft round-trip NOT_EXECUTED |
| F18 | Исправлен | PASS/FAIL/NOT_EXECUTED meta-test; реально недоступная ENOSPC ветка даёт INCOMPLETE | Пропущенные проверки не стали PASS |
| Anti-DPI TUI | Исправлен | Настоящий menu path с pipe/stdin/stdout: Yes/No/default No/EOF/return failure/die failure, RU/EN | Production VPS UI не трогался |

## 3. Explore / reproduce / regression first

Изучены actual call paths: `dpi_transaction_set/disable_ip` → locked preparation → publication → reconcile/verify/rollback; `dpi_disable_cmd` → no-state reconcile; `menu_network_compatibility` → core; SA3 result accounting → Stage A runner.

До исправления production code создан `tests/stagea/sa1-correction-fixture.sh` и запущен против неизменяемого manager 0.2.10. Первый regression-first набор: **21 case, 17 FAIL, 4 PASS**, общий exit1. CLI security gate и положительные контрольные случаи не объявлялись дефектными только ради количества failures. Лог: `evidence/stageA1/targeted-before.log`.

Воспроизведены initial-copy loss, interrupted publication, STOCK residue/false success, prefix/mode false match и отсутствие нужного TUI acknowledgement. F18 установлен из actual skip/exit control-flow; новая meta-regression дополнительно проверяет обработку старого script, который печатает SKIP, но возвращает0. Никакой такой synthetic script не выдаётся за real ENOSPC test.

Итоговый набор расширен до **32 cases**, все PASS. Дополнительный тест symlink parent сначала воспроизвёл удаление mock operator helper внутри disposable каталога и после narrow guard прошёл: `stock-symlink-before.log`, `stock-symlink-after.log`.

## 4. Минимальные production changes

### F01 — checked preparation

`dpi_prepare_transaction_state` явно проверяет mkdir, snapshot copy и proposed copy. Обе копии сравниваются по содержимому и entry sets через GNU diff без разыменования symlinks; прежняя проверка только размеров больше не достаточна. Proposed scopes также проходят existing scope-file parser/metadata checks.

Любой preparation failure прекращает операцию **до commit**. Не запускается rollback с недоказанным snapshot. Проверки return codes работают и внутри conditional-errexit call tree. Проверены в том числе частично скопированные данные при формально успешном cp.

Используется стандартный GNU `diff --no-dereference` (diffutils в поддерживаемой Debian/Ubuntu build-среде), без нового сетевого acquisition или runtime asset.

### F02 — operation-local interrupted publication

`dpi_resolve_pending_publication` работает под прежним DPI flock и вызывается до следующего mutating read/modify/write. Disable host-state lookup перенесён внутрь той же lock boundary. Отдельная операция set/disable также защищает preparation при прямом вызове примитива.

| On-disk state | Действие |
| --- | --- |
| Валидный live, нет retired/staging | Обычная операция |
| Live отсутствует, retired валиден, staging отсутствует или валиден | Вернуть retired в canonical path до чтения; убрать unpublished staging |
| Live валиден, retired отсутствует, staging валиден | Live авторитетен, убрать unpublished staging |
| Одновременно live и retired | Отказ без угадывания и с сохранением обоих |
| Повреждённый/symlink scope directory или неопределённый staging без live/retired | Отказ с сохранением evidence |

Никаких catalog/LKG/journal/generic recovery engine не добавлено. Read-only status не превращён в mutating repair. Это только разрешение двух rename boundaries существующей операции. Ошибка удаления retired после publication также больше не игнорируется.

### F11 — полная проверка STOCK в утверждённой области

Detector и postcondition учитывают exact owned binary, checksum, LICENSE, DPI helper, rules file, два DPI unit files и active units. В глобальном STOCK проверяется отсутствие **именно `ip twebproxy_dpi`** через успешное JSON `list tables ip`: ошибку доступа к nft нельзя принять за доказанное отсутствие таблицы.

Ошибки обязательного delete/unlink/daemon-reload не маскируются успешным return. Empty-rule apply имеет явный success return только после успешного удаления, а не статус ложного `[[ -s /dev/null ]]`. No-state ветка `dpi_disable_cmd` возвращает фактический failure caller, а не безусловный0.

При существующих других scopes выполняется их reconcile/verify, а не unconditional global teardown. Exact nfqws ownership guard сохранён; cleanup helper дополнительно не проходит через неожиданный symlink libexec/state parent. Чужой nfqws executable или чужая nft table не выбираются как cleanup target.

Это не redesign full-uninstall/core lifecycle. Backend firewall, operator tables и другая systemd architecture не менялись.

### F12 — semantic JSON verifier

Producer один раз полностью захватывается через `nft -j -n list table ip twebproxy_dpi`; его exit code проверяется до jq. Нет pipe к early-exit grep.

Проверяются family/table, единственная expected output chain с type filter, priority -150 и accept policy, полный упорядоченный finite rule set. Для каждого scope:

- exact IPv4 и TCP source port443;
- flags mask23 и SYN+ACK value18 для Window/MSS;
- window1152 либо MSS88;
- mark mask `0x40000000` и сравнение с0;
- conntrack reply packets1–6;
- queue217 и bypass;
- expected ownership comment и absence unexpected semantic statements/rules.

Runtime handles и меняющиеся anonymous counter values не являются ложными различиями. Поддерживаются документированные числовые/символьные bitmask representations и string/array queue flags. Неизвестная expression form не принимается как match. Для nfqws по-прежнему проверяются pinned binary hash и active worker.

Форма JSON сверена с primary project-authored documentation:

- [nft manual: JSON output](https://netfilter.org/projects/nftables/manpage.html)
- [libnftables-json schema, Debian bookworm package](https://manpages.debian.org/bookworm/libnftables1/libnftables-json.5.en.html)

**Предел доказательства:** schema documentation и test model не заменяют реальные listings конкретных поддерживаемых nft versions. Поэтому добавлен отдельный mandatory `sa1-real-nft-validation.sh`, который применяет rules в disposable network namespace и проверяет actual kernel JSON. Он в этой среде **не выполнен**. Совместимость live output на Debian12/Ubuntu22.04+ пока не объявляется подтверждённой этим запуском.

Verifier встроен в manager, а не вынесен в новый runtime asset: script-only install/update не получает дополнительной зависимости на файл из extracted directory.

### F18 — честный test result protocol

SA3 считает обязательные not-executed отдельно. Скрипт возвращает:

- 0: все обязательные assertions выполнены и прошли;
- 1: есть failure;
- 77: отсутствует mandatory execution при отсутствии failure.

Stage A runner использует тот же protocol, обрабатывает legacy SKIP+exit0 как incomplete и не печатает общий PASS при наличии NOT_EXECUTED. Новый meta-test проверяет все три результата; failure имеет приоритет над incomplete.

### TUI — narrow glue, core gate сохранён

Меню показывает hostname, публичный IPv4, предупреждение о всём HTTPS-трафике этого IPv4:443, известные shared hostnames и невозможность автоматически доказать выделенность адреса. Затем читает **явный** ответ с default No, без зависимости от stdout being a TTY.

Только Yes вызывает существующий `dpi_set_cmd HOST MODE --accept-shared-scope`. No, пустой ответ, EOF или read failure не вызывают core. Core запускается в изолированном shell call так, чтобы его die/exit не завершал меню; при failure нет дополнительного success message.

Добавлен DPI-only checked choice reader для возврата при EOF; общий `menu_choose`, общий `yesno` и навигация остальных меню не менялись. Settings → Anti-DPI остаётся на прежнем месте.

CLI без флага по-прежнему отказывает без требуемого подтверждения. CLI с флагом сохраняет прежний контракт. Local IPv4 validation и DNS ownership rules не ослаблены.

## 5. Фактически выполненные проверки

| Проверка | Фактический результат |
| --- | --- |
| Bash syntax всех 42 shell files | PASS, 0 failures |
| 32 Stage A.1 targeted cases | PASS |
| Stage A SA1 SIGPIPE | 12 PASS, 0 FAIL |
| SA2 orphan reconcile | 76 PASS, 0 FAIL |
| SA3 publication | 59 PASS, 0 FAIL, **1 mandatory NOT_EXECUTED** |
| SA4 DNS prune | 27 PASS, 0 FAIL |
| SA5 concurrency | 12 PASS, 0 FAIL |
| SA6 metadata | 6 PASS, 0 FAIL |
| Result-accounting meta-test | PASS |
| Real nft JSON/kernel round-trip | **NOT_EXECUTED**, exit77 |
| Полный Stage A runner | **INCOMPLETE**, exit77: 7 PASS groups, 0 FAIL groups, 2 NOT_EXECUTED groups |
| Existing six-mode DPI fixture | 110 PASS, mandatory_skips=0 |
| Installed-manager lifecycle fixture | 53 PASS, mandatory_skips=0 |
| DF3 cleanup/stages | 171 PASS, 0 FAIL |
| DF3b nfqws cleanup propagation | 37 PASS, 0 FAIL |
| TG5 local-address gate | 13 PASS, 0 FAIL |
| TG5b production-errexit gate | 19 PASS, 0 FAIL |
| Read-only core | PASS |
| TUI presentation | PASS |
| FixUI fixture | PASS |
| Localization static/flow, C.UTF-8 | PASS |
| Localization static/flow, C | PASS |
| Static smoke / certificate smoke | PASS / PASS |
| Stage4 protected function-set hash | PASS |
| Protected/non-DPI function comparison | PASS: 300 unchanged, 14 explicitly allowed modified |
| git diff --check, baseline → final checkpoint | PASS |
| Project SHA256SUMS | PASS, 76/76 |
| ZIP compressed-data test | PASS |
| Fresh ZIP extraction + SHA256SUMS | PASS, 76/76 |
| Fresh manager bash -n / protected Stage4 hash | PASS / PASS |

Full project Validation Campaign и повторный Stage4 A–V suite намеренно не запускались: задание требует соответствующий hash/invariants gate, не полную campaign. Stage4 hash-check script и ожидаемый hash не изменены. Старые text mocks получили JSON-adapter, но assertions не удалялись и не ослаблялись.

В одном промежуточном общем прогоне обнаружилась ошибка передачи аргумента нового targeted fixture; исправлена до финального прогона. Его ошибочный запуск не считается успешной проверкой. Позднее git diff --check выявил два trailing prompt spaces в evidence, не в реализации: raw output сохранён без изменения в gzip, в читаемой копии удалены только эти пробелы. Финальный range check прошёл.

## 6. Среда и невыполненные проверки

Среда не разрешает disposable network namespace:

```text
unshare: unshare failed: Operation not permitted
```

Вариант с user mapping тоже недоступен:

```text
unshare: write failed /proc/self/uid_map: Operation not permitted
```

На среде нет nft executable. Обычная попытка получить его через apt завершилась permission errors (в частности `setgroups ... Operation not permitted`, `seteuid ... Invalid argument`). Привилегии не повышались, ограничения не обходились.

SA3 реально дошёл до проверки доступности mount и зафиксировал:

```text
NOT_EXECUTED sa3_enospc_*: NOT_EXECUTED_ENVIRONMENT_LIMITATION (tmpfs mount unavailable)
```

Ни EFBIG, ни synthetic cp failure не представлены как real ENOSPC. Никаких nft operations в host namespace вместо запрещённого disposable namespace не выполнялось.

Чтобы закрыть оставшуюся проверку в другой сессии, использовать disposable Linux VM с nftables и разрешёнными net/mount operations, не production VPS:

```bash
bash tests/stagea/sa1-real-nft-validation.sh
bash tests/stagea/sa3-state-publication.sh
bash tests/stagea/run-stage-a-suite.sh
```

Real-nft fixture запускает только nft rules validation/round-trip в собственном net namespace; systemd/nfqws workers он не стартует. Real-systemd startup/reboot campaign здесь не проводилась.

## 7. Protected invariants и scope review

**Сохранены:**

- Шесть IDs: stock, window1152, mss88, nfqws, window1152_nfqws, mss88_nfqws.
- Existing rule-generation semantics и table ownership.
- Existing DPI flock implementation, descriptor/depth/wait.
- Shared IPv4 opt-in requirement и локальная IPv4 gate.
- nfqws v72.13, commit `87e058624c72863db53bdaf7fb6f16576dddb6ab`.
- nfqws binary SHA-256 `f34615964d7321650197cd69d3f7cbfdaabe8118b5a0d57c6e41dccdff658999`.
- Stage4 protected SHA-256 **`fd0e123c516324c23f0a42084f666104db5c35c58e1518a05abee1704b04abcb`**.
- Existing diagnostics JSON/raw collectors/renderers, кроме штатно изменённой release metadata.
- README и bundled assets побайтно неизменны.

Все existing Bash functions вне разрешённого набора сравнены через `declare -f`: 300 unchanged. Изменены только 12 разрешённых existing DPI functions, локальное Anti-DPI menu и catalog initializer (три новые RU/EN keys). Добавлены шесть небольших DPI/TUI helpers, без общей recovery subsystem.

Не изменялись backend firewall, relay updater, instance/profile lifecycle, Caddy/Nginx, Stage4 manager updater/rollback, downloader/pin, generic locks, diagnostics/logging architecture, остальные меню. Не реализованы новые Anti-DPI методы, Telemt или Stage3 recovery. Production не трогался. Push, merge и release publication не выполнялись.

Поведенческие гарантии real kernel/systemd не подменяются byte-identical/function-hash доказательством: статические invariants сохранены, две live проверки остаются открытыми.

## 8. Состав изменений и evidence

Production:

- `twebproxy-manager.sh`: scoped DPI preparation/recovery/cleanup/verifier, narrow TUI confirmation, RU/EN strings, release constants.
- `VERSION`, `CHANGELOG.md`, `SHA256SUMS`: release metadata.

Tests:

- Новые `sa1-correction-fixture.sh`, `sa1-runner-status-fixture.sh`, `sa1-real-nft-validation.sh`, `sa1-scope-invariants.sh`.
- Новые test-only `nft-json-model.sh`, `stage-a-results.sh`.
- Stage A runner и SA3 result accounting.
- JSON adapters в shared DPI harness, двух existing DPI fixtures и трёх относящихся к cleanup/locality fieldgate fixtures. Existing assertions сохранены.

Внутри source ZIP:

- `evidence/stageA1/results.json`: machine-readable results.
- `evidence/stageA1/focused.diff`: exact code/tests/metadata diff с нулевым context; SHA256SUMS/evidence-generated content описаны отдельно.
- `evidence/stageA1/baseline-stageA.zip`: unchanged input checkpoint.
- Before/after и final regression logs.
- `stage-a-suite-final.raw.log.gz`: unmodified raw final suite output; readable .log отличается только двумя trailing prompt spaces.
- `REVIEW.md`: инструкции и ограничения для следующей сессии.

Project SHA256SUMS пересоздан по текущим файлам, не оставлен stale «protected evidence». Проверено 76 записей после build и после fresh extraction.

## 9. Delivery identities

**Source ZIP:** `TWebProxy-Manager-v0.2.11-dpi-beta-stageA1.zip`

SHA-256:

```text
45f1fb7f83c02be0293d81fe0bd472e55c5c4d7a454eed47ce9566cd5c118d29
```

**Manager SHA-256:**

```text
91998dd80e019a5aed54043578b271b95fe6eb89f54e20084c307cab9c31a7b8
```

Checksum-файл `TWebProxy-StageA1-SHA256SUMS.txt` покрывает ZIP и этот отчёт. Собственный hash checksum-файла внутрь него не включается, чтобы не создавать самоссылку.

Архив извлечён в свежий каталог; проверены все manifest entries, синтаксис manager, baseline ZIP identity и protected Stage4 hash. Локальный рабочий tree после commit чистый.

**Незавершённое:** real ENOSPC и real nft supported-version/kernel round-trip. До их выполнения результат остаётся PARTIAL, а не DEVELOPMENT_COMPLETE. После доставки работа остановлена; Stage B не начат.
