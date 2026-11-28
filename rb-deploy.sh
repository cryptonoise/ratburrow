#!/usr/bin/env bash
# RatBurrow: служебные скрипты RELAY и BACKEND (make_scripts: создаются в $TMPD).
# Часть основного скрипта: подключается из ratburrow.sh (source) и отдельно не запускается.
RB_PART_VERSION="4.16"
if [ "${BASH_SOURCE[0]}" = "$0" ]; then echo "Это часть RatBurrow, запускайте ratburrow.sh"; exit 1; fi

# ───────────────────────── скрипты установки (создаются в $TMPD) ─────────────────────────
make_scripts() {
  local D="$TMPD"

  # Генератор Honeypot вынесен в отдельный файл rb-honeypot.sh (репозиторий): скачивается в момент, когда нужен (honeypot_fetch)

  # RELAY: пакеты (обновление системы делает пункт «Подготовить сервер»)
  cat > "$D/relay-pkgs.sh" <<'EOF'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
APT=(apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
timeout --foreground 1800 "${APT[@]}" update -qq
timeout --foreground 1800 "${APT[@]}" install -y curl unzip nginx certbot ufw sqlite3 python3 openssl dnsutils ca-certificates gzip iproute2 cron socat tzdata tar
EOF

  # 3x-ui: три отдельных шага, чтобы у каждого был свой счётчик времени
  cat > "$D/xui-fetch.sh" <<'__CHAIN_EOF__'
set -e
# установщик 3x-ui нужной версии: до 4 попыток, каждая не дольше 60 с
for i in 1 2 3 4; do
  if curl -4 -fsSL --connect-timeout 10 --max-time 60 "https://raw.githubusercontent.com/mhsanaei/3x-ui/${1:?не передана версия 3x-ui}/install.sh" -o /tmp/3xui-install.sh && [ -s /tmp/3xui-install.sh ]; then
    exit 0
  fi
  echo "попытка $i не удалась, повтор" >&2
  sleep 2
done
echo "установщик 3x-ui не скачан за 4 попытки" >&2
exit 1
__CHAIN_EOF__
  cat > "$D/xui-install.sh" <<'__CHAIN_EOF__'
set -e
export XUI_NONINTERACTIVE=1 XUI_DB_TYPE=sqlite XUI_SSL_MODE=none XUI_PANEL_PORT="$1" XUI_ENABLE_FAIL2BAN=false
# Установщик 3x-ui сам скачивает архив и x-ui.sh долго и без общего лимита времени; архив уже скачан и проверен предыдущими шагами,
# поэтому в копии установщика (версия закреплена) эти загрузки заменяются копированием из /tmp/xui-cache.
# Если фрагменты не найдены (другая версия), установщик работает как есть и скачивает всё сам.
if [ -s /tmp/xui-cache/x-ui.tar.gz ] && [ -s /tmp/xui-cache/x-ui.sh ]; then
  python3 - <<'PY' || echo "патч установщика не применён: он скачает архив сам (возможны задержки)" >&2
import sys
p = "/tmp/3xui-install.sh"
s = open(p, encoding="utf-8").read()
subs = [
    ("curl -fLR --retry 5 --retry-delay 3 --connect-timeout 15 --speed-limit 1 --speed-time 300 -o ${xui_folder}-linux-$(arch).tar.gz ${url}",
     "cp -f /tmp/xui-cache/x-ui.tar.gz ${xui_folder}-linux-$(arch).tar.gz", 1),
    ('verify_release_checksum "${url}" "${xui_folder}-linux-$(arch).tar.gz"', "true", 1),
    ('require_repo_files "${script_ref}" "${required_files[@]}"', "true", 1),
    ('curl -fLRo "${xui_script_temp}" "https://raw.githubusercontent.com/MHSanaei/3x-ui/${script_ref}/x-ui.sh"',
     'cp -f /tmp/xui-cache/x-ui.sh "${xui_script_temp}"', 1),
    ("apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl",
     "dpkg -s cron curl tar tzdata socat ca-certificates openssl >/dev/null 2>&1 || { apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl; }", 2),
]
for old, new, n in subs:
    if s.count(old) != n:
        print("не найден фрагмент установщика: " + old[:70], file=sys.stderr)
        sys.exit(3)
for old, new, n in subs:
    s = s.replace(old, new)
open(p, "w", encoding="utf-8").write(s)
print("установщик подготовлен: загрузки заменены копированием из кэша")
PY
fi
bash /tmp/3xui-install.sh "${2:-}" </dev/null
__CHAIN_EOF__
  cat > "$D/xui-download.sh" <<'__CHAIN_EOF__'
set -e
# Архив панели, контрольная сумма и x-ui.sh скачиваются здесь, а не в установщике 3x-ui: у него загрузка без общего лимита времени
# (оборвётся, только если 300 секунд подряд не идёт ни байта, и так до 5 раз) — отсюда прежние «10+ минут».
# Здесь зависшая загрузка обрывается через 30 с (скорость ниже 20 КБ/с), общий лимит попытки 25 минут, попыток до 3. Архив большой (около 80 МБ).
V="${1:?не передана версия 3x-ui}"
case "$(uname -m)" in
  x86_64 | amd64) A=amd64 ;;
  aarch64 | arm64) A=arm64 ;;
  *) echo "архитектура $(uname -m): предзагрузка не поддерживается" >&2; exit 3 ;;
esac
D=/tmp/xui-cache
rm -rf "$D"; mkdir -p "$D"
B="https://github.com/MHSanaei/3x-ui/releases/download/$V/x-ui-linux-$A.tar.gz"
dl() { curl -4 -fsSL --connect-timeout 10 --max-time "$3" --speed-limit 20480 --speed-time 30 -o "$2" "$1"; }
ok=0
for i in 1 2 3; do
  echo "попытка $i: $B" >&2
  rm -f "$D/x-ui.tar.gz"
  if dl "$B" "$D/x-ui.tar.gz" 1500 && [ -s "$D/x-ui.tar.gz" ]; then ok=1; break; fi
  echo "попытка $i не удалась (обрыв или скорость ниже 20 КБ/с), повтор" >&2
  sleep 2
done
[ "$ok" = 1 ] || { echo "архив 3x-ui не скачан за 3 попытки" >&2; exit 1; }
ok=0
for i in 1 2 3; do dl "$B.sha256" "$D/x-ui.tar.gz.sha256" 30 && [ -s "$D/x-ui.tar.gz.sha256" ] && ok=1 && break; sleep 2; done
[ "$ok" = 1 ] || { echo "контрольная сумма архива не скачана" >&2; exit 1; }
ok=0
for i in 1 2 3; do dl "https://raw.githubusercontent.com/MHSanaei/3x-ui/$V/x-ui.sh" "$D/x-ui.sh" 30 && [ -s "$D/x-ui.sh" ] && ok=1 && break; sleep 2; done
[ "$ok" = 1 ] || { echo "x-ui.sh не скачан" >&2; exit 1; }
echo "скачано: $(du -h "$D/x-ui.tar.gz" | cut -f1)"
__CHAIN_EOF__
  cat > "$D/xui-verify.sh" <<'__CHAIN_EOF__'
set -e
D=/tmp/xui-cache
want=$(awk 'NR==1{print $1}' "$D/x-ui.tar.gz.sha256")
have=$(sha256sum "$D/x-ui.tar.gz" | awk '{print $1}')
if [[ ! "$want" =~ ^[0-9a-f]{64}$ ]] || [ "$want" != "$have" ]; then
  echo "контрольная сумма не совпала: ожидалось ${want:-<нет>}, получено $have" >&2
  rm -rf "$D"
  exit 1
fi
tar tzf "$D/x-ui.tar.gz" >/dev/null
head -c 100 "$D/x-ui.sh" | grep -q '^#!'
echo "SHA-256 совпала, архив читается: $have"
__CHAIN_EOF__
  cat > "$D/xui-check.sh" <<'EOF'
set -e
/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1 || true
systemctl restart x-ui
sleep 3
systemctl is-active --quiet x-ui
ss -tlnH | grep -q "127.0.0.1:$1"
EOF

  cat > "$D/nginx-temp.sh" <<'EOF'
set -e
DOMAIN="$1"
XUI_PATH="${2:-}"
XUI_PATH="${XUI_PATH#/}"
XUI_PATH="${XUI_PATH%/}"
[ -n "$XUI_PATH" ] || { echo "WebBasePath пустой" >&2; exit 1; }
mkdir -p /var/www/certbot
# стандартная страница «Welcome to nginx» выдаёт сервер при обращении по IP и ломает маскировку — убираем
rm -f /etc/nginx/sites-enabled/default
V6=""
if [ -e /proc/net/if_inet6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = 0 ]; then V6=1; fi
L6_80=""
[ -n "$V6" ] && L6_80="listen [::]:80;"
rm -f /etc/nginx/sites-enabled/apex.conf /etc/nginx/sites-available/apex.conf   # прежнее имя конфига
cat > /etc/nginx/sites-available/xpn.conf <<EOT
server {
    listen 80;
    $L6_80
    server_name $DOMAIN;

    server_tokens off;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Временный HTTP-конфиг уже публикует Honeypot на корне домена.
    root /var/www/honeypot/$DOMAIN;
    index index.html;
    location = /$XUI_PATH { return 301 /$XUI_PATH/; }
    location ^~ /$XUI_PATH/ {
        proxy_pass http://127.0.0.1:999;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    location ~ /\.(?!well-known) { return 404; }
    location / { try_files \$uri \$uri/ =404; }
}
EOT
# панель скрыта: убираем её location из временного конфига (диапазон от location = /<путь> до закрывающей скобки)
if [ "${3:-0}" = 1 ]; then
  sed -i "/location = \/$XUI_PATH /,/^    }\$/d" /etc/nginx/sites-available/xpn.conf
fi
ln -sf /etc/nginx/sites-available/xpn.conf /etc/nginx/sites-enabled/xpn.conf
nginx -t
systemctl enable --now nginx
systemctl reload nginx
EOF

  # RELAY: nginx не должен копить освобождённую память в heap glibc (на длинных потоках heap раздувался до 1+ ГБ при ~300 МБ живых данных:
  # динамический порог mmap в glibc растёт, крупные буферы уходят в brk-heap и фрагментируют его). Явные MALLOC_* отключают динамику:
  # крупные выделения идут через mmap и сразу возвращаются системе; перезапуск nginx нужен, чтобы переменные попали в процесс.
  cat > "$D/nginx-malloc.sh" <<'EOF'
set -e
DD=/etc/systemd/system/nginx.service.d
mkdir -p "$DD"
cat > "$DD/chain-malloc.conf" <<'EOT'
[Service]
Environment=MALLOC_MMAP_THRESHOLD_=131072
Environment=MALLOC_TRIM_THRESHOLD_=131072
Environment=MALLOC_ARENA_MAX=1
OOMScoreAdjust=-300
EOT
systemctl daemon-reload
F=/etc/nginx/conf.d/chain-limit.conf
if [ -f "$F" ]; then
  sed -i 's/^http2_body_preread_size .*/http2_body_preread_size 1m;/; s/, 4m около 65 МБ\/с (замер на стенде)/, 1m около 16 МБ\/с (4m расходовали память nginx)/' "$F"
  # оборванные клиентами соединения закрываются сразу, без ожидания FIN: буферы освобождаются быстрее
  grep -q '^reset_timedout_connection' "$F" || echo 'reset_timedout_connection on;' >> "$F"
fi
nginx -t
systemctl restart nginx
sleep 2
systemctl is-active --quiet nginx
# Проверка по /proc/PID/environ здесь невозможна: nginx затирает свою область environ заголовком процесса («nginx: worker process»),
# поэтому MALLOC_* там не видны, даже когда применены. Проверяем то, что задаёт systemd: переменные в окружении службы и отсутствие
# непрочитанных изменений юнита (daemon-reload выполнен, nginx перезапущен после него).
envs=$(systemctl show -p Environment --value nginx)
for v in MALLOC_MMAP_THRESHOLD_=131072 MALLOC_TRIM_THRESHOLD_=131072 MALLOC_ARENA_MAX=1; do
  printf '%s' "$envs" | grep -q -- "$v" || { echo "в окружении службы nginx нет $v" >&2; exit 1; }
done
[ "$(systemctl show -p NeedDaemonReload --value nginx)" = no ] || { echo "юнит nginx изменён после загрузки: нужен daemon-reload" >&2; exit 1; }
m=$(systemctl show -p MainPID --value nginx)
rss=$(ps -o rss= --ppid "$m" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')
echo "nginx перезапущен, MALLOC_* заданы в окружении службы (в /proc/PID/environ nginx их не показывает); RSS workers: ${rss} kB"
EOF

  # RELAY и BACKEND: ограничения памяти для VPS с 1 ГБ ОЗУ. Скрипт ставит инструмент /usr/local/sbin/chain-memory (apply | activate | remove | status)
  # и вызывает его с переданными аргументами. Инструмент: сжатый своп в ОЗУ (zram) или файл подкачки, потолок TCP-памяти и размеров сокетных буферов,
  # лимиты памяти для x-ui, Xray и моста (GOMEMLIMIT, MemoryHigh/MemoryMax), earlyoom (завершает самый тяжёлый процесс до того, как сервер «зависнет»).
  cat > "$D/mem-tune.sh" <<'EOF'
set -u
install -d /usr/local/sbin
cat > /usr/local/sbin/chain-memory <<'EOT'
#!/bin/bash
# chain-memory: ограничения памяти для VPS с малым ОЗУ (RELAY и BACKEND)
#   apply     записать настройки: sysctl, zram/своп, лимиты служб, earlyoom (службы не перезапускаются)
#   activate  перезапустить x-ui / chain-bridge, если лимиты ещё не действуют в запущенном процессе; вернуть страницы из дискового свопа в ОЗУ
#   remove    убрать всё, что поставил apply
#   status    показать текущее состояние
exec </dev/null
set -u
CONF=/etc/sysctl.d/99-zz-chain-memory.conf
SWAPFILE=/swapfile-chain
EARLYOOM_MARK=/var/lib/chain-memory.earlyoom
UNITS="x-ui chain-bridge"
MEM_MB=$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo)

unit_exists() { systemctl cat "$1.service" >/dev/null 2>&1; }
zram_active() { swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/dev/zram'; }

# своп: zram (сжатая подкачка в ОЗУ); если ядро без zram и подкачки нет совсем — файл 1 ГБ
setup_swap() {
  local total avail
  if ! zram_active && modprobe zram 2>/dev/null && command -v zramctl >/dev/null 2>&1; then
    cat > /usr/local/sbin/chain-zram <<'EOZ'
#!/bin/bash
# zram-своп: размер — половина ОЗУ (не более 2 ГБ); данные сжимаются, реально занимают в 2–3 раза меньше
case "${1:-start}" in
  start)
    modprobe zram || exit 1
    mb=$(awk '/^MemTotal:/ { m = int($2 / 2048); if (m > 2048) m = 2048; print m }' /proc/meminfo)
    dev=""
    for alg in zstd lz4 lzo-rle ""; do
      if [ -n "$alg" ]; then dev=$(zramctl --find --size "${mb}M" --algorithm "$alg" 2>/dev/null) || dev=""
      else dev=$(zramctl --find --size "${mb}M" 2>/dev/null) || dev=""; fi
      [ -n "$dev" ] && break
    done
    [ -n "$dev" ] || exit 1
    mkswap "$dev" >/dev/null && swapon -p 100 "$dev"
    ;;
  stop)
    for d in $(swapon --show=NAME --noheadings 2>/dev/null | grep '^/dev/zram'); do swapoff "$d" && zramctl --reset "$d"; done
    ;;
esac
EOZ
    chmod 755 /usr/local/sbin/chain-zram
    cat > /etc/systemd/system/chain-zram.service <<'EOZ'
[Unit]
Description=zram swap (chain-memory)

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/chain-zram start
ExecStop=/usr/local/sbin/chain-zram stop

[Install]
WantedBy=multi-user.target
EOZ
    systemctl daemon-reload
    systemctl enable chain-zram.service >/dev/null 2>&1 || true
    systemctl restart chain-zram.service >/dev/null 2>&1 || true
  fi
  if zram_active; then echo "своп: zram включён"; return 0; fi
  total=$(awk '/^SwapTotal:/ { print int($2 / 1024) }' /proc/meminfo)
  if [ "${total:-0}" -ge 256 ]; then echo "своп: уже есть (${total} МБ), zram недоступен"; return 0; fi
  avail=$(df -Pm / | awk 'NR == 2 { print $4 }')
  if [ "${avail:-0}" -ge 4096 ] && [ ! -e "$SWAPFILE" ]; then
    { fallocate -l 1G "$SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$SWAPFILE" bs=1M count=1024 status=none; } \
      && chmod 600 "$SWAPFILE" && mkswap "$SWAPFILE" >/dev/null && swapon -p 10 "$SWAPFILE" \
      && { grep -q "^$SWAPFILE " /etc/fstab || echo "$SWAPFILE none swap sw,pri=10 0 0" >> /etc/fstab; echo "своп: файл $SWAPFILE 1 ГБ"; } \
      || { swapoff "$SWAPFILE" 2>/dev/null; rm -f "$SWAPFILE"; echo "своп: создать не удалось (контейнер без поддержки подкачки?)"; }
  else
    echo "своп: не создан (мало места на диске или файл уже есть)"
  fi
}

# sysctl: потолок памяти TCP и размеры буферов по объёму ОЗУ. Файл 99-zz грузится после 99-relay-network-tuning.conf и переопределяет его
write_sysctl() {
  local buf pages sw=30
  if   [ "$MEM_MB" -le 1536 ]; then buf=8388608     # 8 МБ: при 60 мс RTT хватает на ~1 Гбит/с на соединение
  elif [ "$MEM_MB" -le 3072 ]; then buf=16777216
  else buf=33554432; fi
  pages=$(( MEM_MB * 256 ))
  zram_active && sw=100
  {
    echo "# chain-memory: ограничения памяти (ОЗУ ${MEM_MB} МБ)"
    echo "net.core.rmem_max=$buf"
    echo "net.core.wmem_max=$buf"
    echo "net.ipv4.tcp_rmem=4096 131072 $buf"
    echo "net.ipv4.tcp_wmem=4096 65536 $buf"
    [ "$MEM_MB" -le 3072 ] && echo "net.ipv4.tcp_mem=$(( pages * 8 / 100 )) $(( pages * 12 / 100 )) $(( pages * 18 / 100 ))"
    echo "net.ipv4.tcp_notsent_lowat=131072"
    echo "vm.swappiness=$sw"
    zram_active && echo "vm.page-cluster=0"
    [ "$MEM_MB" -le 3072 ] && echo "vm.min_free_kbytes=32768"
  } > "$CONF"
  sysctl -q -p "$CONF" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
}

# лимиты служб: GOMEMLIMIT (мягкий потолок кучи Go: сборщик мусора работает чаще вместо роста памяти; x-ui передаёт его запускаемому Xray),
# MemoryHigh (замедляет службу при превышении), MemoryMax (жёсткий потолок: служба перезапускается сама), OOMScoreAdjust (x-ui — первым при нехватке)
write_limits() {
  local gl high max u d
  gl=$(( MEM_MB * 30 / 100 )); high=$(( MEM_MB * 55 / 100 )); max=$(( MEM_MB * 72 / 100 ))
  for u in $UNITS; do
    unit_exists "$u" || continue
    d=/etc/systemd/system/$u.service.d
    mkdir -p "$d"
    cat > "$d/chain-memory.conf" <<EOD
[Service]
Environment=GOMEMLIMIT=${gl}MiB
MemoryHigh=${high}M
MemoryMax=${max}M
OOMScoreAdjust=300
EOD
    echo "лимиты: $u (GOMEMLIMIT ${gl} МиБ, MemoryHigh ${high} МБ, MemoryMax ${max} МБ)"
  done
  systemctl daemon-reload
}

# earlyoom: при нехватке памяти и свопа завершает самый тяжёлый процесс (предпочтительно xray), не трогая sshd и nginx
setup_earlyoom() {
  local d=/etc/systemd/system/earlyoom.service.d eo
  if ! command -v earlyoom >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y earlyoom >/dev/null 2>&1 \
      || { echo "earlyoom: пакет не установился, пропущено"; return 0; }
    : > "$EARLYOOM_MARK"
  fi
  eo=$(command -v earlyoom) || return 0
  mkdir -p "$d"
  cat > "$d/chain.conf" <<EOD
[Service]
ExecStart=
ExecStart=$eo -m 5 -s 10 -r 0 --avoid ^(sshd|nginx|systemd|systemd-journal)\$\$ --prefer ^xray
EOD
  systemctl daemon-reload
  systemctl enable earlyoom >/dev/null 2>&1 || true
  systemctl restart earlyoom >/dev/null 2>&1 || true
  systemctl is-active --quiet earlyoom && echo "earlyoom: работает" || echo "earlyoom: не запустился"
}

has_limit() {  # GOMEMLIMIT есть в окружении запущенной службы?
  local pid
  pid=$(systemctl show -p MainPID --value "$1" 2>/dev/null)
  [ -n "$pid" ] && [ "$pid" != 0 ] && tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -q '^GOMEMLIMIT='
}

# страницы из дискового свопа возвращаются в ОЗУ, только если памяти заведомо хватает (иначе swapoff сам вызвал бы нехватку памяти)
reclaim_swap() {
  local dev used_mb avail_mb
  while read -r dev used_mb; do
    [ -n "$dev" ] || continue
    case "$dev" in /dev/zram*) continue ;; esac
    [ "${used_mb:-0}" -ge 64 ] || continue
    avail_mb=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
    if [ "$avail_mb" -gt $(( used_mb * 3 / 2 + 150 )) ]; then
      if timeout 300 swapoff "$dev" 2>/dev/null; then
        swapon -a 2>/dev/null || true
        swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$dev" || swapon "$dev" 2>/dev/null || true
        echo "своп: $dev очищен (было занято ${used_mb} МБ)"
      fi
    else
      echo "своп: $dev занят ${used_mb} МБ, свободной памяти мало — очистка пропущена"
    fi
  done < <(swapon --show=NAME,USED --bytes --noheadings 2>/dev/null | awk '{ printf "%s %d\n", $1, $2 / 1048576 }')
}

do_activate() {
  local u i
  for u in $UNITS; do
    unit_exists "$u" && [ -f "/etc/systemd/system/$u.service.d/chain-memory.conf" ] || continue
    systemctl is-active --quiet "$u" || continue
    has_limit "$u" && continue
    systemctl restart "$u"
    for i in $(seq 1 20); do systemctl is-active --quiet "$u" && break; sleep 2; done
    systemctl is-active --quiet "$u" && echo "перезапущен: $u (лимиты памяти применены)" || echo "ВНИМАНИЕ: $u не запустился после перезапуска" >&2
  done
  reclaim_swap
}

do_remove() {
  local u
  for u in $UNITS; do
    rm -f "/etc/systemd/system/$u.service.d/chain-memory.conf"
    rmdir "/etc/systemd/system/$u.service.d" 2>/dev/null || true
  done
  rm -f "$CONF" /etc/systemd/system/earlyoom.service.d/chain.conf
  rmdir /etc/systemd/system/earlyoom.service.d 2>/dev/null || true
  systemctl disable --now chain-zram.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/chain-zram.service /usr/local/sbin/chain-zram
  if [ -e "$SWAPFILE" ]; then
    swapoff "$SWAPFILE" 2>/dev/null || true
    sed -i "\|^$SWAPFILE |d" /etc/fstab
    rm -f "$SWAPFILE"
  fi
  if [ -f "$EARLYOOM_MARK" ]; then
    systemctl disable --now earlyoom >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 purge -y earlyoom >/dev/null 2>&1 || true
    rm -f "$EARLYOOM_MARK"
  else
    systemctl restart earlyoom >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload
  sysctl --system >/dev/null 2>&1 || true
  rm -f /usr/local/sbin/chain-memory
  echo "ограничения памяти сняты (лимиты в уже запущенных службах исчезнут при их перезапуске)"
}

do_status() {
  echo "ОЗУ: ${MEM_MB} МБ"; free -m | sed -n '1,3p'
  echo "своп:"; swapon --show 2>/dev/null | sed 's/^/  /'
  sysctl net.core.rmem_max net.ipv4.tcp_mem vm.swappiness 2>/dev/null | sed 's/^/  /'
  local u
  for u in $UNITS; do
    unit_exists "$u" && echo "$u: $(has_limit "$u" && echo "GOMEMLIMIT действует" || echo "лимиты не действуют (нужен перезапуск: chain-memory activate)")"
  done
  systemctl is-active earlyoom 2>/dev/null | sed 's/^/earlyoom: /'
}

[ "$#" -gt 0 ] || set -- status
for a in "$@"; do
  case "$a" in
    apply)    setup_swap; write_sysctl; write_limits; setup_earlyoom ;;
    activate) do_activate ;;
    remove)   do_remove ;;
    status)   do_status ;;
    *) echo "использование: chain-memory apply|activate|remove|status" >&2; exit 1 ;;
  esac
done
EOT
chmod 755 /usr/local/sbin/chain-memory
exec /usr/local/sbin/chain-memory "$@"
EOF

  cat > "$D/cert.sh" <<'EOF'
DOMAIN="$1"; EMAIL="$2"
mkdir -p /var/www/certbot
certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --deploy-hook "systemctl reload nginx"
EOF

  cat > "$D/sub-setup.sh" <<'EOF'
set -e
DOMAIN="$1"; SCHEME="$2"; TITLE="${3:-}"
systemctl stop x-ui
python3 - "$DOMAIN" "$SCHEME" "$TITLE" <<'PY'
import sqlite3, sys
domain, scheme = sys.argv[1], sys.argv[2]
title = sys.argv[3] if len(sys.argv) > 3 else ""
c = sqlite3.connect("/etc/x-ui/x-ui.db")

def get(k, d=""):
    r = c.execute("select value from settings where key=?", (k,)).fetchone()
    return r[0] if r and r[0] else d

def put(k, v):
    if c.execute("select 1 from settings where key=?", (k,)).fetchone():
        c.execute("update settings set value=? where key=?", (v, k))
    else:
        c.execute("insert into settings(key,value) values(?,?)", (k, v))

norm = lambda p: "/" + p.strip("/") + "/"
sp, jp, cp = (norm(get(k, d)) for k, d in (("subPath", "/sub/"), ("subJsonPath", "/json/"), ("subClashPath", "/clash/")))
put("subEnable", "true")
put("subListen", "127.0.0.1")
put("subPort", get("subPort", "2096"))
base = scheme + "://" + domain
put("subURI", base + sp)
put("subJsonURI", base + jp)
put("subClashURI", base + cp)
if title:
    put("subTitle", title)   # клиенты показывают как имя подписки (заголовок Profile-Title)
c.commit()
print(sp)
PY
systemctl start x-ui
sleep 2
systemctl is-active --quiet x-ui
EOF

  cat > "$D/f2b-ignore.sh" <<'EOF'
IP="$1"
J=/etc/fail2ban/jail.local
[ -f "$J" ] || exit 0
if grep -q '^ignoreip' "$J"; then
  grep -q "$IP" "$J" || sed -i "s|^ignoreip.*|& $IP|" "$J"
else
  sed -i "/^\[sshd\]/a ignoreip = 127.0.0.1/8 ::1 $IP" "$J"
fi
systemctl restart fail2ban >/dev/null 2>&1 || true
exit 0
EOF

  cat > "$D/helper-relay.sh" <<'EOF'
set -e
cat > /usr/local/bin/sync-sub-path <<'EOT2'
#!/usr/bin/env python3
# Берёт пути подписки из базы 3x-ui и прописывает их в nginx (xpn.conf, блок sub-paths).
# Запускается таймером каждые 15 секунд: если путь в панели изменили, nginx подхватит сам.
import re, sqlite3, subprocess, sys

DB = "/etc/x-ui/x-ui.db"
CONF = "/etc/nginx/sites-available/xpn.conf"
BEGIN, END = "    # BEGIN sub-paths\n", "    # END sub-paths\n"

try:
    txt = open(CONF).read()
except OSError:
    sys.exit(0)
if BEGIN not in txt or END not in txt:
    sys.exit(0)
try:
    c = sqlite3.connect(DB, timeout=5)

    def get(k, d):
        r = c.execute("select value from settings where key=?", (k,)).fetchone()
        return (r[0] if r and r[0] else d)

    port = get("subPort", "2096")
    paths = []
    for k, d in (("subPath", "/sub/"), ("subJsonPath", "/json/"), ("subClashPath", "/clash/")):
        p = "/" + get(k, d).strip("/") + "/"
        if p != "//" and p not in paths:
            paths.append(p)
except Exception as e:
    sys.exit("sync-sub-path: не удалось прочитать настройки панели: %s" % e)

loc = (
    "    location ^~ {p} {{\n"
    "        proxy_pass http://127.0.0.1:{port};\n"
    "        proxy_set_header Host $host;\n"
    "        proxy_set_header X-Forwarded-Proto $scheme;\n"
    "    }}\n\n"
)
block = BEGIN + "".join(loc.format(p=p, port=port) for p in paths) + END
new = re.sub(re.escape(BEGIN) + ".*?" + re.escape(END), lambda m: block, txt, flags=re.S)
if new == txt:
    sys.exit(0)
open(CONF, "w").write(new)
if subprocess.call(["nginx", "-t"], stderr=subprocess.DEVNULL) != 0:
    open(CONF, "w").write(txt)
    sys.exit("sync-sub-path: nginx -t не прошёл, изменения отменены")
subprocess.call(["systemctl", "reload", "nginx"])
print("sync-sub-path: nginx обновлён, пути подписки: " + " ".join(paths))
EOT2
chmod +x /usr/local/bin/sync-sub-path
cat > /etc/systemd/system/sync-sub-path.service <<'EOT3'
[Unit]
Description=Sync 3x-ui subscription paths into nginx

[Service]
Type=oneshot
LogLevelMax=notice
ExecStart=/usr/local/bin/sync-sub-path
EOT3
cat > /etc/systemd/system/sync-sub-path.timer <<'EOT3'
[Unit]
Description=Sync 3x-ui subscription paths into nginx every 15 seconds

[Timer]
OnBootSec=30
OnUnitActiveSec=15
AccuracySec=1s

[Install]
WantedBy=timers.target
EOT3
systemctl daemon-reload
systemctl enable --now sync-sub-path.timer >/dev/null 2>&1
cat > /usr/local/bin/chain-set-backend <<'EOT4'
#!/bin/bash
# Смена IP BACKEND: туннельный путь на RELAY принимает подключения только с этого адреса (any — без ограничения)
set -e
NEW="${1:-}"; [ -n "$NEW" ] || { echo "usage: chain-set-backend НОВЫЙ_IP_BACKEND | any"; exit 1; }
F=/etc/nginx/chain-backend.conf
if [ "$NEW" = any ]; then
  printf 'allow all;\n' > "$F"
else
  [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "неверный IP"; exit 1; }
  printf 'allow %s;\nallow 127.0.0.1;\ndeny all;\n' "$NEW" > "$F"
fi
nginx -t 2>/dev/null && systemctl reload nginx
[ -f /root/.chain-setup.conf ] && sed -i "s/^BACKEND_IP=.*/BACKEND_IP=$NEW/" /root/.chain-setup.conf
echo "BACKEND (туннельный путь): $NEW"
if [ "$NEW" != any ]; then
  echo "жду подключения моста (до 90 с)…"
  for _ in $(seq 1 45); do
    if [ "$(ss -tnH state established '( sport = :21444 )' 2>/dev/null | wc -l)" -ge 1 ]; then echo "мост подключён"; exit 0; fi
    sleep 2
  done
  /usr/local/bin/chain-incident "мост" "после chain-set-backend мост не подключился за 90 с" "новый адрес BACKEND: $NEW; проверьте, что мост запущен и соединение идёт с этого IP" >/dev/null 2>&1 || true
  echo "мост не подключился за 90 с: проверьте IP BACKEND и состояние моста (journalctl -u chain-bridge на BACKEND)"
  exit 1
fi
EOT4
chmod +x /usr/local/bin/chain-set-backend
cat > /usr/local/bin/chain-status <<'EOT5'
#!/bin/bash
# Состояние цепочки на RELAY
conf=/root/.chain-setup.conf
get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n1; }
D=$(get DOMAIN); TP=$(get TUNNEL_PATH); UP=$(get USER_PATH)
st() { systemctl is-active --quiet "$1" && echo "работает" || echo "НЕ РАБОТАЕТ"; }
echo "nginx:        $(st nginx)"
echo "3x-ui:        $(st x-ui)"
n=$(ss -tnH state established "( sport = :21444 )" 2>/dev/null | wc -l)
echo "туннель:      соединений от BACKEND: $n $([ "$n" -ge 1 ] && echo '(мост подключён)' || echo '(моста нет — проверьте chain-bridge на BACKEND)')"
echo "BACKEND:      $(get BACKEND_IP) ($(head -n1 /etc/nginx/chain-backend.conf 2>/dev/null))"
echo "Xray RELAY:   $(cat /var/lib/chain/xray-version 2>/dev/null || echo '?') (версия на BACKEND: chain-update-bridge --status)"
exp=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$D/fullchain.pem" 2>/dev/null | cut -d= -f2)
echo "сертификат:   до ${exp:-?}"
code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$D:443:127.0.0.1" "https://$D/" 2>/dev/null)
echo "сайт:         HTTP ${code:-000} (ожидается 200)"
code=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --resolve "$D:443:127.0.0.1" "https://$D/$UP/" 2>/dev/null)
echo "проба пути:   HTTP ${code:-000} для чужого запроса (ожидается 404)"
EOT5
chmod +x /usr/local/bin/chain-status
cat > /usr/local/bin/chain-test <<'EOT9'
#!/bin/bash
# Сквозная проверка цепочки на RELAY: клиент → nginx → туннель → BACKEND → интернет (настройки берутся из инбаунда пользователей VPN)
conf=/root/.chain-setup.conf
get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n1; }
D=$(get DOMAIN); UP=$(get USER_PATH)
xray=$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -n1)
[ -n "$D" ] && [ -n "$UP" ] && [ -x "$xray" ] || { echo "нет данных установки или Xray из 3x-ui"; exit 1; }
tmp=$(mktemp -d); trap 'kill $PID 2>/dev/null; rm -rf "$tmp"' EXIT
python3 - "$D" "$tmp/c.json" <<'PY' || { echo "не удалось прочитать инбаунд пользователей из базы 3x-ui"; exit 1; }
import json, sqlite3, sys
domain, out = sys.argv[1:3]
db = sqlite3.connect("/etc/x-ui/x-ui.db")
st, se = db.execute("select stream_settings, settings from inbounds where port = 21443 limit 1").fetchone()
xh = json.loads(st)["xhttpSettings"]
uid = json.loads(se)["clients"][0]["id"]
json.dump({"log": {"loglevel": "warning"},
           "inbounds": [{"listen": "127.0.0.1", "port": 21482, "protocol": "socks", "settings": {"udp": False}}],
           "outbounds": [{"protocol": "vless", "settings": {"address": "127.0.0.1", "port": 443, "id": uid, "encryption": "none"},
                          "streamSettings": {"network": "xhttp", "security": "tls",
                                             "tlsSettings": {"serverName": domain, "fingerprint": "chrome", "alpn": ["h2"]},
                                             "xhttpSettings": xh}}]}, open(out, "w"))
print("XHTTP:", json.dumps(xh, ensure_ascii=False))
PY
/usr/local/bin/chain-status
"$xray" run -c "$tmp/c.json" >"$tmp/x.log" 2>&1 </dev/null &
PID=$!
sleep 2
P=socks5h://127.0.0.1:21482
ip=$(curl -4 -s --max-time 25 -x "$P" https://api.ipify.org | tr -d '[:space:]')
g=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 -x "$P" https://www.google.com/generate_204)
echo "выходной IP цепочки: ${ip:-нет ответа} (должен быть IP BACKEND: $(get BACKEND_IP))"
echo "google generate_204: HTTP ${g:-000} (ожидается 204)"
if [ -n "$ip" ]; then echo "ИТОГ: цепочка RELAY → BACKEND работает; если в клиенте интернета нет — смотрите настройки/ссылку клиента"; else
  echo "ИТОГ: цепочка не работает"; echo "--- лог тестового клиента ---"; tail -n 15 "$tmp/x.log"; exit 1; fi
EOT9
chmod +x /usr/local/bin/chain-test
cat > /usr/local/bin/chain-site-refresh <<'EOT6'
#!/usr/bin/env python3
# Обновляет содержимое «живых» эндпоинтов сайта; набор путей выбран при установке (/etc/chain-site.endpoints), запускается таймером
import datetime, json, os, random, re, sys
try:
    domain = open("/etc/chain-site.domain").read().strip()
    eps = json.load(open("/etc/chain-site.endpoints"))
except (OSError, ValueError):
    sys.exit(0)
root = "/var/www/honeypot/" + domain
if not os.path.isdir(root):
    sys.exit(0)
name = domain.split(".")[0].capitalize()
try:
    t = re.search(r"<title>(.*?)</title>", open(root + "/index.html", encoding="utf-8").read(), re.S | re.I)
    if t:
        name = re.split(r"\s+[—|–-]\s+", t.group(1).strip())[0] or name
except OSError:
    pass
now = datetime.datetime.now(datetime.timezone.utc)
day = random.Random(now.strftime("%Y%m%d") + domain)
minute = random.Random(now.strftime("%Y%m%d%H") + str(now.minute // 5) + domain)
comps = [("Web application", 99.98), ("API", 99.96), ("Authentication", 99.99), ("Background jobs", 99.94)]
rows = [(c, u, minute.randint(38, 140)) for c, u in comps]
bars = "".join('<i class="%s"></i>' % ("w" if day.random() < 0.03 else "g") for _ in range(90))
html = """<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>%(n)s — System status</title><style>body{font:16px/1.5 system-ui,sans-serif;margin:0;background:#f6f7f9;color:#1b1f24}
main{max-width:720px;margin:40px auto;padding:0 20px}h1{font-size:24px;margin:0 0 4px}.ok{color:#1a7f37;font-weight:600}
.card{background:#fff;border:1px solid #e3e6ea;border-radius:10px;padding:6px 18px;margin:18px 0}
.r{display:flex;justify-content:space-between;padding:12px 0;border-bottom:1px solid #eef0f2}.r:last-child{border:0}.s{color:#6a737d;font-size:14px}
.b{display:flex;gap:2px;height:30px;margin-top:10px}.b i{flex:1;border-radius:2px}.g{background:#2da44e}.w{background:#d4a72c}
small{color:#6a737d}</style></head><body><main><h1>%(n)s Status</h1><div class="ok">All systems operational</div>
<div class="card">%(rows)s</div><div class="card"><div class="r"><span>Uptime — last 90 days</span><span class="s">99.97%%</span></div>
<div class="b">%(bars)s</div><p><small>Updated %(t)s UTC</small></p></div></main></body></html>
""" % {"n": name, "t": now.strftime("%Y-%m-%d %H:%M"), "bars": bars,
       "rows": "".join('<div class="r"><span>%s</span><span class="s">%.2f%% · %d ms</span></div>' % (c, u, ms) for c, u, ms in rows)}
site = random.Random(domain)   # значения, стабильные для этого сайта
svc = domain.split(".")[0]
ver = "%d.%d.%d" % (site.randint(1, 4), site.randint(0, 19), site.randint(0, 9))
build = "%07x" % site.getrandbits(28)
start = datetime.datetime(2025, 1, 1, tzinfo=datetime.timezone.utc) + datetime.timedelta(days=site.randint(0, 400))
up = int((now - start).total_seconds())
ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")
expires = (now + datetime.timedelta(days=365)).strftime("%Y-%m-%dT00:00:00.000Z")
bodies = {
    # Health
    "health_json": json.dumps({
        "status": "ok",
        "service": svc,
        "version": ver,
        "uptime_seconds": up,
        "timestamp": ts
    }),

    # Status
    "status_json": json.dumps({
        "status": "operational",
        "components": [
            {"name": c, "status": "operational", "latency_ms": ms}
            for c, u, ms in rows
        ],
        "updated_at": ts
    }),

    # Ping
    "ping_json": json.dumps({
        "pong": True,
        "time": int(now.timestamp())
    }),

    # Version
    "version_json": json.dumps({
        "name": svc,
        "version": ver,
        "build": build
    }),

    # Ready
    "ready_json": json.dumps({
        "ready": True
    }),

    # Info
    "info_json": json.dumps({
        "service": svc,
        "version": ver,
        "build": build,
        "status": "operational",
        "components": len(rows),
        "updated_at": ts
    }),

    # Uptime
    "uptime_json": json.dumps({
        "service": svc,
        "uptime_seconds": up,
        "started_at": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "updated_at": ts
    }),

    # Prometheus metrics
    "metrics_text": "\n".join(
        [
            "# HELP process_uptime_seconds Process uptime in seconds",
            "# TYPE process_uptime_seconds gauge",
            "process_uptime_seconds %d" % up,
            "# HELP service_component_latency_ms Component response latency",
            "# TYPE service_component_latency_ms gauge",
        ] + [
            'service_component_latency_ms{component="%s"} %d' %
            (c.lower().replace(" ", "_"), ms)
            for c, u, ms in rows
        ]
    ) + "\n",

    # Text responses
    "text_ok": "OK\n",
    "text_pong": "pong\n",

    # Standard files
    "robots": "User-agent: *\nDisallow: /api/\nDisallow: /admin/\n",

    "security": (
        "Contact: mailto:security@%s\n"
        "Expires: %s\n"
        "Preferred-Languages: en\n"
    ) % (domain, expires),

    # HTML status page
    "status_html": html,
}
os.makedirs(root + "/.ep", exist_ok=True)
for e in eps:
    body = bodies.get(e.get("kind"))
    if body is None or not re.fullmatch(r"[0-9a-f]{12}", str(e.get("id", ""))):
        continue
    fn = root + "/.ep/" + e["id"]
    open(fn + ".tmp", "w", encoding="utf-8").write(body)
    os.replace(fn + ".tmp", fn)
EOT6
chmod +x /usr/local/bin/chain-site-refresh
cat > /etc/systemd/system/chain-site-refresh.service <<'EOT7'
[Unit]
Description=Refresh status pages of the site

[Service]
Type=oneshot
ExecStart=/usr/local/bin/chain-site-refresh
EOT7
cat > /etc/systemd/system/chain-site-refresh.timer <<'EOT7'
[Unit]
Description=Refresh status pages every 5 minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=300

[Install]
WantedBy=timers.target
EOT7
# версия Xray на RELAY: мост BACKEND читает её (nginx отдаёт файл только с IP BACKEND) и подтягивает такую же
mkdir -p /var/lib/chain
cat > /usr/local/bin/chain-xray-version <<'EOT8'
#!/bin/bash
# Записывает версию Xray из 3x-ui в /var/lib/chain/xray-version
x=$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -n1)
[ -x "$x" ] || exit 0
v=$("$x" version 2>/dev/null | awk 'NR==1{print $2}')
[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 0
mkdir -p /var/lib/chain
printf '%s\n' "$v" > /var/lib/chain/xray-version.tmp && mv -f /var/lib/chain/xray-version.tmp /var/lib/chain/xray-version
chmod 644 /var/lib/chain/xray-version
EOT8
chmod +x /usr/local/bin/chain-xray-version
cat > /etc/systemd/system/chain-xray-version.service <<'EOT8'
[Unit]
Description=Publish Xray version for the bridge

[Service]
Type=oneshot
ExecStart=/usr/local/bin/chain-xray-version
EOT8
cat > /etc/systemd/system/chain-xray-version.path <<'EOT8'
[Unit]
Description=Publish Xray version when 3x-ui updates the core

[Path]
PathChanged=/usr/local/x-ui/bin
Unit=chain-xray-version.service

[Install]
WantedBy=multi-user.target
EOT8
systemctl daemon-reload
systemctl disable --now chain-xray-version.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/chain-xray-version.timer
systemctl enable --now chain-site-refresh.timer chain-xray-version.path >/dev/null 2>&1
/usr/local/bin/chain-xray-version || true
EOF


  # сетевые твики на BACKEND (та же функция, что и на RELAY)
  { declare -f tune_network; echo 'tune_network "$@"'; } > "$D/tune.sh"

  # RELAY: финальный конфиг nginx (сайт, панель, секретные пути, «живые» эндпоинты)
  cat > "$D/nginx-final.py" <<'PYEOF'
import os, re, subprocess, sys

domain, xui_path, upath, tpath, uport, tport, backend = sys.argv[1:8]
xui_path = xui_path.strip("/")
hide_panel = len(sys.argv) > 8 and sys.argv[8] == "1"   # 1 — панель не публикуется через nginx (только SSH-туннель)
v6 = os.path.exists("/proc/net/if_inet6") and open("/proc/sys/net/ipv6/conf/all/disable_ipv6").read().strip() == "0"
ver = subprocess.run(["nginx", "-v"], capture_output=True, text=True).stderr
m = re.search(r"nginx/(\d+)\.(\d+)\.(\d+)", ver)
newer = tuple(int(x) for x in m.groups()) >= (1, 25, 1) if m else False

if newer:
    listen_ssl = "listen 443 ssl default_server so_keepalive=60s:15s:4;\n" + ("    listen [::]:443 ssl default_server so_keepalive=60s:15s:4;\n" if v6 else "") + "    http2 on;"
else:
    listen_ssl = "listen 443 ssl http2 default_server so_keepalive=60s:15s:4;" + ("\n    listen [::]:443 ssl http2 default_server so_keepalive=60s:15s:4;" if v6 else "")
listen_80 = "listen 80 default_server;" + ("\n    listen [::]:80 default_server;" if v6 else "")

try:
    os.remove("/etc/nginx/sites-enabled/default")   # иначе два default_server на портах 80/443
except OSError:
    pass
os.makedirs("/etc/nginx/snippets", exist_ok=True)
os.makedirs("/etc/nginx/conf.d", exist_ok=True)
os.makedirs("/var/www/certbot", exist_ok=True)

open("/etc/nginx/snippets/chain-headers.conf", "w").write(
    'add_header X-Content-Type-Options "nosniff" always;\n'
    'add_header X-Frame-Options "SAMEORIGIN" always;\n'
    'add_header Referrer-Policy "strict-origin-when-cross-origin" always;\n'
    'add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;\n'
    'add_header X-Request-ID $request_id always;\n')
open("/etc/nginx/conf.d/chain-limit.conf", "w").write(
    "limit_req_zone $binary_remote_addr zone=chain_site:10m rate=10r/s;\nlimit_req_status 429;\n"
    "# окно приёма HTTP/2 на поток (по умолчанию 64k): скорость одного потока ≈ окно / RTT: при 60 мс 64k даёт около 1 МБ/с, 1m около 16 МБ/с (4m расходовали память nginx: фрагментация heap)\n"
    "http2_body_preread_size 1m;\n"
    "keepalive_requests 100000;\n")
if not os.path.exists("/etc/nginx/chain-backend.conf"):
    open("/etc/nginx/chain-backend.conf", "w").write(
        "allow all;\n" if backend == "any" else "allow %s;\nallow 127.0.0.1;\ndeny all;\n" % backend)

tpl = r"""server {
    @@LISTEN80@@
    server_name @@DOMAIN@@;
    server_tokens off;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://@@DOMAIN@@$request_uri;
    }
}

server {
    @@LISTENSSL@@
    server_name @@DOMAIN@@;

    ssl_certificate     /etc/letsencrypt/live/@@DOMAIN@@/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/@@DOMAIN@@/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    server_tokens off;
    access_log off;
    include /etc/nginx/snippets/chain-headers.conf;

    root /var/www/honeypot/@@DOMAIN@@;
    index index.html;
    error_page 404 /404.html;
    location = /404.html { internal; }

    # BEGIN sub-paths
    # END sub-paths

    # Канал пользователей (VLESS + XHTTP): только HTTP/2 и только точный секретный путь, остальное — 404.
    # Таймауты большие намеренно: поток «скачивания» XHTTP молчит, пока идёт долгая загрузка, и короткий
    # grpc_read_timeout рвал такие загрузки; «мёртвые» соединения закрывает so_keepalive на listen.
    location ^~ /@@UPATH@@/ {
        if ($server_protocol != "HTTP/2.0") { return 404; }
        limit_except GET POST { deny all; }
        client_max_body_size 0;
        client_body_timeout 24h;
        grpc_read_timeout 24h;
        grpc_send_timeout 24h;
        grpc_set_header Host $host;
        grpc_intercept_errors on;
        error_page 400 401 403 405 =404 /404.html;
        grpc_pass grpc://127.0.0.1:@@UPORT@@;
    }

    # Туннель: сюда сам подключается мост BACKEND; другим адресам — 404
    location ^~ /@@TPATH@@/ {
        if ($server_protocol != "HTTP/2.0") { return 404; }
        include /etc/nginx/chain-backend.conf;
        error_page 403 =404 /404.html;
        client_max_body_size 0;
        client_body_timeout 24h;
        grpc_read_timeout 24h;
        grpc_send_timeout 24h;
        grpc_set_header Host $host;
        grpc_pass grpc://127.0.0.1:@@TPORT@@;
    }

    # Версия Xray для синхронизации моста BACKEND (доступна только с IP BACKEND)
    location = /@@VPATH@@/ {
        include /etc/nginx/chain-backend.conf;
        error_page 403 =404 /404.html;
        default_type text/plain;
        add_header Cache-Control "no-store" always;
        # root+try_files: alias на файл без «/» давал 500 из-за обработчика index (…xray-versionindex.html)
        root /var/lib/chain;
        try_files /xray-version =404;
    }

    # Панель 3x-ui по отдельному пути
    location = /@@XUI@@ { return 301 /@@XUI@@/; }
    location ^~ /@@XUI@@/ {
        limit_req zone=chain_site burst=60 nodelay;
        proxy_pass http://127.0.0.1:999;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # «Живой» сайт: эндпоинты (случайный набор, выбран при установке)
@@ENDPOINTS@@
    location ^~ /api/ {
        limit_req zone=chain_site burst=30 nodelay;
        default_type application/json;
        include /etc/nginx/snippets/chain-headers.conf;
        add_header WWW-Authenticate 'Bearer realm="api"' always;
        return 401 '{"error":"unauthorized","message":"Missing or invalid API key"}';
    }

    location ~ /\.(?!well-known) { return 404; }
    location / {
        limit_req zone=chain_site burst=30 nodelay;
        try_files $uri $uri/ =404;
    }
}
"""
import json
vpath = sys.argv[9] if len(sys.argv) > 9 else "x"
CT = {
    "health_json": "application/json",
    "status_json": "application/json",
    "ping_json": "application/json",
    "version_json": "application/json",
    "ready_json": "application/json",
    "info_json": "application/json",
    "uptime_json": "application/json",
    "metrics_text": "text/plain",
    "text_ok": "text/plain",
    "text_pong": "text/plain",
    "robots": "text/plain",
    "security": "text/plain",
    "status_html": "text/html"
}
blocks = []
try:
    eps = json.load(open("/etc/chain-site.endpoints"))
except (OSError, ValueError):
    eps = []
for e in eps:
    if e.get("kind") not in CT or not re.fullmatch(r"[0-9a-f]{12}", str(e.get("id", ""))) or not re.fullmatch(r"/[A-Za-z0-9._/-]+", str(e.get("path", ""))):
        continue
    for q in ([e["path"], e["path"] + "/"] if e["kind"] == "status_html" else [e["path"]]):
        blocks.append("    location = %s {\n        limit_req zone=chain_site burst=30 nodelay;\n        default_type %s;\n"
                      "        include /etc/nginx/snippets/chain-headers.conf;\n        add_header Cache-Control \"no-store\" always;\n"
                      "        try_files /.ep/%s =404;\n    }\n" % (q, CT[e["kind"]], e["id"]))
conf = (tpl.replace("@@ENDPOINTS@@", "".join(blocks)).replace("@@VPATH@@", vpath).replace("@@LISTEN80@@", listen_80).replace("@@LISTENSSL@@", listen_ssl)
        .replace("@@DOMAIN@@", domain).replace("@@UPATH@@", upath).replace("@@TPATH@@", tpath)
        .replace("@@UPORT@@", uport).replace("@@TPORT@@", tport).replace("@@XUI@@", xui_path))
if hide_panel:
    conf = re.sub(r"    # Панель 3x-ui по отдельному пути\n.*?(?=    # «Живой» сайт)", "", conf, flags=re.S)
    assert "proxy_pass http://127.0.0.1:999;" not in conf, "панель не удалена из конфига nginx"
open("/etc/nginx/sites-available/xpn.conf", "w").write(conf)
for old in ("/etc/nginx/sites-enabled/apex.conf", "/etc/nginx/sites-available/apex.conf"):   # прежнее имя конфига
    try:
        os.remove(old)
    except OSError:
        pass
if not os.path.islink("/etc/nginx/sites-enabled/xpn.conf"):
    try:
        os.symlink("/etc/nginx/sites-available/xpn.conf", "/etc/nginx/sites-enabled/xpn.conf")
    except FileExistsError:
        pass
if subprocess.call(["nginx", "-t"]) != 0:
    sys.exit("nginx -t не прошёл")
subprocess.check_call(["systemctl", "reload", "nginx"])
subprocess.call(["systemctl", "enable", "--now", "certbot.timer"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for f in ("/etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh", "/etc/letsencrypt/renewal-hooks/post/start-nginx.sh"):
    try:
        os.remove(f)
    except OSError:
        pass
PYEOF

  # RELAY: инбаунды 3x-ui через API (пользователи + туннель с reverse) и маршрутизация «пользователи → туннель»
  cat > "$D/chain-inbounds.py" <<'PYEOF'
import json, os, secrets, string, sys, urllib.parse, urllib.request, uuid

base, token, domain, upath, tpath, uport, tport = sys.argv[1:8]
uport, tport = int(uport), int(tport)
tunnel_obfs = len(sys.argv) > 8 and sys.argv[8] == "1"   # padding-обфускация на туннеле BACKEND → RELAY


def api(path, body=None, form=None, method=None):
    if body is not None:
        data, ctype = json.dumps(body).encode(), "application/json"
    elif form is not None:
        data, ctype = urllib.parse.urlencode(form).encode(), "application/x-www-form-urlencoded"
    else:
        data, ctype = None, "application/json"
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Authorization": "Bearer " + token, "Content-Type": ctype})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def stream(path, ext=None, obfs=False, xmux=False, mode=None):
    # пользователям — packet-up (параллельные HTTP-запросы: высокая скорость загрузки и устойчивость при больших файлах)
    xh = {"path": "/" + path + "/", "host": domain, "mode": mode or ("packet-up" if xmux else "auto"), "xPaddingBytes": "100-1000"}
    if obfs:
        # padding-обфускация: оба конца (RELAY и мост) наши, поэтому клиентские приложения не затрагиваются
        xh.update({"xPaddingObfsMode": True, "xPaddingKey": "_dc", "xPaddingHeader": "X-Cache", "xPaddingMethod": "tokenish"})
    if xmux:
        # ротация соединений у клиентов (попадает в ссылку подписки через extra).
        # hKeepAlivePeriod: через столько секунд клиент проверяет «зависшее» соединение (+15 с ожидания ответа),
        # то есть это и есть время до восстановления после обрыва: не увеличивать
        xh["xmux"] = {"maxConnections": int(os.environ.get("XMUX_CONNECTIONS", "2")), "hMaxRequestTimes": "600-900", "hMaxReusableSecs": "1800-3000", "hKeepAlivePeriod": 20}
        xh["scMaxEachPostBytes"] = "1200000-2000000"   # размер POST (серверу нужен лимит не меньше, иначе крупные POST отвергаются)
        xh["scMinPostsIntervalMs"] = "8-14"            # пауза между POST: 30 мс по умолчанию ограничивает отдачу примерно 200 Мбит/с
    s = {"network": "xhttp", "security": "none", "xhttpSettings": xh}
    if ext:
        s["externalProxy"] = ext
    return json.dumps(s)


# панель после перезапуска отвечает не сразу
import time
for _ in range(60):
    try:
        api("/panel/api/inbounds/list")
        break
    except Exception:
        time.sleep(1)
else:
    sys.exit("API панели не отвечает")

sniff = json.dumps({"enabled": False, "destOverride": ["http", "tls"], "metadataOnly": False, "routeOnly": False})
alnum = string.ascii_lowercase + string.digits
existing = {i.get("remark"): i for i in (api("/panel/api/inbounds/list").get("obj") or [])}
# инбаунды прежней установки (с другими именами) находим по порту и переиспользуем как есть
by_port = {i.get("port"): i for i in (api("/panel/api/inbounds/list").get("obj") or [])}
users_inb = existing.get("VPN") or by_port.get(uport)
tunnel_inb = existing.get("TUNNEL") or by_port.get(tport)


def first_client(inb):
    s = inb.get("settings")
    s = json.loads(s) if isinstance(s, str) else s
    return s["clients"][0]


# пользователи: VLESS + XHTTP, TLS снаружи (nginx); во внешней ссылке/подписке — домен:443 с TLS
if users_inb:
    c = first_client(users_inb)
    user_id, sub_id = c["id"], c.get("subId", "")
else:
    user_id, sub_id = str(uuid.uuid4()), "".join(secrets.choice(alnum) for _ in range(16))
    settings = {"clients": [{"id": user_id, "email": "User", "flow": "", "limitIp": 0, "totalGB": 0, "expiryTime": 0,
                             "enable": True, "subId": sub_id, "comment": "", "reset": 0}],
                "decryption": "none", "fallbacks": []}
    ext = [{"forceTls": "tls", "dest": domain, "port": 443, "remark": "", "sni": domain,
            "fingerprint": "chrome", "alpn": ["h2"]}]
    r = api("/panel/api/inbounds/add", body={"remark": "VPN", "enable": True, "listen": "127.0.0.1", "port": uport,
                                             "protocol": "vless", "settings": json.dumps(settings),
                                             "streamSettings": stream(upath, ext, False, True), "sniffing": sniff, "tag": "VPN"})
    if not r.get("success"):
        sys.exit("не удалось создать инбаунд пользователей: %s" % r.get("msg"))

# туннель: клиент с reverse-тегом; в подписки не попадает
if tunnel_inb:
    tunnel_id = first_client(tunnel_inb)["id"]
    # инбаунд уже есть: мост должен получить ровно те же настройки padding, что стоят на нём
    try:
        ss = tunnel_inb.get("streamSettings")
        ss = json.loads(ss) if isinstance(ss, str) else ss
        tunnel_obfs = bool(ss["xhttpSettings"].get("xPaddingObfsMode"))
    except Exception:
        tunnel_obfs = False
else:
    tunnel_id = str(uuid.uuid4())
    settings = {"clients": [{"id": tunnel_id, "email": "TUNNEL", "flow": "", "limitIp": 0, "totalGB": 0, "expiryTime": 0,
                             "enable": True, "subId": "".join(secrets.choice(alnum) for _ in range(16)), "comment": "",
                             "reset": 0, "reverse": {"tag": "r-tunnel"}}],
                "decryption": "none", "fallbacks": []}
    r = api("/panel/api/inbounds/add", body={"remark": "TUNNEL", "enable": True, "listen": "127.0.0.1", "port": tport,
                                             "protocol": "vless", "settings": json.dumps(settings),
                                             "streamSettings": stream(tpath, None, tunnel_obfs, mode="stream-up"), "sniffing": sniff, "tag": "TUNNEL",
                                             "excludeFromSub": True})
    if not r.get("success"):
        sys.exit("не удалось создать инбаунд туннеля: %s" % r.get("msg"))

# актуальный тег инбаунда пользователей (панель могла присвоить свой, если запрошенный занят)
inb_now = api("/panel/api/inbounds/list").get("obj") or []
users_tag = next((i.get("tag") for i in inb_now if i.get("port") == uport), None) or "VPN"

# маршрутизация: всё из инбаунда пользователей — только в туннель (если моста нет, соединение сбрасывается, прямого выхода с RELAY нет)
r = api("/panel/api/xray/", form={})
o = r["obj"]
o = json.loads(o) if isinstance(o, str) else o
xs = o["xraySetting"]
xs = json.loads(xs) if isinstance(xs, str) else xs
rules = xs.setdefault("routing", {}).setdefault("rules", [])
rule = {"type": "field", "inboundTag": [users_tag], "outboundTag": "r-tunnel"}
if rule not in rules:
    idx = 0
    for i, x in enumerate(rules):
        if x.get("outboundTag") in ("api", "blocked"):
            idx = i + 1
    rules.insert(idx, rule)
    r = api("/panel/api/xray/update", form={"xraySetting": json.dumps(xs), "outboundTestUrl": "https://www.google.com/generate_204"})
    if not r.get("success"):
        sys.exit("не удалось сохранить маршрутизацию: %s" % r.get("msg"))

print(json.dumps({"user_id": user_id, "sub_id": sub_id, "tunnel_id": tunnel_id, "tunnel_obfs": 1 if tunnel_obfs else 0}))
PYEOF

  # RELAY: случайный набор «живых» эндпоинтов сайта (создаётся только при установке)
  cat > "$D/site-endpoints.py" <<'PYEOF'
import json, os, random, secrets
POOL = [
    # Health — состояние приложения
    ("/health", "health_json"),
    ("/healthz", "text_ok"),
    ("/livez", "text_ok"),
    ("/readyz", "text_ok"),
    ("/live", "text_ok"),
    ("/api/health", "health_json"),
    ("/api/v1/health", "health_json"),
    ("/api/v2/health", "health_json"),
    ("/v1/health", "health_json"),
    ("/service/health", "health_json"),
    ("/api/ready", "ready_json"),
    ("/api/v1/ready", "ready_json"),
    ("/api/live", "ready_json"),

    # Status — состояние компонентов
    ("/status", "status_html"),
    ("/status/summary", "status_html"),
    ("/api/status", "status_json"),
    ("/api/v1/status", "status_json"),
    ("/api/v2/status", "status_json"),
    ("/v1/status", "status_json"),
    ("/service/status", "status_json"),

    # Ping — проверка доступности
    ("/ping", "text_pong"),
    ("/api/ping", "ping_json"),
    ("/api/v1/ping", "ping_json"),
    ("/api/v2/ping", "ping_json"),
    ("/v1/ping", "ping_json"),

    # Version / Build — сведения о версии
    ("/version", "version_json"),
    ("/api/version", "version_json"),
    ("/api/v1/version", "version_json"),
    ("/api/v2/version", "version_json"),
    ("/v1/version", "version_json"),
    ("/build", "version_json"),
    ("/api/build", "version_json"),

    # Info — сведения о приложении
    ("/info", "info_json"),
    ("/api/info", "info_json"),
    ("/api/v1/info", "info_json"),
    ("/v1/info", "info_json"),

    # Uptime — время работы
    ("/uptime", "uptime_json"),
    ("/api/uptime", "uptime_json"),
    ("/v1/uptime", "uptime_json"),

    # Metrics — метрики приложения
    ("/metrics", "metrics_text"),
    ("/metrics/prometheus", "metrics_text"),
    ("/api/metrics", "metrics_text"),
    ("/api/v1/metrics", "metrics_text"),

    # Стандартные служебные файлы
    ("/robots.txt", "robots"),
    ("/.well-known/security.txt", "security"),
]
rnd = random.SystemRandom()
while True:
    pick = rnd.sample(POOL, rnd.randint(2, 5))
    if len({k for _, k in pick}) >= 2:   # разные форматы ответов
        break
eps = [{"path": p, "kind": k, "id": secrets.token_hex(6)} for p, k in pick]
json.dump(eps, open("/etc/chain-site.endpoints", "w"))
os.chmod("/etc/chain-site.endpoints", 0o644)
print(", ".join(p for p, _ in pick))
PYEOF

  # BACKEND: мост Xray (обратный туннель к RELAY)
  cat > "$D/bridge-install.sh" <<'EOF'
set -Eeuo pipefail
RELAY="$1"; DOMAIN="$2"; TPATH="$3"; TUUID="$4"; VPATH="${5:-}"; TOBFS="${6:-0}"; XRAYV="${7:-}"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
case "$(uname -m)" in
  x86_64 | amd64) ARCH=64 ;;
  aarch64 | arm64) ARCH=arm64-v8a ;;
  *) echo "неподдерживаемая архитектура: $(uname -m)" >&2; exit 1 ;;
esac
need=()
for c in curl unzip python3 sha256sum; do command -v "$c" >/dev/null 2>&1 || need+=("$c"); done
if [ ${#need[@]} -gt 0 ]; then
  apt-get -o DPkg::Lock::Timeout=300 update -qq
  apt-get -o DPkg::Lock::Timeout=300 install -y curl unzip python3 coreutils ca-certificates
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -n "$XRAYV" ]; then URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAYV#v}/Xray-linux-$ARCH.zip"; else URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$ARCH.zip"; fi
curl -fsSL --retry 3 -o "$tmp/x.zip" "$URL"
curl -fsSL --retry 3 -o "$tmp/x.dgst" "$URL.dgst"
want=$(sed -n 's/^SHA2-256= *//p' "$tmp/x.dgst" | head -n1 | tr -d '[:space:]')
have=$(sha256sum "$tmp/x.zip" | awk '{ print $1 }')
[ -n "$want" ] && [ "$want" = "$have" ] || { echo "контрольная сумма Xray не совпала" >&2; exit 1; }
unzip -oq "$tmp/x.zip" xray -d "$tmp"
install -m 755 "$tmp/xray" /usr/local/bin/chain-xray
id chainbridge >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin chainbridge
mkdir -p /etc/chain-bridge
python3 - "$RELAY" "$DOMAIN" "$TPATH" "$TUUID" "$TOBFS" <<'PY'
import json, re, subprocess, sys
relay, domain, tpath, tuuid, tobfs = sys.argv[1:6]
cfg = {
    "log": {"loglevel": "warning", "access": "none"},
    "outbounds": [
        {"tag": "tunnel", "protocol": "vless",
         "settings": {"address": relay, "port": 443, "id": tuuid, "encryption": "none", "reverse": {"tag": "r-in"}},
         "streamSettings": {"network": "xhttp", "security": "tls",
                            "tlsSettings": {"serverName": domain, "fingerprint": "chrome", "alpn": ["h2"]},
                            "xhttpSettings": {"host": domain, "path": "/" + tpath + "/", "mode": "stream-up", "xPaddingBytes": "100-1000",
                                            # keepalive HTTP/2 (PING раз в ~15 с): без него молча умершее соединение мост замечает только через минуты
                                            "xmux": {"hKeepAlivePeriod": 15}}}},
        # ВАЖНО: без явных finalRules Xray блокирует весь трафик reverse-моста (vless-reverse) на 30–90 с.
        # geoip:private не используем — ему нужен geoip.dat, а на BACKEND ставится только бинарник xray.
        {"tag": "direct", "protocol": "freedom",
         "settings": {"finalRules": [
             {"action": "block", "ip": ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
                                        "172.16.0.0/12", "192.0.0.0/24", "192.168.0.0/16", "198.18.0.0/15",
                                        "224.0.0.0/4", "240.0.0.0/4", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"]},
             {"action": "allow"}]}},
    ],
    "routing": {"rules": [{"type": "field", "inboundTag": ["r-in"], "outboundTag": "direct"}]},
}
if tobfs == "1":   # те же параметры padding, что на инбаунде туннеля у RELAY
    cfg["outbounds"][0]["streamSettings"]["xhttpSettings"].update(
        {"xPaddingObfsMode": True, "xPaddingKey": "_dc", "xPaddingHeader": "X-Cache", "xPaddingMethod": "tokenish"})
# свои публичные адреса BACKEND — в список запретов выхода (через туннель нельзя обращаться к самому серверу по его внешнему IP)
own = []
for fam, flag, plen in (("inet", "-4", 32), ("inet6", "-6", 128)):
    out = subprocess.run(["ip", "-o", flag, "addr", "show", "scope", "global"], capture_output=True, text=True).stdout
    own += ["%s/%d" % (m.group(1), plen) for m in re.finditer(r"\b%s\s+([0-9a-fA-F:.]+)/\d+" % fam, out)]
cfg["outbounds"][1]["settings"]["finalRules"][0]["ip"] += own
json.dump(cfg, open("/etc/chain-bridge/config.json", "w"), indent=2)
PY
chown -R root:chainbridge /etc/chain-bridge
chmod 750 /etc/chain-bridge; chmod 640 /etc/chain-bridge/config.json
/usr/local/bin/chain-xray run -test -c /etc/chain-bridge/config.json
# параметры синхронизации версии Xray с RELAY
cat > /etc/chain-bridge/sync.conf <<EOT
RELAY_IP=$RELAY
DOMAIN=$DOMAIN
VPATH=$VPATH
EOT
chmod 600 /etc/chain-bridge/sync.conf
cat > /etc/systemd/system/chain-bridge.service <<'EOT'
[Unit]
Description=chain bridge (Xray reverse tunnel to RELAY)
After=network-online.target
Wants=network-online.target

[Service]
User=chainbridge
Group=chainbridge
ExecStart=/usr/local/bin/chain-xray run -c /etc/chain-bridge/config.json
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOT
systemctl disable --now chain-update-bridge.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/chain-update-bridge.service /etc/systemd/system/chain-update-bridge.timer /etc/chain-bridge/autosync
systemctl daemon-reload
systemctl enable chain-bridge >/dev/null 2>&1
systemctl restart chain-bridge
sleep 3
systemctl is-active --quiet chain-bridge
EOF

  # RELAY: chain-health (состояние цепочки, счётчик соединений, перезапуск моста по SSH-ключу), автотест после перезагрузки, проверка сертификата; убирает путь /health, чинит путь версии Xray
  cat > "$D/health-relay.sh" <<'__CHAIN_EOF__'
set -Eeuo pipefail
VPATH="${1:?не передан секретный путь версии}"
F=/etc/nginx/sites-available/xpn.conf
[ -f "$F" ] || { echo "нет $F: сначала настройте канал" >&2; exit 1; }
mkdir -p /var/lib/chain
cat > /usr/local/bin/chain-health <<'EOT_H'
#!/bin/bash
# chain-health — состояние цепочки на RELAY (запускается таймером chain-health.timer раз в 30 с).
# Пишет /var/lib/chain/health (соединения моста, сквозная проверка), считает новые соединения в минуту (nginx stub_status, без адресов клиентов),
# записывает сбои в /var/log/chain-incidents.log и, если мост пропал, просит BACKEND перезапустить его по SSH
# (отдельный ключ /root/.ssh/chain-restart; на BACKEND он разрешает только одну команду — перезапуск моста).
#   chain-health          обновить состояние
#   chain-health --show   показать состояние (его выводит и chain-status)
H=${CHAIN_HEALTH_FILE:-/var/lib/chain/health}
ST=${CHAIN_HEALTH_STATE:-/var/lib/chain/state}
MET=${CHAIN_HEALTH_METRICS:-/var/lib/chain/metrics}
conf=${CHAIN_SETUP_CONF:-/root/.chain-setup.conf}
now=${CHAIN_HEALTH_NOW:-$(date +%s)}
RKEY=${CHAIN_RESTART_KEY:-/root/.ssh/chain-restart}
STATUS_URL=${CHAIN_STATUS_URL:-http://127.0.0.1:21480/nginx_status}
get() { sed -n "s/^$1=//p" "$conf" 2>/dev/null | head -n1; }
kv() { sed -n "s/^$1=//p" "$H" 2>/dev/null | head -n1; }
sv() { sed -n "s/^$1=//p" "$ST" 2>/dev/null | head -n1; }
setst() { { grep -v "^$1=" "$ST" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2"; } > "$ST.tmp" && mv -f "$ST.tmp" "$ST"; }
inc() { /usr/local/bin/chain-incident "$@" >/dev/null 2>&1 || true; }
MARK=${CHAIN_MARKER_FILE:-/root/.chain-setup.installed}
mget() { sed -n "s/^$1=//p" "$MARK" 2>/dev/null | head -n1; }
mset() { [ -f "$MARK" ] || return 0; if grep -q "^$1=" "$MARK"; then sed -i "s|^$1=.*|$1=$2|" "$MARK"; else printf '%s=%s\n' "$1" "$2" >> "$MARK"; fi; }
if [ "${1:-}" = "--show" ]; then
  if [ ! -r "$H" ]; then echo "сторож:       данных нет (chain-health ещё не запускался)"; exit 0; fi
  ts=$(kv ts); c=$(kv conns); e=$(kv e2e); et=$(kv e2e_ts)
  echo "сторож:       проверено $((now - ${ts:-0})) с назад; соединений моста: ${c:-?}; сквозная проверка: ${e:-?} ($((now - ${et:-0})) с назад)"
  [ -s "$MET" ] && tail -n 20 "$MET" | awk '{s+=$3;n++;a=$4} END{if(n) printf "нагрузка:      новых соединений в минуту: %.1f (среднее за %d замеров), активных сейчас: %s\n", s/n, n, a}'
  xv=$(mget XRAY_VERSION); pv=$(mget PEER_XRAY_VERSION); ps=$(mget PEER_XRAY_SEEN)
  if [ -n "$xv" ] && [ -n "$pv" ] && [ "$xv" != "$pv" ]; then
    pd=""; [[ "$ps" =~ ^[0-9]+$ ]] && pd=" (проверено при запуске скрипта $(date -d "@$ps" '+%F %H:%M'))"
    echo "Xray:         ▲ версии различаются: RELAY $xv, BACKEND $pv$pd; выберите «Обновить Xray» в меню скрипта"
  fi
  if [ -s /var/log/chain-incidents.log ]; then echo "сбои (3 последних, всё: chain-incident --show):"; tail -n 3 /var/log/chain-incidents.log | sed 's/^/  /'; else echo "сбои:         записей нет"; fi
  exit 0
fi
mkdir -p "$(dirname "$H")"
exec 9>"${CHAIN_HEALTH_LOCK:-/run/chain-health.lock}"; flock -n 9 || exit 0

# сквозная проверка: 0 — прошла, 1 — не прошла, 2 — нет условий (nginx/3x-ui не работают, нет данных)
e2e_probe() {
  local D xray tmp pid port=21483 code ip
  D=$(get DOMAIN)
  xray=$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -n1)
  [ -n "$D" ] && [ -x "$xray" ] || return 2
  systemctl is-active --quiet nginx && systemctl is-active --quiet x-ui || return 2
  ss -tlnH "( sport = :21443 )" 2>/dev/null | grep -q . || return 2
  tmp=$(mktemp -d)
  python3 - "$D" "$tmp/c.json" "$port" <<'PY' || { rm -rf "$tmp"; return 2; }
import json, sqlite3, sys
domain, out, port = sys.argv[1:4]
db = sqlite3.connect("/etc/x-ui/x-ui.db")
st, se = db.execute("select stream_settings, settings from inbounds where port = 21443 limit 1").fetchone()
xh = json.loads(st)["xhttpSettings"]
uid = json.loads(se)["clients"][0]["id"]
json.dump({"log": {"loglevel": "none"},
           "inbounds": [{"listen": "127.0.0.1", "port": int(port), "protocol": "socks", "settings": {"udp": False}}],
           "outbounds": [{"protocol": "vless", "settings": {"address": "127.0.0.1", "port": 443, "id": uid, "encryption": "none"},
                          "streamSettings": {"network": "xhttp", "security": "tls",
                                             "tlsSettings": {"serverName": domain, "fingerprint": "chrome", "alpn": ["h2"]},
                                             "xhttpSettings": xh}}]}, open(out, "w"))
PY
  "$xray" run -c "$tmp/c.json" >/dev/null 2>&1 </dev/null &
  pid=$!
  sleep 2
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -x "socks5h://127.0.0.1:$port" https://www.google.com/generate_204 2>/dev/null)
  ip=""
  [ "$code" = 204 ] || ip=$(curl -4 -s --max-time 12 -x "socks5h://127.0.0.1:$port" https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -rf "$tmp"
  [ "$code" = 204 ] || [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# просим BACKEND перезапустить мост (ключ разрешает на BACKEND только эту команду); не чаще 4 раз в час
repair() {
  local ip port out rc n
  ip=$(get BACKEND_IP); port=$(get BACKEND_PORT)
  if systemctl cat chain-bridge >/dev/null 2>&1; then   # BACKEND на этом же сервере: перезапускаем напрямую
    systemctl restart chain-bridge; echo "$now" >> "$ST.repairs"; setst grace $((now + 180)); setst ef 0
    inc "мост" "мост перезапущен на этом сервере" "причина: $1"; return 0
  fi
  n=$(awk -v t="$now" '$1 > t-3600' "$ST.repairs" 2>/dev/null | wc -l)
  if [ "$n" -ge 4 ]; then inc "мост" "автоперезапуск моста пропущен" "уже было 4 перезапуска за последний час"; setst grace $((now + 600)); return 0; fi
  if [ -z "$ip" ] || [ ! -r "$RKEY" ]; then inc "мост" "перезапуск моста невозможен" "нет адреса BACKEND в настройках или ключа $RKEY"; setst grace $((now + 900)); return 0; fi
  rc=0; out=$(timeout 30 ssh -i "$RKEY" -p "${port:-22}" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "root@$ip" "$1" 2>&1) || rc=$?
  echo "$now" >> "$ST.repairs"; tail -n 20 "$ST.repairs" > "$ST.repairs.tmp" && mv -f "$ST.repairs.tmp" "$ST.repairs"
  setst grace $((now + 180))
  if [ "$rc" -eq 0 ]; then
    inc "мост" "RELAY попросил BACKEND перезапустить мост" "причина: $1"
    setst ef 0
  else
    inc "мост" "не удалось перезапустить мост по SSH" "ssh завершился с кодом $rc: $(printf '%s' "$out" | tail -n 1 | cut -c1-160)"
  fi
}

# службы RELAY
for s in nginx x-ui; do
  if systemctl is-active --quiet "$s"; then
    if [ "$(sv "svc_$s")" = fail ]; then inc --ok "$s" "служба снова работает"; setst "svc_$s" ok; fi
  else
    setst "svc_$s" fail
    inc "$s" "служба не работает" "systemctl is-active: $(systemctl is-active "$s" 2>&1 | head -n1)"
  fi
done

# соединения моста
conns=$(ss -tnH state established "( sport = :21444 )" 2>/dev/null | wc -l)
cf=$(sv cf); cf=${cf:-0}
if [ "$conns" -ge 1 ]; then
  [ "$cf" -ge 2 ] && inc --ok "мост" "мост снова подключён к RELAY"
  cf=0
else
  cf=$((cf + 1))
  [ "$cf" -ge 2 ] && inc "мост" "мост не подключён" "на туннельном пути нет соединений минуту и дольше"
fi
setst cf "$cf"

# сквозная проверка (не чаще раза в 2 мин и только при подключённом мосте)
e2e=$(kv e2e); e2e_ts=$(kv e2e_ts); e2e=${e2e:-unknown}; e2e_ts=${e2e_ts:-0}
[[ "$e2e_ts" =~ ^[0-9]+$ ]] || e2e_ts=0
ef=$(sv ef); ef=${ef:-0}
if [ "$conns" -ge 1 ] && { [ "${CHAIN_HEALTH_FORCE_E2E:-0}" = 1 ] || [ $((now - e2e_ts)) -ge 120 ]; }; then
  rc=0; e2e_probe || rc=$?
  case $rc in 0) e2e=ok ;; 1) e2e=fail ;; *) e2e=unknown ;; esac
  e2e_ts=$now
  if [ "$e2e" = fail ]; then
    ef=$((ef + 1))
    inc "цепочка" "сквозная проверка не прошла" "запрос клиент → nginx → мост → интернет не получил ответа"
  elif [ "$e2e" = ok ]; then
    [ "$ef" -ge 1 ] && inc --ok "цепочка" "сквозная проверка проходит"
    ef=0
  fi
  setst ef "$ef"
fi

# нагрузка: новые соединения в минуту (суммарно по nginx, без адресов клиентов)
stt=$(curl -s --max-time 3 "$STATUS_URL" 2>/dev/null || true)
acc=$(printf '%s\n' "$stt" | awk 'NR==3{print $1}'); act=$(printf '%s\n' "$stt" | awk '/Active connections/{print $3}')
if [[ "$acc" =~ ^[0-9]+$ ]]; then
  pa=$(sv acc); pt=$(sv acc_ts)
  if [[ "$pa" =~ ^[0-9]+$ ]] && [[ "$pt" =~ ^[0-9]+$ ]] && [ "$now" -gt "$pt" ] && [ "$acc" -ge "$pa" ]; then
    rate=$(awk -v d=$((acc - pa)) -v s=$((now - pt)) 'BEGIN{printf "%.1f", d*60/s}')
    printf '%s %s %s %s\n' "$now" "$acc" "$rate" "${act:-0}" >> "$MET"
    tail -n 240 "$MET" > "$MET.tmp" && mv -f "$MET.tmp" "$MET"
  fi
  setst acc "$acc"; setst acc_ts "$now"
fi

# перезапуск моста: нет соединений ~3 мин или две неудачные сквозные проверки подряд
grace=$(sv grace); grace=${grace:-0}; ef=$(sv ef); ef=${ef:-0}
need=""
[ "$cf" -ge 6 ] && need="no-bridge"
[ "$ef" -ge 2 ] && need=${need:-e2e-fail}
if [ -n "$need" ] && [ "$now" -ge "$grace" ]; then repair "$need"; fi

# версия Xray на RELAY: запоминается в метке установки (и при обновлении через панель 3x-ui — по смене файла)
xbin=""; for b in /usr/local/x-ui/bin/xray-linux-*; do case "$b" in *.prev) continue ;; esac; xbin=$b; break; done
if [ -x "$xbin" ]; then
  stamp=$(stat -c '%Y:%s' "$xbin" 2>/dev/null)
  if [ -n "$stamp" ] && [ "$stamp" != "$(sv xbin_stamp)" ]; then
    xv=$("$xbin" version 2>/dev/null | awk 'NR==1{print $2}')
    if [ -n "$xv" ]; then
      old=$(mget XRAY_VERSION)
      if [ "$xv" != "$old" ]; then
        mset XRAY_VERSION "$xv"; mset XRAY_UPDATED "$now"
        if [ -n "$old" ]; then
          mset XRAY_SOURCE external
          inc --info "Xray" "Xray на RELAY изменён: $old → $xv (обнаружено автоматически, например обновление через панель 3x-ui)"
        else
          mset XRAY_SOURCE detected
        fi
      fi
      setst xbin_stamp "$stamp"
    fi
  fi
fi


printf 'ts=%s\nconns=%s\ne2e=%s\ne2e_ts=%s\n' "$now" "$conns" "$e2e" "$e2e_ts" > "$H.tmp" && mv -f "$H.tmp" "$H"
chmod 644 "$H"
EOT_H
chmod +x /usr/local/bin/chain-health

cat > /usr/local/bin/chain-certcheck <<'EOT_C'
#!/bin/bash
# chain-certcheck — раз в неделю: срок сертификата и пробное продление (certbot renew --dry-run). Результат — в журнал сбоев.
#   chain-certcheck          полная проверка
#   chain-certcheck --days   только сколько дней осталось
conf=${CHAIN_SETUP_CONF:-/root/.chain-setup.conf}
D=$(sed -n 's/^DOMAIN=//p' "$conf" 2>/dev/null | head -n1)
cert=/etc/letsencrypt/live/$D/fullchain.pem
FLAG=/var/lib/chain/cert-failed
inc() { /usr/local/bin/chain-incident "$@" >/dev/null 2>&1 || true; }
days() {
  local end; end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
  [ -n "$end" ] || return 1
  echo $(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
}
if [ "${1:-}" = "--days" ]; then days || echo "?"; exit 0; fi
bad=0
d=$(days) || { inc "сертификат" "сертификат не найден" "нет файла $cert"; touch "$FLAG"; exit 1; }
if [ "$d" -lt 21 ]; then inc "сертификат" "срок сертификата истекает" "осталось $d дн.; автопродление должно срабатывать за 30 дн."; bad=1; fi
rc=0; out=$(timeout 240 certbot renew --dry-run --cert-name "$D" 2>&1) || rc=$?
if [ "$rc" -ne 0 ]; then
  inc "сертификат" "пробное продление не прошло" "certbot: $(printf '%s' "$out" | grep -aiE 'error|fail|timeout|connection|unauthorized|detail' | tail -n 1 | cut -c1-200)"
  bad=1
fi
if [ "$bad" -eq 0 ]; then
  [ -e "$FLAG" ] && inc --ok "сертификат" "срок $d дн., пробное продление проходит"
  rm -f "$FLAG"
else touch "$FLAG"; fi
exit "$bad"
EOT_C
chmod +x /usr/local/bin/chain-certcheck

cat > /usr/local/bin/chain-boot-test <<'EOT_B'
#!/bin/bash
# chain-boot-test — автотест после перезагрузки RELAY: службы, мост, сквозная проверка, «без моста нет выхода», срок сертификата.
# Итог пишется в /var/log/chain-incidents.log (компонент «автотест»).
inc() { /usr/local/bin/chain-incident "$@" >/dev/null 2>&1 || true; }
bad=0
for i in $(seq 1 36); do systemctl is-active --quiet nginx && systemctl is-active --quiet x-ui && break; sleep 5; done
for s in nginx x-ui; do
  systemctl is-active --quiet "$s" || { inc "автотест" "после перезагрузки $s не запустился" "systemctl is-active: $(systemctl is-active "$s" 2>&1 | head -n1)"; bad=1; }
done
c=0
for i in $(seq 1 48); do c=$(ss -tnH state established "( sport = :21444 )" 2>/dev/null | wc -l); [ "$c" -ge 1 ] && break; sleep 5; done
if [ "$c" -lt 1 ]; then
  inc "автотест" "после перезагрузки мост не подключился за 4 минуты" "соединений на туннельном пути нет; BACKEND мог ещё не запуститься или нет связи"
  bad=1
else
  CHAIN_HEALTH_FORCE_E2E=1 /usr/local/bin/chain-health || true
  e=$(sed -n 's/^e2e=//p' /var/lib/chain/health 2>/dev/null | head -n1)
  [ "$e" = ok ] || { inc "автотест" "после перезагрузки сквозная проверка не прошла" "результат проверки: ${e:-нет данных}"; bad=1; }
fi
if [ -x /usr/local/bin/chain-failclosed ]; then
  rc=0; /usr/local/bin/chain-failclosed --quiet || rc=$?
  case $rc in
    0) ;;
    1) inc "автотест" "УТЕЧКА: без моста трафик пользователей выходит с IP RELAY" "проверка chain-failclosed вернула «выход есть»"; bad=1 ;;
    *) inc "автотест" "проверка «без моста нет выхода» не выполнена" "chain-failclosed завершилась с кодом $rc (запустите вручную для подробностей)"; bad=1 ;;
  esac
fi
d=$(/usr/local/bin/chain-certcheck --days 2>/dev/null)
if [[ "$d" =~ ^-?[0-9]+$ ]] && [ "$d" -lt 14 ]; then inc "автотест" "срок сертификата меньше 14 дней" "осталось $d дн."; bad=1; fi
[ "$bad" -eq 0 ] && inc --ok "автотест" "после перезагрузки всё в порядке"
exit 0
EOT_B
chmod +x /usr/local/bin/chain-boot-test

cat > /etc/nginx/conf.d/chain-status.conf <<'EOT_N'
# служебный счётчик соединений nginx (только localhost) — для chain-health
server {
    listen 127.0.0.1:21480;
    access_log off;
    location = /nginx_status { stub_status; allow 127.0.0.1; deny all; }
}
EOT_N

cat > /etc/systemd/system/chain-health.service <<'EOT_S'
[Unit]
Description=chain health (состояние цепочки на RELAY)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/chain-health
EOT_S
cat > /etc/systemd/system/chain-health.timer <<'EOT_T'
[Unit]
Description=chain health: раз в 30 секунд

[Timer]
OnBootSec=60
OnUnitActiveSec=30
AccuracySec=5

[Install]
WantedBy=timers.target
EOT_T
cat > /etc/systemd/system/chain-certcheck.service <<'EOT_S'
[Unit]
Description=chain: проверка срока и продления сертификата

[Service]
Type=oneshot
ExecStart=/usr/local/bin/chain-certcheck
EOT_S
cat > /etc/systemd/system/chain-certcheck.timer <<'EOT_T'
[Unit]
Description=chain: проверка сертификата раз в неделю

[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOT_T
cat > /etc/systemd/system/chain-boot-test.service <<'EOT_S'
[Unit]
Description=chain: автотест после перезагрузки
After=network-online.target nginx.service x-ui.service

[Service]
Type=oneshot
TimeoutStartSec=900
ExecStart=/usr/local/bin/chain-boot-test
EOT_S
cat > /etc/systemd/system/chain-boot-test.timer <<'EOT_T'
[Unit]
Description=chain: автотест через 3 минуты после запуска системы

[Timer]
OnBootSec=3min

[Install]
WantedBy=timers.target
EOT_T
cp -p "$F" "$F.bak-health"
if ! python3 - "$F" "$VPATH" <<'PY'
# Обновляет конфиг nginx RELAY: (1) путь версии Xray отдаёт файл через root+try_files (alias на файл без «/» давал 500
# из-за обработчика index); (2) убирает путь состояния /health (в 4.3 BACKEND RELAY не опрашивает).
# Идемпотентно. Код возврата: 0 — готово, 2 — не найден блок версии Xray.
import re, sys
f, vp = sys.argv[1], sys.argv[2]
s = open(f).read()
pat = r"    location = /%s/ \{.*?\n    \}\n" % re.escape(vp)
m = re.search(pat, s, re.S)
if not m:
    print("блок версии Xray не найден в %s" % f)
    sys.exit(2)
ver = m.group(0)
fixed = ver.replace("        alias /var/lib/chain/xray-version;\n", "        root /var/lib/chain;\n        try_files /xray-version =404;\n")
out = s[:m.start()] + fixed + s[m.end():]
done = []
if fixed != ver:
    done.append("путь версии исправлен")
hp = r"\n    # Состояние туннеля для сторожа моста BACKEND[^\n]*\n    location = /%s/health \{.*?\n    \}\n" % re.escape(vp)
out2 = re.sub(hp, "\n", out, flags=re.S)
if out2 != out:
    done.append("путь /health убран")
    out = out2
if out != s:
    open(f, "w").write(out)
print(", ".join(done) or "уже актуально")
PY
then
  cp -p "$F.bak-health" "$F"; echo "конфиг nginx не изменён" >&2; exit 1
fi
if nginx -t >/dev/null 2>&1; then
  systemctl reload nginx
  rm -f "$F.bak-health"
else
  cp -p "$F.bak-health" "$F"; rm -f /etc/nginx/conf.d/chain-status.conf; nginx -t >&2 || true; echo "nginx -t не прошёл, конфиг возвращён" >&2; exit 1
fi
if [ -f /usr/local/bin/chain-status ] && ! grep -q 'chain-health --show' /usr/local/bin/chain-status; then
  printf '%s\n' '[ -x /usr/local/bin/chain-health ] && /usr/local/bin/chain-health --show' >> /usr/local/bin/chain-status
fi
systemctl daemon-reload
systemctl enable --now chain-health.timer chain-certcheck.timer chain-boot-test.timer >/dev/null 2>&1
/usr/local/bin/chain-health || true
__CHAIN_EOF__

  # BACKEND: локальный сторож chain-watchdog (раз в минуту, в сеть ничего не отправляет), chain-restart-bridge (команда для ключа RELAY), keepalive HTTP/2 и защита моста; идемпотентно, подходит и для уже установленного моста
  cat > "$D/watchdog-install.sh" <<'__CHAIN_EOF__'
set -Eeuo pipefail
CF=/etc/chain-bridge/config.json
[ -f "$CF" ] && [ -f /etc/chain-bridge/sync.conf ] && [ -x /usr/local/bin/chain-xray ] || { echo "мост chain-bridge не установлен" >&2; exit 1; }
NEW="${CF%.json}.next.json"   # Xray определяет формат по расширению: временный файл тоже *.json
changed=$(python3 - "$CF" "$NEW" <<'PY'
import json, re, subprocess, sys
f = sys.argv[1]
c = json.load(open(f))
changed = 0
xm = c["outbounds"][0]["streamSettings"]["xhttpSettings"].setdefault("xmux", {})
if "hKeepAlivePeriod" not in xm:
    xm["hKeepAlivePeriod"] = 15
    changed = 1
# свои публичные адреса BACKEND — в список запретов выхода (через туннель нельзя обращаться к самому серверу по его внешнему IP)
own = []
for fam, plen in (("inet", 32), ("inet6", 128)):
    out = subprocess.run(["ip", "-o", "-" + ("4" if fam == "inet" else "6"), "addr", "show", "scope", "global"], capture_output=True, text=True).stdout
    for m in re.finditer(r"\b%s\s+([0-9a-fA-F:.]+)/\d+" % fam, out):
        own.append("%s/%d" % (m.group(1), plen))
for o in c["outbounds"]:
    if o.get("tag") == "direct":
        fr = o.get("settings", {}).get("finalRules", [])
        if fr and fr[0].get("action") == "block":
            have = set(fr[0].get("ip", []))
            add = [a for a in own if a not in have]
            if add:
                fr[0]["ip"] = fr[0].get("ip", []) + add
                changed = 1
if changed:
    json.dump(c, open(sys.argv[2], "w"), indent=2)
print(changed)
PY
)
if [ "$changed" = 1 ]; then
  chown --reference="$CF" "$NEW"; chmod --reference="$CF" "$NEW"
  if /usr/local/bin/chain-xray run -test -c "$NEW" >/dev/null 2>&1; then mv -f "$NEW" "$CF"; else rm -f "$NEW"; echo "обновлённый конфиг моста не прошёл проверку Xray" >&2; exit 1; fi
fi
mkdir -p /var/lib/chain-bridge/watchdog
cat > /usr/local/bin/chain-watchdog <<'EOT_WD'
#!/bin/bash
# chain-watchdog — сторож моста (BACKEND). Раз в минуту смотрит ТОЛЬКО на этот сервер, в сеть ничего не отправляет:
# жива ли служба chain-bridge и есть ли установленное соединение моста с RELAY:443.
# Нет соединения 2 минуты — запись в журнал сбоев с причиной; 3 минуты — перезапуск моста (не чаще раза в 3 мин и не больше 4 раз в час).
# Состояние RELAY проверяет сам RELAY (chain-health) и при необходимости просит перезапустить мост (chain-restart-bridge).
#   chain-watchdog            одна проверка (запускается таймером)
#   chain-watchdog --status   последнее состояние и история перезапусков
CONF=${CHAIN_BRIDGE_CONF:-/etc/chain-bridge/sync.conf}
S=${CHAIN_WD_STATE:-/var/lib/chain-bridge/watchdog}
now=${CHAIN_WD_NOW:-$(date +%s)}
get() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -n1; }
sv() { sed -n "s/^$1=//p" "$S/state" 2>/dev/null | head -n1; }
num() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
inc() { /usr/local/bin/chain-incident "$@" >/dev/null 2>&1 || true; }
mkdir -p "$S"
if [ "${1:-}" = "--status" ]; then
  if [ -r "$S/state" ]; then cat "$S/state"; else echo "состояния ещё нет"; fi
  echo "перезапусков за последний час: $(awk -v n="$now" '$1 > n - 3600' "$S/restarts" 2>/dev/null | wc -l)"
  echo "последние перезапуски:"; tail -n 5 "$S/restarts" 2>/dev/null | while read -r t why; do echo "  $(date -d "@$t" '+%F %T') $why"; done
  exit 0
fi
# версия Xray моста: запоминается в метке установки (и при обновлении вне скрипта — по смене файла)
MARK=${CHAIN_MARKER_FILE:-/root/.chain-setup.installed}
mget() { sed -n "s/^$1=//p" "$MARK" 2>/dev/null | head -n1; }
mset() { [ -f "$MARK" ] || return 0; if grep -q "^$1=" "$MARK"; then sed -i "s|^$1=.*|$1=$2|" "$MARK"; else printf '%s=%s\n' "$1" "$2" >> "$MARK"; fi; }
xb=${CHAIN_XRAY_BIN:-/usr/local/bin/chain-xray}
if [ -x "$xb" ]; then
  stamp=$(stat -c '%Y:%s' "$xb" 2>/dev/null)
  if [ -n "$stamp" ] && [ "$stamp" != "$(cat "$S/xbin_stamp" 2>/dev/null)" ]; then
    xv=$("$xb" version 2>/dev/null | awk 'NR==1{print $2}')
    if [ -n "$xv" ]; then
      old=$(mget XRAY_VERSION)
      if [ "$xv" != "$old" ]; then
        mset XRAY_VERSION "$xv"; mset XRAY_UPDATED "$now"
        if [ -n "$old" ]; then
          mset XRAY_SOURCE external
          inc --info "Xray" "Xray на BACKEND изменён: $old → $xv (обнаружено автоматически)"
        else
          mset XRAY_SOURCE detected
        fi
      fi
      printf '%s\n' "$stamp" > "$S/xbin_stamp"
    fi
  fi
fi
RELAY_IP=$(get RELAY_IP)
[ -n "$RELAY_IP" ] || exit 0
cf=$(sv conn_fails); grace=$(sv grace_until); dn=$(sv down)
num "$cf" || cf=0; num "$grace" || grace=0; [ "$dn" = 1 ] || dn=0
verdict=ok
if systemctl is-failed --quiet chain-bridge; then
  inc "мост" "служба chain-bridge в состоянии failed" "последняя ошибка: $(journalctl -u chain-bridge -n 20 --no-pager -o cat 2>/dev/null | grep -aiE 'error|fail|timeout|refused|reset' | tail -n 1 | cut -c1-160)"
  systemctl restart chain-bridge; verdict=restarted-failed; grace=$((now + 180))
elif ! systemctl is-active --quiet chain-bridge; then
  verdict=stopped      # мост остановлен вручную — не вмешиваемся
  cf=0
else
  conns=$(ss -tnH state established "( dst $RELAY_IP and dport = :443 )" 2>/dev/null | wc -l)
  if [ "$conns" -ge 1 ]; then
    [ "$dn" = 1 ] && inc --ok "мост" "соединение моста с RELAY восстановлено"
    cf=0; dn=0
  elif [ "$now" -lt "$grace" ]; then
    verdict=grace      # после перезапуска даём время подключиться
  else
    cf=$((cf + 1)); verdict=failing
    if [ "$cf" -ge 2 ]; then
      rc=0; timeout 5 bash -c "exec 3<>/dev/tcp/$RELAY_IP/443" 2>/dev/null || rc=$?
      case $rc in 0) tcp="TCP до RELAY:443 открывается, но мост соединение не держит" ;; 124) tcp="TCP до RELAY:443: нет ответа (таймаут)" ;; *) tcp="TCP до RELAY:443 не открывается (отказ или сброс)" ;; esac
      dn=1
      inc "мост" "нет соединения моста с RELAY" "$tcp; последняя ошибка моста: $(journalctl -u chain-bridge -n 20 --no-pager -o cat 2>/dev/null | grep -aiE 'error|fail|timeout|refused|reset' | tail -n 1 | cut -c1-120)"
    fi
    if [ "$cf" -ge 3 ]; then
      last=$(tail -n 1 "$S/restarts" 2>/dev/null | awk '{print $1}'); num "$last" || last=0
      recent=$(awk -v n="$now" '$1 > n - 3600' "$S/restarts" 2>/dev/null | wc -l)
      if [ $((now - last)) -lt 180 ]; then
        verdict=cooldown
      elif [ "$recent" -ge 4 ]; then
        verdict=rate-limited; inc "мост" "автоперезапуск моста пропущен" "уже было 4 перезапуска за последний час"
      else
        echo "$now no-connection" >> "$S/restarts"; tail -n 50 "$S/restarts" > "$S/restarts.tmp" && mv -f "$S/restarts.tmp" "$S/restarts"
        inc "мост" "мост перезапущен сторожем" "соединения с RELAY нет 3 минуты"
        systemctl restart chain-bridge
        cf=0; grace=$((now + 180)); verdict=restarted
      fi
    fi
  fi
fi
{ echo "verdict=$verdict"; echo "checked=$now"; echo "conn_fails=$cf"; echo "grace_until=$grace"; echo "down=$dn"; } > "$S/state.tmp" && mv -f "$S/state.tmp" "$S/state"
exit 0
EOT_WD
chmod +x /usr/local/bin/chain-watchdog
cat > /usr/local/bin/chain-restart-bridge <<'EOT_RB'
#!/bin/bash
# chain-restart-bridge — единственная команда, которую SSH-ключу RELAY (chain-restart) разрешено выполнять на BACKEND: перезапуск моста.
reason=${SSH_ORIGINAL_COMMAND:-}
[ "$reason" = ping ] && { echo "ключ работает"; exit 0; }
[ "$reason" = version ] && { /usr/local/bin/chain-xray version 2>/dev/null | awk 'NR==1{print "xray="$2}'; exit 0; }
[ "$reason" = cpu ] && { read -r _ u1 n1 s1 i1 w1 q1 f1 _ < /proc/stat; sleep 4; read -r _ u2 n2 s2 i2 w2 q2 f2 _ < /proc/stat; t=$(( (u2+n2+s2+i2+w2+q2+f2) - (u1+n1+s1+i1+w1+q1+f1) )); b=$(( t - (i2+w2-i1-w1) )); if [ "$t" -gt 0 ]; then echo "cpu=$(( 100*b/t ))"; else echo "cpu=0"; fi; exit 0; }
case "$reason" in
  no-bridge) why="RELAY не видит соединений моста" ;;
  e2e-fail) why="сквозная проверка на RELAY не прошла" ;;
  *) why="по запросу RELAY" ;;
esac
S=/var/lib/chain-bridge/watchdog; mkdir -p "$S"
now=$(date +%s)
last=$(tail -n 1 "$S/restarts" 2>/dev/null | awk '{print $1}'); [[ "$last" =~ ^[0-9]+$ ]] || last=0
if [ $((now - last)) -lt 120 ]; then echo "перезапуск пропущен: мост перезапускали менее 2 минут назад"; exit 0; fi
echo "$now relay:${reason:-request}" >> "$S/restarts"; tail -n 50 "$S/restarts" > "$S/restarts.tmp" && mv -f "$S/restarts.tmp" "$S/restarts"
/usr/local/bin/chain-incident "мост" "мост перезапущен по запросу RELAY" "$why" >/dev/null 2>&1 || true
systemctl restart chain-bridge
sleep 2
systemctl is-active --quiet chain-bridge && echo "мост перезапущен" || { echo "мост не запустился"; exit 1; }
EOT_RB
chmod +x /usr/local/bin/chain-restart-bridge
cat > /etc/systemd/system/chain-watchdog.service <<'EOT_S'
[Unit]
Description=chain watchdog (сторож моста, локальные проверки)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/chain-watchdog
EOT_S
cat > /etc/systemd/system/chain-watchdog.timer <<'EOT_T'
[Unit]
Description=chain watchdog: раз в минуту (в сеть ничего не отправляет)

[Timer]
OnBootSec=120
OnUnitActiveSec=60
AccuracySec=5

[Install]
WantedBy=timers.target
EOT_T
systemctl daemon-reload
systemctl enable --now chain-watchdog.timer >/dev/null 2>&1
if [ "$changed" = 1 ]; then
  systemctl restart chain-bridge
  sleep 3
  systemctl is-active --quiet chain-bridge
fi
__CHAIN_EOF__

  cat > "$D/incident-install.sh" <<'__CHAIN_EOF_INCIDENT_INSTALL_SH__'
set -e
mkdir -p /var/lib/chain-incident
cat > /usr/local/bin/chain-incident <<'EOT'
#!/bin/bash
# chain-incident — журнал сбоев цепочки: /var/log/chain-incidents.log
#   chain-incident КОМПОНЕНТ "что произошло" "причина"   записать сбой (то же самое чаще раза в 30 мин не дублируется)
#   chain-incident --ok КОМПОНЕНТ "что восстановилось"    записать восстановление
#   chain-incident --info КОМПОНЕНТ "что произошло"       информационная запись (например, изменение версии Xray)
#   chain-incident --show [N]                             последние N записей (по умолчанию 30)
F=${CHAIN_INCIDENT_LOG:-/var/log/chain-incidents.log}
S=${CHAIN_INCIDENT_STATE:-/var/lib/chain-incident}
MARK=${CHAIN_MARKER_FILE:-/root/.chain-setup.installed}
role=$(sed -n 's/^ROLE=//p' "$MARK" 2>/dev/null | head -n1); role=${role:-relay}
clean() { printf '%s' "$*" | tr '\n\r|' '   ' | tr -d '\000-\010\013\014\016-\037' | cut -c1-300; }
h() { printf '%s' "$1" | md5sum | cut -c1-8; }
if [ "${1:-}" = "--show" ]; then tail -n "${2:-30}" "$F" 2>/dev/null || true; [ -s "$F" ] || echo "записей нет"; exit 0; fi
mkdir -p "$S" "$(dirname "$F")"
[ -e "$F" ] || { : > "$F"; chmod 600 "$F"; }
now=${CHAIN_INCIDENT_NOW:-$(date +%s)}
ts=$(date -d "@$now" '+%F %T')
if [ "${1:-}" = "--info" ]; then
  comp=$(clean "${2:-?}"); what=$(clean "${3:-?}")
  printf '%s | %s | %s | ИНФО: %s | —\n' "$ts" "${role^^}" "$comp" "$what" >> "$F"
  exit 0
fi
if [ "${1:-}" = "--ok" ]; then
  comp=$(clean "${2:-?}"); what=$(clean "${3:-восстановлено}")
  rm -f "$S/$(h "$comp")"-* 2>/dev/null
  printf '%s | %s | %s | ВОССТАНОВЛЕНО: %s | —\n' "$ts" "${role^^}" "$comp" "$what" >> "$F"
  exit 0
fi
comp=$(clean "${1:-?}"); what=$(clean "${2:-?}"); why=$(clean "${3:-причина не определена}")
k="$S/$(h "$comp")-$(h "$what|$why")"
if [ -f "$k" ] && [ $((now - $(cat "$k" 2>/dev/null || echo 0))) -lt 1800 ]; then exit 0; fi
printf '%s\n' "$now" > "$k"
printf '%s | %s | %s | %s | %s\n' "$ts" "${role^^}" "$comp" "$what" "$why" >> "$F"
exit 0
EOT
chmod +x /usr/local/bin/chain-incident
cat > /etc/logrotate.d/chain-incidents <<'EOT'
/var/log/chain-incidents.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 600 root root
}
EOT
[ -e /var/log/chain-incidents.log ] || { : > /var/log/chain-incidents.log; chmod 600 /var/log/chain-incidents.log; }
__CHAIN_EOF_INCIDENT_INSTALL_SH__

  cat > "$D/bridge-tools.sh" <<'__CHAIN_EOF_BRIDGE_TOOLS_SH__'
set -Eeuo pipefail
[ -f /etc/chain-bridge/config.json ] && [ -x /usr/local/bin/chain-xray ] || { echo "мост chain-bridge не установлен" >&2; exit 1; }
cat > /usr/local/bin/chain-update-bridge <<'EOT'
#!/bin/bash
# chain-update-bridge — версия Xray моста (только вручную, по таймеру ничего не опрашивается)
#   chain-update-bridge 26.10.31   установить указанную версию (прежняя сохраняется; если мост не подключился — автоматический откат)
#   chain-update-bridge            привести Xray моста к версии RELAY (если RELAY отвечает)
#   chain-update-bridge --rollback вернуть версию, сохранённую при последнем обновлении
#   chain-update-bridge --status   показать версии на BACKEND и RELAY
CONF=/etc/chain-bridge/sync.conf; BIN=/usr/local/bin/chain-xray
get() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -n1; }
RELAY_IP=$(get RELAY_IP); DOMAIN=$(get DOMAIN); VPATH=$(get VPATH)
log() { logger -t chain-update "$*"; echo "$(date '+%F %T') $*"; }
inc() { /usr/local/bin/chain-incident "$@" >/dev/null 2>&1 || true; }
mark_xray() { local f=/root/.chain-setup.installed kv k; [ -f "$f" ] || return 0; for kv in "XRAY_VERSION=$1" "XRAY_UPDATED=$(date +%s)" "XRAY_SOURCE=script"; do k=${kv%%=*}; if grep -q "^$k=" "$f"; then sed -i "s|^$k=.*|$kv|" "$f"; else echo "$kv" >> "$f"; fi; done; }
cur=$("$BIN" version 2>/dev/null | awk 'NR==1{print $2}')
remote() {
  [ -n "$RELAY_IP" ] && [ -n "$DOMAIN" ] && [ -n "$VPATH" ] || return 1
  curl -fsS --max-time 15 --resolve "$DOMAIN:443:$RELAY_IP" "https://$DOMAIN/$VPATH/" 2>/dev/null | tr -d '[:space:]'
}
valid() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
wait_conn() { local _; for _ in $(seq 1 25); do sleep 1; if systemctl is-active --quiet chain-bridge && ss -tnH state established "( dst $RELAY_IP and dport = :443 )" 2>/dev/null | grep -q .; then return 0; fi; done; return 1; }
mode="${1:-sync}"
case "$mode" in
  --status | status)
    r=$(remote)
    echo "Xray на BACKEND: ${cur:-?}"
    echo "Xray на RELAY:   ${r:-недоступно}"
    [ -x "$BIN.prev" ] && echo "сохранённая предыдущая версия: $("$BIN.prev" version 2>/dev/null | awk 'NR==1{print $2}')"
    exit 0 ;;
  --rollback)
    [ -x "$BIN.prev" ] || { echo "предыдущей версии нет ($BIN.prev)"; exit 1; }
    pv=$("$BIN.prev" version 2>/dev/null | awk 'NR==1{print $2}')
    mv -f "$BIN.prev" "$BIN"; [ -n "$pv" ] && mark_xray "$pv"; systemctl restart chain-bridge
    if wait_conn; then log "откат выполнен: ${cur:-?} -> ${pv:-?}"; inc "обновление Xray" "Xray моста возвращён на предыдущую версию" "${cur:-?} -> ${pv:-?} по запросу"; exit 0; fi
    log "ОШИБКА: после отката на ${pv:-?} мост не подключился"; inc "обновление Xray" "после отката мост не подключился" "версия ${pv:-?}"; exit 1 ;;
  sync) target=$(remote) || { echo "RELAY недоступен: версия не получена"; exit 1; }; valid "$target" || { echo "RELAY вернул неверную версию"; exit 1; } ;;
  *) target="${mode#v}"; valid "$target" || { echo "использование: chain-update-bridge [ВЕРСИЯ|--rollback|--status]"; exit 1; } ;;
esac
if [ "$target" = "$cur" ]; then echo "уже установлена версия $cur"; exit 0; fi
exec 9>/run/chain-update.lock
flock -n 9 || exit 0
case "$(uname -m)" in x86_64 | amd64) ARCH=64 ;; aarch64 | arm64) ARCH=arm64-v8a ;; *) log "неподдерживаемая архитектура"; exit 1 ;; esac
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
URL="https://github.com/XTLS/Xray-core/releases/download/v$target/Xray-linux-$ARCH.zip"
if ! curl -fsSL --retry 3 --max-time 300 -o "$tmp/x.zip" "$URL" || ! curl -fsSL --retry 3 --max-time 60 -o "$tmp/x.dgst" "$URL.dgst"; then
  log "версия $target недоступна на GitHub — пропуск"; inc "обновление Xray" "версия $target не скачана" "GitHub не отдал файл или нет связи"; exit 1
fi
want=$(sed -n 's/^SHA2-256= *//p' "$tmp/x.dgst" | head -n1 | tr -d '[:space:]')
have=$(sha256sum "$tmp/x.zip" | awk '{ print $1 }')
[ -n "$want" ] && [ "$want" = "$have" ] || { log "контрольная сумма $target не совпала — отмена"; inc "обновление Xray" "контрольная сумма $target не совпала" "обновление отменено"; exit 1; }
unzip -oq "$tmp/x.zip" xray -d "$tmp" || { log "не удалось распаковать $target"; exit 1; }
"$tmp/xray" run -test -c /etc/chain-bridge/config.json >/dev/null 2>&1 || { log "конфиг моста не проходит проверку версией $target — отмена"; inc "обновление Xray" "версия $target не приняла конфиг моста" "обновление отменено"; exit 1; }
cp -f "$BIN" "$BIN.prev"
install -m 755 "$tmp/xray" "$BIN.new" && mv -f "$BIN.new" "$BIN"
mark_xray "$target"
systemctl restart chain-bridge
if wait_conn; then
  log "Xray обновлён: ${cur:-?} -> $target (предыдущая версия сохранена: chain-update-bridge --rollback)"
else
  mv -f "$BIN.prev" "$BIN"
  [ -n "$cur" ] && mark_xray "$cur"
  systemctl restart chain-bridge
  log "ОШИБКА: мост не подключился на версии $target — выполнен откат на ${cur:-?}"
  inc "обновление Xray" "мост не подключился на версии $target" "автоматически выполнен откат на ${cur:-?}"
  exit 1
fi
EOT
chmod +x /usr/local/bin/chain-update-bridge
cat > /usr/local/bin/chain-set-relay <<'EOT'
#!/bin/bash
# chain-set-relay НОВЫЙ_IP_RELAY — сменить адрес RELAY у моста. Если мост не подключится к новому адресу за 40 с, прежний адрес возвращается.
CF=/etc/chain-bridge/config.json; SC=/etc/chain-bridge/sync.conf
NEW="${1:-}"; [ -n "$NEW" ] || { echo "usage: chain-set-relay НОВЫЙ_IP_RELAY"; exit 1; }
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "неверный IP"; exit 1; }
inc() { /usr/local/bin/chain-incident "$@" >/dev/null 2>&1 || true; }
setip() {
  python3 - "$1" <<'PY'
import json, sys
f = "/etc/chain-bridge/config.json"
c = json.load(open(f))
old = c["outbounds"][0]["settings"]["address"]
c["outbounds"][0]["settings"]["address"] = sys.argv[1]
json.dump(c, open(f, "w"), indent=2)
print(old)
PY
}
old=$(setip "$NEW") || { echo "не удалось изменить конфиг моста"; exit 1; }
echo "RELAY: $old -> $NEW"
sed -i "s/^RELAY_IP=.*/RELAY_IP=$NEW/" "$SC" 2>/dev/null || true
systemctl restart chain-bridge
ok=0
for _ in $(seq 1 40); do
  sleep 1
  if systemctl is-active --quiet chain-bridge && ss -tnH state established "( dst $NEW and dport = :443 )" 2>/dev/null | grep -q .; then ok=1; break; fi
done
if [ "$ok" -eq 1 ]; then echo "готово: мост подключён к $NEW"; exit 0; fi
setip "$old" >/dev/null
sed -i "s/^RELAY_IP=.*/RELAY_IP=$old/" "$SC" 2>/dev/null || true
systemctl restart chain-bridge
inc "мост" "смена адреса RELAY отменена" "мост не подключился к $NEW за 40 с; возвращён адрес $old"
echo "мост не подключился к $NEW за 40 с — возвращён прежний адрес $old"
exit 1
EOT
chmod +x /usr/local/bin/chain-set-relay
__CHAIN_EOF_BRIDGE_TOOLS_SH__

  cat > "$D/restart-key-install.sh" <<'__CHAIN_EOF_RESTART_KEY_INSTALL_SH__'
set -Eeuo pipefail
pub=$(printf '%s' "${1:?не передан ключ}" | base64 -d)
[[ "$pub" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ [^[:space:]]+)?$ ]] || { echo "некорректный публичный ключ" >&2; exit 1; }
[ -x /usr/local/bin/chain-restart-bridge ] || { echo "нет /usr/local/bin/chain-restart-bridge (установите сторож моста)" >&2; exit 1; }
mkdir -p /root/.ssh; chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
sed -i '/ chain-restart@/d' /root/.ssh/authorized_keys
printf 'restrict,command="/usr/local/bin/chain-restart-bridge" %s\n' "$pub" >> /root/.ssh/authorized_keys
__CHAIN_EOF_RESTART_KEY_INSTALL_SH__

  cat > "$D/xray-update-relay.sh" <<'__CHAIN_EOF_XRAY_UPDATE_RELAY_SH__'
set -Eeuo pipefail
# Обновление ядра Xray внутри 3x-ui на RELAY: prepare (скачать, проверить, прогнать проверки на новой версии) → apply (заменить с сохранением прежней) → rollback.
cmd="${1:?prepare|apply|rollback}"; V="${2:-}"; V="${V#v}"
BIN=""; for b in /usr/local/x-ui/bin/xray-linux-*; do case "$b" in *.prev) continue ;; esac; BIN=$b; break; done
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "Xray из 3x-ui не найден" >&2; exit 1; }
NEWD=/var/lib/chain/xray-new
inc() { /usr/local/bin/chain-incident "$@" >/dev/null 2>&1 || true; }
mark_xray() { local f=/root/.chain-setup.installed kv k; [ -f "$f" ] || return 0; for kv in "XRAY_VERSION=$1" "XRAY_UPDATED=$(date +%s)" "XRAY_SOURCE=script"; do k=${kv%%=*}; if grep -q "^$k=" "$f"; then sed -i "s|^$k=.*|$kv|" "$f"; else echo "$kv" >> "$f"; fi; done; }
wait_up() { local _; for _ in $(seq 1 40); do sleep 1; if systemctl is-active --quiet x-ui && ss -tlnH "( sport = :21443 )" 2>/dev/null | grep -q .; then return 0; fi; done; return 1; }
case "$cmd" in
  prepare)
    [[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "неверная версия Xray: $V" >&2; exit 1; }
    case "$(uname -m)" in x86_64 | amd64) ARCH=64 ;; aarch64 | arm64) ARCH=arm64-v8a ;; *) echo "неподдерживаемая архитектура" >&2; exit 1 ;; esac
    rm -rf "$NEWD"; mkdir -p "$NEWD"
    URL="https://github.com/XTLS/Xray-core/releases/download/v$V/Xray-linux-$ARCH.zip"
    curl -fsSL --retry 3 --max-time 300 -o "$NEWD/x.zip" "$URL" && curl -fsSL --retry 3 --max-time 60 -o "$NEWD/x.dgst" "$URL.dgst" || { echo "версия $V не скачана с GitHub" >&2; exit 1; }
    want=$(sed -n 's/^SHA2-256= *//p' "$NEWD/x.dgst" | head -n1 | tr -d '[:space:]'); have=$(sha256sum "$NEWD/x.zip" | awk '{print $1}')
    [ -n "$want" ] && [ "$want" = "$have" ] || { echo "контрольная сумма $V не совпала" >&2; exit 1; }
    unzip -oq "$NEWD/x.zip" xray -d "$NEWD"; chmod 755 "$NEWD/xray"
    "$NEWD/xray" run -test -c /usr/local/x-ui/bin/config.json >/dev/null 2>&1 || { echo "текущий конфиг Xray не проходит проверку версией $V" >&2; exit 1; }
    if [ -x /usr/local/bin/chain-failclosed ]; then
      rc=0; CHAIN_XRAY_BIN="$NEWD/xray" /usr/local/bin/chain-failclosed --quiet || rc=$?
      [ "$rc" -eq 1 ] && { echo "на версии $V без моста трафик выходит с IP RELAY — обновление отменено" >&2; inc "обновление Xray" "версия $V отклонена: утечка без моста" "проверка chain-failclosed на новой версии вернула «выход есть»"; exit 1; }
      [ "$rc" -eq 0 ] || echo "проверка «без моста нет выхода» на новой версии не выполнена (код $rc)" >&2
    fi
    echo "версия $V проверена и готова к установке" ;;
  apply)
    [ -x "$NEWD/xray" ] || { echo "сначала prepare" >&2; exit 1; }
    cp -f "$BIN" "$BIN.prev"
    oldv=$("$BIN.prev" version 2>/dev/null | awk 'NR==1{print $2}')
    install -m 755 "$NEWD/xray" "$BIN.new" && mv -f "$BIN.new" "$BIN"
    mark_xray "$("$BIN" version 2>/dev/null | awk 'NR==1{print $2}')"
    systemctl restart x-ui
    if wait_up; then echo "Xray на RELAY обновлён"; rm -rf "$NEWD"; exit 0; fi
    mv -f "$BIN.prev" "$BIN"; [ -n "${oldv:-}" ] && mark_xray "$oldv"; systemctl restart x-ui; wait_up || true
    inc "обновление Xray" "x-ui не поднялся на новой версии Xray" "автоматически возвращена прежняя версия"
    echo "x-ui не поднялся на новой версии — возвращена прежняя" >&2; exit 1 ;;
  rollback)
    [ -x "$BIN.prev" ] || { echo "сохранённой версии нет ($BIN.prev)" >&2; exit 1; }
    mv -f "$BIN.prev" "$BIN"; pv=$("$BIN" version 2>/dev/null | awk 'NR==1{print $2}'); [ -n "$pv" ] && mark_xray "$pv"; systemctl restart x-ui
    if wait_up; then inc "обновление Xray" "Xray на RELAY возвращён на предыдущую версию" "по запросу"; echo "откат выполнен"; else echo "после отката x-ui не поднялся" >&2; exit 1; fi ;;
  *) echo "неизвестная команда: $cmd" >&2; exit 1 ;;
esac
__CHAIN_EOF_XRAY_UPDATE_RELAY_SH__

  cat > "$D/relay-harden.py" <<'__CHAIN_EOF_RELAY_HARDEN_PY__'
#!/usr/bin/env python3
# Отключает журнал доступа и DNS-журнал Xray в шаблоне 3x-ui, чтобы на RELAY не копились адреса назначения пользователей.
# Меняет только log.access и log.dnsLog в шаблоне xrayTemplateConfig. Перед правкой делает копию базы. Код возврата: 0 — готово/менять нечего, 1 — ошибка.
import json, os, shutil, sqlite3, sys, time

DB = os.environ.get("CHAIN_XUI_DB", "/etc/x-ui/x-ui.db")
if not os.path.exists(DB):
    print("база 3x-ui не найдена: %s" % DB)
    sys.exit(1)
con = sqlite3.connect(DB, timeout=30)
row = con.execute("select value from settings where key='xrayTemplateConfig'").fetchone()
if not row or not row[0]:
    print("шаблон Xray в базе не задан: менять нечего")
    sys.exit(0)
try:
    tpl = json.loads(row[0])
except Exception as e:
    print("шаблон Xray не разобран: %s" % e)
    sys.exit(1)
log = tpl.setdefault("log", {})
want = {"access": "none", "dnsLog": False}
if str(log.get("loglevel", "")).lower() in ("debug", "info"):
    want["loglevel"] = "warning"
if all(log.get(k) == v for k, v in want.items()):
    print("журналы Xray уже отключены")
    sys.exit(0)
shutil.copy2(DB, "%s.bak-%s" % (DB, time.strftime("%Y%m%d-%H%M%S")))
log.update(want)
con.execute("update settings set value=? where key='xrayTemplateConfig'", (json.dumps(tpl, ensure_ascii=False),))
con.commit()
print("журнал доступа и DNS-журнал Xray отключены (нужен перезапуск x-ui)")
sys.exit(0)
__CHAIN_EOF_RELAY_HARDEN_PY__

  cat > "$D/failclosed.py" <<'__CHAIN_EOF_FAILCLOSED_PY__'
#!/usr/bin/env python3
# chain-failclosed — проверка: без моста RELAY не выпускает трафик пользователей в интернет сам.
# Берёт настройки Xray из 3x-ui, поднимает их временную копию на свободных портах БЕЗ моста и проверяет три случая:
#   1) контроль: маршрут пользователей временно заменён на прямой выход (должно работать — значит, проверка исправна);
#   2) моста нет: маршрут как в работе (прямого выхода быть не должно);
#   3) нет самого тега туннеля: Xray не находит исходящий и применяет исходящий по умолчанию (прямого выхода быть не должно).
# Рабочая цепочка и пользователи не затрагиваются. Код возврата: 0 — выхода нет (хорошо), 1 — ВЫХОД ЕСТЬ (утечка IP RELAY), 2 — проверить не удалось.
import copy, glob, json, os, signal, socket, subprocess, sys, tempfile, time

CONF = os.environ.get("CHAIN_XRAY_CONFIG", "/usr/local/x-ui/bin/config.json")
BIN = os.environ.get("CHAIN_XRAY_BIN") or next(iter(sorted(glob.glob("/usr/local/x-ui/bin/xray-linux-*"))), "")
URL = os.environ.get("CHAIN_TEST_URL", "https://www.google.com/generate_204")
USER_PORT, TUN_PORT = int(os.environ.get("CHAIN_USER_PORT", "21443")), int(os.environ.get("CHAIN_TUNNEL_PORT", "21444"))
T_USER, T_TUN, T_SOCKS = 21463, 21464, 21485
QUIET = "--quiet" in sys.argv


def say(msg):
    if not QUIET:
        print(msg, flush=True)


def listening(port, tries=40):
    for _ in range(tries):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.3).close()
            return True
        except OSError:
            time.sleep(0.15)
    return False


def port_busy(port):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port))
        return False
    except OSError:
        return True
    finally:
        s.close()


def run_case(name, srv_cfg, cli_cfg, tmp):
    sp, cp = os.path.join(tmp, name + "-s.json"), os.path.join(tmp, name + "-c.json")
    json.dump(srv_cfg, open(sp, "w"))
    json.dump(cli_cfg, open(cp, "w"))
    t = subprocess.run([BIN, "run", "-test", "-c", sp], capture_output=True, text=True)
    if t.returncode != 0:
        say("  ✖ %s: Xray не принял тестовую конфигурацию: %s" % (name, (t.stdout + t.stderr).strip().splitlines()[-1:] or ""))
        return None
    procs = []
    try:
        procs.append(subprocess.Popen([BIN, "run", "-c", sp], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        if not listening(T_USER):
            return None
        procs.append(subprocess.Popen([BIN, "run", "-c", cp], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        if not listening(T_SOCKS):
            return None
        r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "12",
                            "--socks5-hostname", "127.0.0.1:%d" % T_SOCKS, URL],
                           capture_output=True, text=True)
        return (r.stdout or "000").strip() or "000"
    finally:
        for p in procs:
            p.send_signal(signal.SIGTERM)
        for p in procs:
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()


def main():
    if not BIN or not os.access(BIN, os.X_OK):
        say("Xray из 3x-ui не найден: проверка невозможна")
        return 2
    try:
        cfg = json.load(open(CONF))
    except Exception as e:
        say("не удалось прочитать настройки Xray (%s): %s" % (CONF, e))
        return 2
    inb = {i.get("port"): i for i in cfg.get("inbounds", [])}
    user_in, tun_in = inb.get(USER_PORT), inb.get(TUN_PORT)
    if not user_in or not tun_in:
        say("в настройках Xray нет инбаундов пользователей/туннеля (порты %d/%d)" % (USER_PORT, TUN_PORT))
        return 2
    for p in (T_USER, T_TUN, T_SOCKS):
        if port_busy(p):
            say("порт %d занят: проверка невозможна" % p)
            return 2
    try:
        uid = user_in["settings"]["clients"][0]["id"]
        xh = copy.deepcopy(user_in["streamSettings"]["xhttpSettings"])
    except Exception:
        say("не удалось прочитать клиента или xhttp-настройки инбаунда пользователей")
        return 2
    outs = cfg.get("outbounds", [])
    direct = next((o.get("tag") for o in outs if o.get("protocol") == "freedom" and o.get("tag")), None)
    if not direct:
        say("в настройках Xray нет исходящего freedom: проверка невозможна")
        return 2

    def server(case):
        u, t = copy.deepcopy(user_in), copy.deepcopy(tun_in)
        u["port"], t["port"] = T_USER, T_TUN
        u["listen"] = t["listen"] = "127.0.0.1"
        rules = []
        for r in copy.deepcopy(cfg.get("routing", {}).get("rules", [])):
            if r.get("outboundTag") == "api" or "api" in (r.get("inboundTag") or []):
                continue
            if case == "control" and r.get("outboundTag") == "r-tunnel":
                r["outboundTag"] = direct
            rules.append(r)
        if case == "notag":
            for c in t.get("settings", {}).get("clients", []):
                c.pop("reverse", None)
        return {"log": {"loglevel": "none"}, "inbounds": [u, t], "outbounds": copy.deepcopy(outs),
                "routing": {"domainStrategy": cfg.get("routing", {}).get("domainStrategy", "AsIs"), "rules": rules}}

    client = {"log": {"loglevel": "none"},
              "inbounds": [{"listen": "127.0.0.1", "port": T_SOCKS, "protocol": "socks", "settings": {"udp": False}}],
              "outbounds": [{"protocol": "vless",
                             "settings": {"address": "127.0.0.1", "port": T_USER, "id": uid, "encryption": "none"},
                             "streamSettings": {"network": "xhttp", "security": "none", "xhttpSettings": xh}}]}
    res = {}
    with tempfile.TemporaryDirectory() as tmp:
        for case in ("control", "nobridge", "notag"):
            res[case] = run_case(case, server(case), client, tmp)
    say("  контроль (прямой выход включён вручную): HTTP %s %s" % (res["control"], "— проверка исправна" if res["control"] == "204" else "— НЕ прошёл"))
    say("  моста нет: HTTP %s %s" % (res["nobridge"], "— выхода нет" if res["nobridge"] == "000" else "— ЕСТЬ ВЫХОД"))
    say("  тега туннеля нет: HTTP %s %s" % (res["notag"], "— выхода нет" if res["notag"] == "000" else "— ЕСТЬ ВЫХОД"))
    if res["control"] != "204" or res["nobridge"] is None or res["notag"] is None:
        say("ИТОГ: проверить не удалось (контроль не прошёл или тестовый Xray не поднялся)")
        return 2
    if res["nobridge"] != "000" or res["notag"] != "000":
        say("ИТОГ: УТЕЧКА — без моста трафик пользователей выходит в интернет с IP RELAY")
        return 1
    say("ИТОГ: без моста RELAY трафик пользователей в интернет не выпускает")
    return 0


if __name__ == "__main__":
    sys.exit(main())
__CHAIN_EOF_FAILCLOSED_PY__

  cat > "$D/speedtest.py" <<'__CHAIN_EOF_SPEEDTEST_PY__'
#!/usr/bin/env python3
# chain-speedtest — скорость цепочки, измеренная на RELAY (без вашей линии до RELAY): клиент на RELAY → nginx → туннель → BACKEND → интернет.
# Измеряется скорость «вниз» и «вверх» для двух профилей отправки, чтобы было видно, что даёт настройка:
#   прежний — POST 1 МБ и пауза 30 мс (значения Xray по умолчанию, так работают клиенты без настройки);
#   текущий — параметры из инбаунда пользователей, то есть то, что клиенты получают с подпиской.
# Использование: chain-speedtest [--size МБ] [--quick] [--check]
#   --size N   объём передачи в каждую сторону (по умолчанию 40 МБ);  --quick — 15 МБ
#   --check    быстрая проверка для автоматики: передача 6 МБ в обе стороны с текущим профилем; код возврата 0 — работает, 1 — нет
# Меняются только временные процессы: рабочие настройки и клиенты не затрагиваются.
import json, os, re, signal, socket, sqlite3, subprocess, sys, tempfile, threading, time

ARGS = sys.argv[1:]
CHECK = "--check" in ARGS
QUICK = "--quick" in ARGS
SIZE_MB = 6 if CHECK else (15 if QUICK else 40)
if "--size" in ARGS:
    try:
        SIZE_MB = max(2, int(ARGS[ARGS.index("--size") + 1]))
    except (ValueError, IndexError):
        print("использование: chain-speedtest [--size МБ] [--quick] [--check]"); sys.exit(2)
CONF = os.environ.get("CHAIN_SETUP_CONF", "/root/.chain-setup.conf")
DB = os.environ.get("CHAIN_XUI_DB", "/etc/x-ui/x-ui.db")
ADDR = os.environ.get("CHAIN_SPEED_ADDR", "127.0.0.1")
PORT = int(os.environ.get("CHAIN_SPEED_PORT", "443"))
PIN = os.environ.get("CHAIN_SPEED_PIN", "")                     # только для тестового стенда
DOWN = os.environ.get("CHAIN_SPEED_DOWN_URL", "https://speed.cloudflare.com/__down?bytes={bytes}")
UP = os.environ.get("CHAIN_SPEED_UP_URL", "https://speed.cloudflare.com/__up")
SKIP_BRIDGE = os.environ.get("CHAIN_SPEED_SKIP_BRIDGE_CHECK") == "1"
KEY = os.environ.get("CHAIN_RESTART_KEY", "/root/.ssh/chain-restart")
SOCKS = 21486
OLD = {"scMaxEachPostBytes": "1000000", "scMinPostsIntervalMs": "30"}


def conf(k):
    try:
        for line in open(CONF, encoding="utf-8"):
            if line.startswith(k + "="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def xray_bin():
    b = os.environ.get("CHAIN_XRAY_BIN")
    if b:
        return b
    import glob
    for p in sorted(glob.glob("/usr/local/x-ui/bin/xray-linux-*")):
        if not p.endswith(".prev"):
            return p
    return ""


def cpu_sample():
    with open("/proc/stat") as f:
        v = [int(x) for x in f.readline().split()[1:8]]
    return sum(v) - v[3] - v[4], sum(v)


def cpu_pct(a, b):
    return 100.0 * (b[0] - a[0]) / max(1, b[1] - a[1])


def backend_cpu(out, key):
    """Загрузка процессора BACKEND за время передачи: команда «cpu» ограниченного ключа (если компоненты BACKEND обновлены)."""
    ip, port = conf("BACKEND_IP"), conf("BACKEND_PORT") or "22"
    if not ip or not os.access(KEY, os.R_OK):
        return
    try:
        r = subprocess.run(["ssh", "-i", KEY, "-p", port, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                            "-o", "ConnectTimeout=8", "root@" + ip, "cpu"], capture_output=True, text=True, timeout=20)
        m = re.search(r"cpu=(\d+)", r.stdout)
        if m:
            out[key] = int(m.group(1))
    except Exception:
        pass


def bridge_conns():
    r = subprocess.run('ss -tnH state established "( sport = :21444 )" 2>/dev/null | wc -l', shell=True, capture_output=True, text=True)
    return int((r.stdout or "0").strip() or 0)


def client_cfg(xh, uid, domain):
    tls = {"serverName": domain, "fingerprint": "chrome", "alpn": ["h2"]}
    if PIN:
        tls["pinnedPeerCertSha256"] = PIN
    return {"log": {"loglevel": "none"},
            "inbounds": [{"listen": "127.0.0.1", "port": SOCKS, "protocol": "socks", "settings": {"udp": False}}],
            "outbounds": [{"protocol": "vless", "settings": {"address": ADDR, "port": PORT, "id": uid, "encryption": "none"},
                           "streamSettings": {"network": "xhttp", "security": "tls", "tlsSettings": tls, "xhttpSettings": xh}}]}


def curl(args, timeout):
    r = subprocess.run(["curl", "-s", "-o", "/dev/null", "--max-time", str(timeout), "--socks5-hostname", "127.0.0.1:%d" % SOCKS,
                        "-w", "%{speed_download} %{speed_upload} %{http_code} %{size_download} %{size_upload}"] + args, capture_output=True, text=True)
    f = (r.stdout.strip().split() + ["0"] * 5)[:5]
    return float(f[0]), float(f[1]), f[2], int(float(f[3])), int(float(f[4]))


def measure(name, xh, uid, domain, xb, tmp, backend=True):
    """Возвращает словарь с результатами одного профиля."""
    cfgp = os.path.join(tmp, "c.json")
    json.dump(client_cfg(xh, uid, domain), open(cfgp, "w"))
    t = subprocess.run([xb, "run", "-test", "-c", cfgp], capture_output=True, text=True)
    if t.returncode != 0:
        return {"name": name, "err": "Xray не принял тестовую конфигурацию: " + ((t.stdout + t.stderr).strip().splitlines() or ["?"])[-1][:120]}
    p = subprocess.Popen([xb, "run", "-c", cfgp], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    res = {"name": name}
    try:
        for _ in range(40):
            try:
                socket.create_connection(("127.0.0.1", SOCKS), timeout=0.3).close()
                break
            except OSError:
                time.sleep(0.15)
        else:
            res["err"] = "тестовый клиент не запустился"
            return res
        n = SIZE_MB * 1000000
        tmo = max(40, SIZE_MB * 4)
        bk = {}
        # скачивание
        c0 = cpu_sample(); th = threading.Thread(target=backend_cpu, args=(bk, "down")) if backend else None
        if th: th.start()
        sd, _, code, got, _ = curl([DOWN.format(bytes=n)], tmo)
        c1 = cpu_sample()
        if th: th.join()
        res.update(down=sd * 8 / 1e6, down_code=code, down_got=got, cpu_relay_down=cpu_pct(c0, c1))
        # отдача
        fp = os.path.join(tmp, "up.bin")
        with open(fp, "wb") as f:
            for _ in range(SIZE_MB):
                f.write(os.urandom(1000000))
        c0 = cpu_sample(); th = threading.Thread(target=backend_cpu, args=(bk, "up")) if backend else None
        if th: th.start()
        _, su, code, _, sent = curl(["-X", "POST", "--data-binary", "@" + fp, UP], tmo)
        c1 = cpu_sample()
        if th: th.join()
        os.unlink(fp)
        res.update(up=su * 8 / 1e6, up_code=code, up_sent=sent, cpu_relay_up=cpu_pct(c0, c1), cpu_backend_down=bk.get("down"), cpu_backend_up=bk.get("up"))
    finally:
        p.send_signal(signal.SIGTERM)
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()
    return res


def main():
    domain = conf("DOMAIN")
    xb = xray_bin()
    if not domain or not xb or not os.access(xb, os.X_OK):
        print("нет данных установки или Xray из 3x-ui: запускать на RELAY, настроенном этим скриптом"); return 2
    try:
        db = sqlite3.connect(DB, timeout=10)
        st, se = db.execute("select stream_settings, settings from inbounds where port = 21443 limit 1").fetchone()
        xh = json.loads(st)["xhttpSettings"]
        uid = json.loads(se)["clients"][0]["id"]
    except Exception as e:
        print("не удалось прочитать инбаунд пользователей из базы 3x-ui: %s" % e); return 2
    if not SKIP_BRIDGE and bridge_conns() < 1:
        print("мост не подключён: измерять нечего (chain-status, journalctl -u chain-bridge на BACKEND)"); return 1
    tuned = any(str(xh.get(k, OLD[k])) != OLD[k] for k in OLD)
    with tempfile.TemporaryDirectory() as tmp:
        if CHECK:
            # коды возврата: 0 — текущий профиль работает; 1 — прежний работает, а текущий нет (настройку надо откатить);
            # 3 — не прошёл ни один профиль (тестовый сервер недоступен, проверить нельзя)
            good = lambda r: not r.get("err") and r.get("down_code") == "200" and r.get("up_code") == "200" and r.get("down", 0) > 0 and r.get("up", 0) > 0
            cur = measure("текущий", xh, uid, domain, xb, tmp, backend=False)
            if good(cur):
                print("проверка скорости: вниз %.0f, вверх %.0f Мбит/с" % (cur["down"], cur["up"])); return 0
            if tuned:
                old = measure("прежний", dict(xh, **OLD), uid, domain, xb, tmp, backend=False)
                if good(old):
                    print("проверка скорости: с настроенными параметрами передача не проходит (HTTP вниз %s, вверх %s), с прежними проходит" % (cur.get("down_code"), cur.get("up_code"))); return 1
            print("проверка скорости: тестовый сервер недоступен, проверить нельзя (%s)" % (cur.get("err") or "HTTP вниз %s, вверх %s" % (cur.get("down_code"), cur.get("up_code")))); return 3
        print("Скорость цепочки, измеренная на RELAY (без вашего канала до RELAY), %d МБ в каждую сторону" % SIZE_MB)
        results = []
        old_xh = dict(xh); old_xh.update(OLD)
        for name, x in ((("прежний (POST 1 МБ, пауза 30 мс)", old_xh),) + ((("текущий (из подписки)", xh),) if tuned else ())):
            print("  измеряю: %s …" % name, flush=True)
            results.append(measure(name, x, uid, domain, xb, tmp))
    print()
    print("  %-36s %12s %12s %10s" % ("профиль отправки", "вниз", "вверх", "вверх/вниз"))
    for r in results:
        if r.get("err"):
            print("  %-36s %s" % (r["name"], r["err"])); continue
        bad = r.get("down_code") != "200" or r.get("up_code") != "200"
        ratio = r["up"] / r["down"] if r["down"] else 0
        print("  %-36s %7.0f Мбит/с %7.0f Мбит/с %9.2f%s" % (r["name"], r["down"], r["up"], ratio, "   (HTTP %s/%s)" % (r.get("down_code"), r.get("up_code")) if bad else ""))
    good = [r for r in results if not r.get("err")]
    if not good:
        return 1
    cur = good[-1]
    cp = lambda a, b: "%d%%" % a if a is not None else "—"
    print("  процессор во время передачи: RELAY %.0f%% (вниз) / %.0f%% (вверх); BACKEND %s / %s" % (cur["cpu_relay_down"], cur["cpu_relay_up"], cp(cur.get("cpu_backend_down"), 0), cp(cur.get("cpu_backend_up"), 0)))
    print()
    if tuned and len(good) == 2 and good[0]["up"] > 0:
        gain = (good[1]["up"] / good[0]["up"] - 1) * 100
        print("  Вывод: настроенные параметры отправки дают %+.0f%% к скорости вверх." % gain)
    elif not tuned:
        print("  Вывод: параметры отправки в инбаунде не заданы: клиенты работают как «прежний» профиль. Запустите скрипт — он предложит обновить компоненты.")
    hi = max(cur["cpu_relay_down"], cur["cpu_relay_up"], cur.get("cpu_backend_down") or 0, cur.get("cpu_backend_up") or 0)
    if cur["up"] >= 0.7 * cur["down"]:
        print("  Серверная часть не ограничивает отдачу (вверх не меньше 70%% от вниз).\n  Если на телефоне вверх заметно ниже, смотрите линию оператора и обновление подписки в приложении.")
    elif hi >= 85:
        print("  Упирается в процессор (до %.0f%%): нужен более мощный сервер или меньше одновременной нагрузки." % hi)
    else:
        print("  Вверх ниже вниз, процессор не загружен: повторите тест позже (скорость до тестового сервера и в самом интернете меняется) и сравните с --size 80.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
__CHAIN_EOF_SPEEDTEST_PY__

  cat > "$D/speed-tune.py" <<'__CHAIN_EOF_SPEED_TUNE_PY__'
#!/usr/bin/env python3
# Параметры отправки XHTTP в инбаунде пользователей (порт 21443): размер POST и пауза между POST.
# Они же попадают в ссылку подписки (extra), поэтому клиенты получают их при обновлении подписки; серверу значения нужны, чтобы принимать крупные POST
# (сервер по умолчанию отвергает POST больше 1 МБ).
#   apply   задать значения, если они не заданы или равны значениям Xray по умолчанию (1000000, 30 и 30); прежние значения запоминаются
#   revert  вернуть запомненные прежние значения
#   status  показать текущие значения
# Значения — диапазоны, а не одно число: фиксированная пауза 30 мс — известная примета, случайный разброс её сглаживает.
# Нужен перезапуск x-ui (его делает вызывающий скрипт). Код возврата: 0 — готово, 1 — ошибка.
import json, os, shutil, sqlite3, sys, time

DB = os.environ.get("CHAIN_XUI_DB", "/etc/x-ui/x-ui.db")
PREV = os.environ.get("CHAIN_SPEED_TUNE_PREV", "/var/lib/chain/speed-tune.prev")
# scMaxBufferedPosts (только сервер): сколько POST, пришедших вне очереди, сервер держит в памяти на сессию (по умолчанию 30 × до 2 МБ = до 60 МБ на сессию);
# 12 хватает: при паузе 8–14 мс и RTT в десятки миллисекунд вне очереди приходят единицы POST
WANT = {"scMaxEachPostBytes": "1200000-2000000", "scMinPostsIntervalMs": "8-14", "scMaxBufferedPosts": 12}
DEFAULT = {"scMaxEachPostBytes": "1000000", "scMinPostsIntervalMs": "30", "scMaxBufferedPosts": 30}
cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
if not os.path.exists(DB):
    print("база 3x-ui не найдена: %s" % DB); sys.exit(1)
con = sqlite3.connect(DB, timeout=30)
row = con.execute("select id, stream_settings from inbounds where port = 21443 limit 1").fetchone()
if not row:
    print("инбаунд пользователей (порт 21443) не найден"); sys.exit(1)
iid, raw = row
ss = json.loads(raw)
xh = ss.setdefault("xhttpSettings", {})
def save():
    con.execute("update inbounds set stream_settings = ? where id = ?", (json.dumps(ss, ensure_ascii=False), iid)); con.commit()
if cmd == "status":
    for k in WANT:
        print("%s=%s" % (k, xh.get(k, "(не задан, по умолчанию %s)" % DEFAULT[k])))
elif cmd == "apply":
    prev, changed = {}, []
    for k, v in WANT.items():
        cur = xh.get(k)
        if cur is None or str(cur) == str(DEFAULT[k]):
            prev[k] = cur; xh[k] = v; changed.append(k)
    if not changed:
        print("unchanged"); sys.exit(0)
    shutil.copy2(DB, "%s.bak-speed-%s" % (DB, time.strftime("%Y%m%d-%H%M%S")))
    os.makedirs(os.path.dirname(PREV), exist_ok=True)
    old = json.load(open(PREV)) if os.path.exists(PREV) else {}
    for k, v in prev.items():
        old.setdefault(k, v)   # прежние значения из первого применения не затираются
    json.dump(old, open(PREV, "w"))
    save()
    print("changed: " + ", ".join("%s=%s" % (k, WANT[k]) for k in changed))
elif cmd == "revert":
    if not os.path.exists(PREV):
        print("нет сохранённых прежних значений"); sys.exit(1)
    prev = json.load(open(PREV))
    for k, v in prev.items():
        if v is None: xh.pop(k, None)
        else: xh[k] = v
    save(); os.remove(PREV)
    print("reverted")
else:
    print("использование: speed-tune.py apply|revert|status"); sys.exit(1)
__CHAIN_EOF_SPEED_TUNE_PY__

  # BACKEND: firewall — только SSH (все остальные входящие закрыты)
  cat > "$D/ufw-backend.sh" <<'EOF'
set -e
ports=$( {
  ss -tlnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }'
  sshd -T 2>/dev/null | awk '/^port / { print $2 }'
  systemctl show ssh.socket -p Listen 2>/dev/null | sed -n 's/^Listen=.*:\([0-9][0-9]*\) (Stream)$/\1/p'
  [ -n "${SSH_CONNECTION:-}" ] && echo "$SSH_CONNECTION" | awk '{ print $4 }'
} | grep -E '^[0-9]+$' | sort -un || true )
[ -n "$ports" ] || { echo "sshd port not found" >&2; exit 1; }
command -v ufw >/dev/null 2>&1 || { apt-get -o DPkg::Lock::Timeout=300 install -y ufw; }
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
for p in $ports; do ufw allow "$p/tcp"; done
ufw --force enable
ufw status
EOF

  # BACKEND: откат моста
  cat > "$D/uninstall-backend.sh" <<'EOF'
[ -x /usr/local/sbin/chain-memory ] && /usr/local/sbin/chain-memory remove >/dev/null 2>&1 || true
systemctl disable --now chain-watchdog.timer chain-bridge chain-update-bridge.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/chain-watchdog.service /etc/systemd/system/chain-watchdog.timer /usr/local/bin/chain-watchdog
rm -rf /var/lib/chain-bridge
rm -f /etc/systemd/system/chain-bridge.service /usr/local/bin/chain-xray /usr/local/bin/chain-xray.prev /usr/local/bin/chain-set-relay \
  /etc/systemd/system/chain-update-bridge.service /etc/systemd/system/chain-update-bridge.timer /usr/local/bin/chain-update-bridge /run/chain-update.lock
rm -rf /etc/chain-bridge
userdel chainbridge >/dev/null 2>&1 || true
rm -f /etc/sysctl.d/99-relay-network-tuning.conf /etc/modules-load.d/relay-bbr.conf
systemctl daemon-reload
rm -f /usr/local/bin/chain-restart-bridge /usr/local/bin/chain-incident /etc/logrotate.d/chain-incidents /etc/systemd/journald.conf.d/chain-limits.conf
rm -rf /var/lib/chain-incident
rm -f /var/log/chain-incidents.log /var/log/chain-incidents.log.*
[ -f /root/.ssh/authorized_keys ] && sed -i '/ chain-restart@/d' /root/.ssh/authorized_keys
sysctl --system >/dev/null 2>&1 || true
exit 0
EOF
}
