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

Версия `RB_PART_VERSION` в `rb-deploy.sh` и `rb-prepare.sh` должна совпадать с `RB_VERSION` в `ratburrow.sh`. Локальный запуск: положить все файлы в один каталог или задать `RB_PARTS_DIR`.
