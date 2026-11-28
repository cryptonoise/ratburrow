# RatBurrow
```bash
curl -fsSL https://raw.githubusercontent.com/cryptonoise/ratburrow/refs/heads/main/ratburrow.sh | sudo bash
```

Файлы репозитория (все лежат в корне, основной скрипт сам скачивает остальные):

| Файл | Назначение |
|---|---|
| `ratburrow.sh` | основной скрипт: меню, установка, откат, обновление |
| `rb-deploy.sh` | служебные скрипты RELAY и BACKEND (`make_scripts`) |
| `rb-prepare.sh` | «Подготовить сервер» |
| `rb-honeypot.sh` | генератор сайта-приманки |
| `relay-test.sh` | диагностика задержек и потерь сервера, отчёт для поддержки хостинга |
| `changelog.md` | история изменений |

Версия `RB_PART_VERSION` в `rb-deploy.sh` и `rb-prepare.sh` должна совпадать с `RB_VERSION` в `ratburrow.sh`. Локальный запуск: положить все файлы в один каталог или задать `RB_PARTS_DIR`.

## Диагностика сервера: relay-test.sh

Запускается на RELAY (или любом сервере). Меряет задержки и потери до шлюза хостера и внешних адресов, строит маршруты (mtr), проверяет MTU пути, время TCP/TLS-соединений, «соседей по гипервизору» (CPU steal, джиттер таймера) и счётчики сетевой карты. Каждая команда идёт под анимацией и показана в отчёте вместе с выводом. Отчёт сохраняется в `/root/relay-test-ХОСТ-ДАТА.txt`: сводка вверху, затем вывод всех команд, готовый текст обращения в поддержку хостинга (по-русски и по-английски).

```bash
curl -fsSL https://raw.githubusercontent.com/cryptonoise/ratburrow/refs/heads/main/relay-test.sh | sudo bash
```

С параметрами (адрес BACKEND и IP клиента):

```bash
curl -fsSL https://raw.githubusercontent.com/cryptonoise/ratburrow/refs/heads/main/relay-test.sh | sudo bash -s -- --backend 89.125.120.175 --client 78.81.150.211
```

| Параметр | Назначение |
|---|---|
| `--backend IP` | пинг, mtr и MTU до BACKEND |
| `--client IP` | считает, сколько пакетов клиента дошло до сервера: во время теста на клиенте нужно запустить `ping -c 300 -i 0.2 IP_СЕРВЕРА` |
| `--count N` | пакетов пинга на цель (по умолчанию 100) |
| `--quick` | короткий прогон, около 3 минут |
| `--out ФАЙЛ` | куда сохранить отчёт |
| `--no-install` | не устанавливать недостающие пакеты (mtr, ethtool, tcpdump и т.д.) |

Полный прогон занимает 6–8 минут. Скачать отчёт на свой компьютер: `scp root@IP_СЕРВЕРА:/root/relay-test-*.txt .`
