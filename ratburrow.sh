#!/usr/bin/env bash
RB_VERSION="4.14"
NAME="RatBurrow"

set -u
set -o pipefail
export LC_ALL=C.UTF-8   # одинаковая работа с кириллицей независимо от локали сервера

# ───────────────────────── пути (переопределяются для тестов) ─────────────────────────
UFW_SYSCTL="${UFW_SYSCTL:-/etc/ufw/sysctl.conf}"
CONF_FILE="${CONF_FILE:-/root/.chain-setup.conf}"
REPORT_FILE="${REPORT_FILE:-/root/chain-setup-report.txt}"
LOG="${LOG:-/var/log/chain-setup.log}"
MARKER_FILE="${MARKER_FILE:-/root/.chain-setup.installed}"
PANEL_PORT=999
HONEYPOT_URL="${HONEYPOT_URL:-https://raw.githubusercontent.com/cryptonoise/ratburrow/refs/heads/main/rb-honeypot.sh}"   # генератор «живого» сайта (отдельный файл в репозитории)
HONEYPOT_FILE="${HONEYPOT_FILE:-}"   # локальный rb-honeypot.sh вместо скачивания (для тестов/офлайна)
HP_PROXY=""
SUB_TITLE="${SUB_TITLE:-}"   # название подписки в клиентах (Incy, Happ): спрашивается при установке
CHAIN_USER_PORT=21443     # 127.0.0.1: инбаунд пользователей (за nginx)
CHAIN_TUNNEL_PORT=21444   # 127.0.0.1: инбаунд туннеля, к которому подключается мост BACKEND (за nginx)
SELFTEST_PORT=21481       # 127.0.0.1: временный клиент для проверки цепочки
XRAY_VER="${XRAY_VER:-26.10.31}"   # закреплённая версия Xray для моста BACKEND (проверена; меняется пунктом меню «Обновить Xray»)
XUI_VER="${XUI_VER:-v3.11.0}"       # закреплённая версия панели 3x-ui для новой установки
TOTAL=12
STEP=0
SUB=0; SUBL=""; INFO=""
CHAIN_USER_ID=""; CHAIN_SUB_ID=""; TUNNEL_UUID=""; SUB_PATHS=""; TUNNEL_OBFS=0; VER_PATH=""

# ───────────────────────── цвета ─────────────────────────
if [ -t 1 ]; then
  R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; CYN=$'\e[36m'
else
  R=; B=; DIM=; RED=; GRN=; YLW=; BLU=; CYN=
fi
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# ───────────────────────── вывод ─────────────────────────
rule()  { printf '%s' "$CYN"; printf '═%.0s' $(seq 1 60); printf '%s\n' "$R"; }
thin()  { printf '%s' "$DIM"; printf '─%.0s' $(seq 1 60); printf '%s\n' "$R"; }
ok()    { printf '  %s✔%s %s\n' "$GRN" "$R" "$*"; }
warn()  { printf '  %s▲%s %s\n' "$YLW" "$R" "$*"; }
fail()  { printf '  %s✖%s %s\n' "$RED" "$R" "$*"; }
info()  { printf '  %s•%s %s\n' "$BLU" "$R" "$*"; }
kv()    { printf '  %s%-14s%s %s\n' "$DIM" "$1" "$R" "$2"; }

section() {
  STEP=$((STEP + 1))
  SUB=0
  echo
  printf '%s[%d/%d]%s %s%s%s\n' "$CYN" "$STEP" "$TOTAL" "$R" "$B" "$*" "$R"
  thin
}

banner() {
  clear 2>/dev/null || true
  rule
  printf '  %s%s%s\n' "$B" "$NAME" "$R"
  printf '  %sверсия %s%s\n' "$DIM" "$RB_VERSION" "$R"
  rule
  echo "  Защищённый канал RELAY ← BACKEND:"
  echo "   • подготовка сервера: обновление, SSH-порт и ключ, fail2ban, автообновления"
  echo "   • RELAY (РФ): nginx + Let's Encrypt, «живой» сайт-приманка, панель 3x-ui и подписка"
  echo "   • BACKEND (за рубежом): мост Xray сам подключается к RELAY, входящие порты закрыты"
  echo "   • канал: VLESS + XHTTP по HTTPS на 443, секретные пути, всё остальное — 404"
  echo "   • клиент: Incy и любой клиент на Xray-core (подписка из панели)"
  rule
  echo
  rd -r -p "  Нажмите Enter, чтобы начать." _
  echo
}

# ───────────────────────── ввод ─────────────────────────
# rd — чтение с терминала (даже если stdin — пайп); при закрытом вводе скрипт завершается,
# а не крутится в бесконечном цикле
rd() {
  local rc
  if ( : < /dev/tty ) 2>/dev/null; then read "$@" < /dev/tty; else read "$@"; fi
  rc=$?
  if [ $rc -ne 0 ]; then
    echo
    die "ввод недоступен (терминал закрыт). Запустите скрипт в интерактивной сессии: bash burrow.sh"
  fi
}

ask() {  # ask VAR "Вопрос" "по умолчанию"
  local __v="$1" q="$2" d="${3:-}" a
  if [ -n "$d" ]; then
    rd -r -p "${B}?${R} $q ${DIM}[$d]${R}: " a
    a="${a:-$d}"
  else
    rd -r -p "${B}?${R} $q: " a
  fi
  printf -v "$__v" '%s' "$a"
}

# сбрасываем всё, что накопилось в буфере терминала (случайные Enter, хвост вставленного ключа),
# иначе «залежавшийся» Enter мгновенно ответит «да» на следующий вопрос
drain_tty() {
  ( : < /dev/tty ) 2>/dev/null || return 0
  local _j
  while IFS= read -r -t 0.05 -n 1 _j < /dev/tty; do :; done
}

confirm() {  # confirm "вопрос" — единый формат для всех вопросов да/нет: Enter = да
  local a def=y hint="Enter или y — да / n — нет"
  drain_tty
  while true; do
    rd -r -p "${B}?${R} $1 ${DIM}[$hint]${R}: " a
    case "${a:-$def}" in
      y | Y | yes | YES | д | Д) return 0 ;;
      n | N | no | NO | н | Н | нет) return 1 ;;
      *) printf '  %sВведите Enter или y (да) / n (нет)%s\n' "$DIM" "$R" ;;
    esac
  done
}

valid_ip()   { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ! [[ "$1" =~ (^|\.)(25[6-9]|2[6-9][0-9]|[3-9][0-9]{2})(\.|$) ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }
valid_dom()  { [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }

# ── «что происходит сейчас»: строка под спиннером ──
# Самый «молодой» не-shell потомок процесса шага: показывает, что реально выполняется
step_proc() {  # step_proc PID
  ps -e -o pid=,ppid=,comm= --sort=start_time 2>/dev/null | awk -v root="$1" '
    $1 == root { d[$1] = 1; next }
    ($2 in d)  { d[$1] = 1; if ($3 !~ /^(sh|bash|dash|timeout)$/) last = $3 }
    END { print last }'
}

# Расшифровка процесса для человека (частые «долгие» операции на слабых серверах)
proc_hint() {
  case "$1" in
    update-initramf*|mkinitramfs|cpio) echo "сборка initramfs (на слабом сервере — минуты) [$1]" ;;
    dkms|depmod)                       echo "сборка модулей ядра [$1]" ;;
    grub-mkconfig|update-grub*|os-prober) echo "обновление загрузчика GRUB [$1]" ;;
    mandb|man-db)                      echo "индекс man-страниц [$1]" ;;
    ldconfig)                          echo "кеш библиотек [$1]" ;;
    needrestart)                       echo "проверка служб для перезапуска [$1]" ;;
    systemctl)                         echo "перезапуск служб [$1]" ;;
    update-ca-certi*)                  echo "обновление сертификатов [$1]" ;;
    apt-get|apt|dpkg)                  echo "процесс: $1" ;;
    *)                                 echo "процесс: $1" ;;
  esac
}

# Машинный статус apt (APT::Status-Fd) → понятная строка
apt_status_text() {  # apt_status_text ФАЙЛ
  local line kind a pct msg
  line=$(tail -n1 "$1" 2>/dev/null)
  [ -n "$line" ] || return 0
  IFS=: read -r kind a pct msg <<<"$line"
  pct=${pct%%.*}
  case "$kind" in
    dlstatus)
      msg=$(printf '%s' "$msg" | sed -E 's/Downloading file ([0-9]+) of ([0-9]+)/файл \1 из \2/; s/\(([^)]*) remaining\)/(осталось \1)/')
      printf 'Загрузка: %s%% — %s' "$pct" "$msg" ;;
    pmstatus)
      msg=$(printf '%s' "$msg" | sed -E 's/^Preparing /Подготовка /; s/^Unpacking /Распаковка /; s/^Setting up /Настройка /; s/^Configuring /Настройка /; s/^Installed /Установлен /; s/^Removing /Удаление /; s/^Removed /Удалён /; s/^Running dpkg/Запуск dpkg/; s/^Processing triggers for /Обработка триггеров: /')
      printf 'Установка: %s%% — %s' "$pct" "$msg" ;;
  esac
}

# Последняя «живая» строка лога, появившаяся после начала шага (например, ожидание блокировки apt)
step_logline() {  # step_logline СМЕЩЕНИЕ_ЛОГА
  local sz
  sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  [ "$sz" -gt "$1" ] || return 0
  tail -c 4096 "$LOG" 2>/dev/null | tr '\r\000' '\n\n' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' \
    | grep -v '^[[:space:]]*$' | tail -n1 \
    | sed -E 's/Waiting for cache lock: Could not get lock ([^ ]+)\. It is held by process ([0-9]+) \(([^)]*)\).*/Ожидание блокировки apt — её держит процесс \2 (\3)/'
}

# Собирает строку INFO. Вызывается из step_run и использует его локальные переменные
# (lastsig, lastchg, proc, tick) — так работает динамическая область видимости bash.
step_info() {  # step_info PID ФАЙЛ_СТАТУСА СМЕЩЕНИЕ_ЛОГА
  local sig st idle
  sig="$(stat -c %s "$2" "$LOG" 2>/dev/null | tr '\n' ' ')"
  if [ "$sig" != "$lastsig" ]; then lastsig=$sig; lastchg=$SECONDS; fi
  st=$(apt_status_text "$2")
  [ -n "$st" ] || st=$(step_logline "$3")
  if [ $((tick % 2)) -eq 0 ]; then proc=$(step_proc "$1"); fi
  INFO=$st
  [ -n "$proc" ] && INFO="${INFO:+$INFO · }$(proc_hint "$proc")"
  idle=$((SECONDS - lastchg))
  if [ "$idle" -ge 30 ]; then INFO="${INFO:+$INFO · }нет новых сообщений ${idle}с, процесс выполняется"; fi
}

# ───────────────────────── выполнение шагов с анимацией ─────────────────────────
# Строка 1: спиннер + название + время. Строка 2: что происходит прямо сейчас
# (прогресс apt, текущий пакет, активный процесс, ожидание блокировки).
# Без терминала (лог/pipe) раз в минуту печатается строка-«пульс».
step_run() {  # step_run [-s] "Описание" команда args...   (-s: при ошибке только предупреждение)
  local soft=0
  if [ "${1:-}" = "-s" ]; then soft=1; shift; fi
  local label="$1"
  shift
  local t0=$SECONDS pid rc i=0 clr="" tty=0 sf off cols lab
  local lastsig="" lastchg=$SECONDS proc="" tick=0
  if [ -t 1 ]; then tty=1; clr=$'\r\033[2K\n\033[2K\033[A\r'; fi
  sf=$(mktemp 2>/dev/null) || sf=/dev/null
  off=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  cols=$(tput cols 2>/dev/null || echo 80)
  lab=${label:0:$((cols - 14))}
  ( export STEP_STATUS_FILE="$sf"; "$@" ) </dev/null >>"$LOG" 2>&1 &
  pid=$!
  if [ $tty -eq 1 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      if [ $((i % 10)) -eq 0 ]; then
        step_info "$pid" "$sf" "$off"
        tick=$((tick + 1))
      fi
      printf '\r  %s%s%s %s %s(%ds)%s\033[K\n    %s↳ %s%s\033[K\033[A' \
        "$CYN" "${SPIN[i % 10]}" "$R" "$lab" "$DIM" $((SECONDS - t0)) "$R" \
        "$DIM" "${INFO:0:$((cols - 8))}" "$R"
      i=$((i + 1))
      sleep 0.1
    done
  else
    while kill -0 "$pid" 2>/dev/null; do
      sleep 1
      i=$((i + 1))
      if [ $((i % 60)) -eq 0 ]; then
        step_info "$pid" "$sf" "$off"
        tick=$((tick + 1))
        printf '    … %s (%dс)%s\n' "$label" $((SECONDS - t0)) "${INFO:+ — $INFO}"
      fi
    done
  fi
  wait "$pid"
  rc=$?
  [ "$sf" != /dev/null ] && rm -f "$sf"
  INFO=""
  # очистка строк спиннера и итог — одним printf, чтобы ничто не вклинилось между ними
  if [ $rc -eq 0 ]; then
    printf '%s  %s✔%s %s %s(%dс)%s\n' "$clr" "$GRN" "$R" "$label" "$DIM" $((SECONDS - t0)) "$R"
  elif [ $soft -eq 1 ]; then
    printf '%s  %s▲%s %s — пропущено\n' "$clr" "$YLW" "$R" "$label"
  else
    printf '%s  %s✖%s %s\n' "$clr" "$RED" "$R" "$label"
    echo "${DIM}    ── последние строки лога ($LOG) ──${R}"
    tail -n 12 "$LOG" | sed 's/^/    /'
  fi
  return $rc
}

# ── apt: стадии с видимым прогрессом ──
sub() { SUB=$((SUB + 1)); SUBL="$STEP.$SUB"; }   # номер подэтапа в названии: «2.3»

# apt-get с машинным статусом (fd 3 → файл шага) и лимитом в секундах (0 = без лимита)
apt_run() {  # apt_run ЛИМИТ_СЕК аргументы apt-get...
  local lim="$1"; shift
  timeout --foreground "$lim" apt-get "${APT_OPTS[@]}" \
    -o Acquire::Retries=3 -o Acquire::http::Timeout=60 -o Acquire::https::Timeout=60 \
    -o APT::Status-Fd=3 "$@" 3>>"${STEP_STATUS_FILE:-/dev/null}"
}

# Холостой прогон: сколько пакетов будет затронуто и сколько нужно скачать
apt_simulate() {  # apt_simulate upgrade|dist-upgrade   (результат — в $APT_SIM_FILE)
  apt-get "${APT_OPTS[@]}" -s "$1" >"$APT_SIM_FILE" 2>&1 || { cat "$APT_SIM_FILE" >>"$LOG"; return 1; }
}

# Расчёт → загрузка → установка отдельными шагами: видно, на какой стадии идёт время
apt_upgrade_phase() {  # apt_upgrade_phase upgrade|dist-upgrade "Название" ЛИМИТ_УСТАНОВКИ_СЕК
  local mode="$1" title="$2" lim="${3:-0}" n r need rc
  APT_SIM_FILE=$(mktemp) || die "не удалось создать временный файл"
  sub; step_run "$SUBL $title: расчёт списка пакетов" apt_simulate "$mode" \
    || { rm -f "$APT_SIM_FILE"; die "apt не смог рассчитать обновления ($mode). Подробности — в $LOG"; }
  n=$(grep -c '^Inst ' "$APT_SIM_FILE")
  r=$(grep -c '^Remv ' "$APT_SIM_FILE")
  need=$(sed -n 's/^Need to get \(.*\) of archives\..*/\1/p' "$APT_SIM_FILE" | head -n1)
  need=${need%%/*}   # «скачать / всего» → только то, что ещё не лежит в кеше
  rm -f "$APT_SIM_FILE"
  if [ "${n:-0}" -eq 0 ] && [ "${r:-0}" -eq 0 ]; then
    ok "$title: обновлений нет"
    return 0
  fi
  info "$title: пакетов к установке/обновлению — $n$([ "${r:-0}" -gt 0 ] && echo ", к удалению — $r")${need:+, скачать — $need}"
  case "$need" in
    "" | "0 B"*) ;;
    *) sub; step_run "$SUBL $title: загрузка пакетов ($need)" apt_run 0 -d -y "$mode" \
         || die "не удалось загрузить пакеты ($mode). Проверьте сеть и зеркала apt. Подробности — в $LOG" ;;
  esac
  sub; step_run "$SUBL $title: установка (пакетов: $n)" apt_run "$lim" -y "$mode" || {
    rc=$?
    if [ "$rc" -eq 124 ]; then die "apt $mode завис или превысил лимит $((lim / 60)) минут. Проверьте /var/log/apt/term.log и /var/log/dpkg.log; возможен незавершённый dpkg или запрос действия.";
    else die "apt $mode завершился с ошибкой (код $rc). Подробности — в $LOG и /var/log/apt/term.log"; fi
  }
}

die() {
  echo
  fail "$*"
  echo "  ${DIM}Полный лог: $LOG${R}"
  exit 1
}

# сетевые твики: BBR, буферы TCP/UDP, MTU probing и др. (применяется на RELAY и BACKEND)
tune_network() {
  local f=/etc/sysctl.d/99-relay-network-tuning.conf
  modprobe tcp_bbr 2>/dev/null || true
  modprobe nf_conntrack 2>/dev/null || true   # чтобы nf_conntrack_max применился и на RELAY с NAT
  echo tcp_bbr > /etc/modules-load.d/relay-bbr.conf
  {
    echo "# relay-setup: сетевые твики"
    echo "net.core.default_qdisc=fq"
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then echo "net.ipv4.tcp_congestion_control=bbr"; fi
    printf '%s\n' \
      "net.core.rmem_max=33554432" \
      "net.core.wmem_max=33554432" \
      "net.ipv4.tcp_rmem=4096 262144 33554432" \
      "net.ipv4.tcp_wmem=4096 262144 33554432" \
      "net.ipv4.tcp_mtu_probing=1" \
      "net.ipv4.tcp_slow_start_after_idle=0" \
      "net.core.netdev_max_backlog=16384" \
      "net.core.somaxconn=4096" \
      "net.ipv4.tcp_max_syn_backlog=8192" \
      "net.ipv4.ip_local_port_range=10240 65535" \
      "net.ipv4.tcp_keepalive_time=300" \
      "net.ipv4.tcp_keepalive_intvl=30" \
      "net.ipv4.tcp_keepalive_probes=5" \
      "fs.file-max=1048576"
    if [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then echo "net.netfilter.nf_conntrack_max=262144"; fi
    if [ -e /proc/sys/net/mptcp/enabled ]; then echo "net.mptcp.enabled=0"; fi   # MPTCP не используется: лишнюю поверхность отключаем
  } > "$f"
  sysctl -q -p "$f" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
  # журнал systemd не должен разрастаться на маленьком VPS
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=200M\nMaxRetentionSec=14day\n' > /etc/systemd/journald.conf.d/chain-limits.conf
  systemctl restart systemd-journald >/dev/null 2>&1 || true
  return 0
}

# ───────────────────────── метка установки ─────────────────────────
marker_text() {  # marker_text статус роль(relay|backend) [версия Xray здесь] [версия Xray на втором сервере] — содержимое метки настройки канала
  cat <<EOF
STATUS=$1
ROLE=$2
INSTALLED_AT=$(date '+%F %T')
VERSION=$RB_VERSION
KIND=${INSTALL_KIND:-chain}
RELAY_IP=${RELAY_IP:-}
BACKEND_IP=${BACKEND_IP:-}
BACKEND_PORT=${BACKEND_PORT:-}
DOMAIN=${DOMAIN:-}
XUI_BY_SCRIPT=${XUI_BY_SCRIPT:-}
COMPONENTS=$RB_VERSION
XRAY_VERSION=${3:-}
XRAY_SOURCE=script
XRAY_UPDATED=$(date +%s)
PEER_XRAY_VERSION=${4:-}
PEER_XRAY_SEEN=$([ -n "${4:-}" ] && date +%s)
EOF
}
# метка на BACKEND (по SSH); до подключения к BACKEND тихо пропускается
write_marker_backend() {  # write_marker_backend статус [версия Xray на BACKEND] [версия Xray на RELAY]
  [ "${LOCAL_BACKEND:-0}" = 1 ] && return 0
  [ -n "${SSH_OPTS+x}" ] || return 0
  marker_text "$1" backend "${2:-}" "${3:-}" | ssh "${SSH_OPTS[@]}" "root@$BACKEND_IP" "umask 077; cat > '$MARKER_FILE'" >>"$LOG" 2>&1 ||
    warn "не удалось записать метку на BACKEND (см. лог)"
}
write_marker() {  # write_marker статус (in-progress | done | check-failed) — метки на RELAY (здесь) и на BACKEND, с версиями Xray
  local lv="" bv=""
  if [ "$1" != in-progress ]; then lv=$(local_xray_version); bv=$(backend_xray_version); fi
  ( umask 077; marker_text "$1" relay "$lv" "$bv" > "$MARKER_FILE" )
  chmod 600 "$MARKER_FILE"
  write_marker_backend "$1" "$bv" "$lv"
}
marker_get() { sed -n "s/^$1=//p" "$MARKER_FILE" 2>/dev/null | head -n1; }
# записать/заменить строку КЛЮЧ=значение в метке на RELAY (здесь) и на BACKEND
marker_set() { local k=$1 v=$2; [ -f "$MARKER_FILE" ] || return 0; if grep -q "^$k=" "$MARKER_FILE"; then sed -i "s|^$k=.*|$k=$v|" "$MARKER_FILE"; else printf '%s=%s\n' "$k" "$v" >> "$MARKER_FILE"; fi; }
marker_set_backend() {
  local k=$1 v=$2 cmd
  cmd=$(printf "f=%q; if grep -q '^%s=' \"\$f\"; then sed -i 's|^%s=.*|%s=%s|' \"\$f\"; else echo '%s=%s' >> \"\$f\"; fi" "$MARKER_FILE" "$k" "$k" "$k" "$v" "$k" "$v")
  bk "$cmd" >>"$LOG" 2>&1 || true
}
# версия Xray ядра 3x-ui на RELAY и версия Xray моста на BACKEND
local_xray_version() {
  local b
  for b in /usr/local/x-ui/bin/xray-linux-*; do
    case "$b" in *.prev) continue ;; esac
    [ -x "$b" ] && "$b" version 2>/dev/null | awk 'NR==1{print $2}'
    return 0
  done
}
backend_xray_version() { bk "/usr/local/bin/chain-xray version 2>/dev/null" 2>/dev/null | awk 'NR==1{print $2}'; }

# порты, на которых слушает sshd (+ порт текущего SSH-подключения; Ubuntu 22.10+ — ssh.socket)
ssh_ports() {
  {
    ss -tlnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }'
    sshd -T 2>/dev/null | awk '/^port / { print $2 }'
    systemctl show ssh.socket -p Listen 2>/dev/null | sed -n 's/^Listen=.*:\([0-9][0-9]*\) (Stream)$/\1/p'
    [ -n "${SSH_CONNECTION:-}" ] && echo "$SSH_CONNECTION" | awk '{ print $4 }'
  } | grep -E '^[0-9]+$' | sort -un
}

# базовые утилиты нужны ещё до вопросов (curl, dig, ssh, openssl, ss)
ensure_tools() {
  local miss=()
  command -v curl >/dev/null 2>&1 || miss+=(curl)
  command -v dig >/dev/null 2>&1 || miss+=(dnsutils)
  { command -v ssh >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; } || miss+=(openssh-client)
  command -v openssl >/dev/null 2>&1 || miss+=(openssl)
  command -v python3 >/dev/null 2>&1 || miss+=(python3)
  command -v ss >/dev/null 2>&1 || miss+=(iproute2)
  [ ${#miss[@]} -eq 0 ] && return 0
  info "устанавливаю: ${miss[*]}"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt-get -o DPkg::Lock::Timeout=300 update -y >>"$LOG" 2>&1 &&
    apt-get -o DPkg::Lock::Timeout=300 install -y "${miss[@]}" >>"$LOG" 2>&1
}

detect_relay_ip() {
  local ip=""
  for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')
    valid_ip "$ip" && break
    ip=""
  done
  if [ -z "$ip" ]; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1) }' | head -1)
  fi
  printf '%s' "$ip"
}

# ───────────────────────── DNS ─────────────────────────
dns_collect() {  # IPv4 из нескольких резолверов + системного
  local d
  for d in 8.8.8.8 1.1.1.1 77.88.8.8; do
    dig +short +time=3 +tries=1 A "$DOMAIN" @"$d" 2>/dev/null
  done
  getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{ print $1 }'
}

dns_check() {
  local all v6 x tgt="${DNS_TARGET:-$RELAY_IP}"
  while true; do
    all=$(dns_collect | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | sort -u | tr '\n' ' ')
    all="${all% }"
    v6=$(dig +short +time=3 +tries=1 AAAA "$DOMAIN" @8.8.8.8 2>/dev/null | grep ':' | head -1)
    if [ "$all" = "$tgt" ] && [ -z "$v6" ]; then
      ok "DNS: $DOMAIN → $tgt"
      return 0
    fi
    echo
    rule
    printf '  %s▲ Проблема с DNS%s\n' "$YLW" "$R"
    echo "  Домен:        $DOMAIN"
    echo "  Сейчас:       A: ${all:-нет}   AAAA: ${v6:-нет}"
    echo "  Должно быть:  A = $tgt (IP сервера, DNS only, TTL 1 мин), AAAA — удалить"
    echo "  ${DIM}(AAAA должен отсутствовать: клиенты и Let's Encrypt предпочитают IPv6, а канал настроен только на IPv4)${R}"
    rule
    rd -r -p "  Нажмите Enter, когда исправили (n — пропустить проверку): " x
    if [[ "$x" =~ ^[nNнН] ]]; then
      warn "проверка DNS пропущена — сертификат может не выпуститься"
      return 1
    fi
  done
}

# ───────────────────────── SSH к BACKEND ─────────────────────────
read_key() {
  local line default_key="" f tries=0
  if [ -n "${KEY_PATH:-}" ] && [ -f "$KEY_PATH" ]; then
    default_key="$KEY_PATH"
  else
    for f in /root/.ssh/id_ed25519 /root/.ssh/id_rsa /root/.ssh/id_ecdsa; do
      [ -f "$f" ] && { default_key="$f"; break; }
    done
  fi
  while true; do
    tries=$((tries + 1))
    [ $tries -le 5 ] || die "ключ не получен за 5 попыток"
    echo "${B}?${R} Приватный ключ root для BACKEND: путь к файлу или вставьте ключ целиком ${DIM}(ввод скрыт)${R}"
    [ -n "$default_key" ] && echo "  ${DIM}Enter — использовать $default_key${R}"
    IFS= rd -r -s line
    echo
    line="${line//$'\r'/}"
    if [ -z "$line" ]; then
      if [ -n "$default_key" ]; then KEY_FILE="$default_key"; else fail "ключ не указан"; continue; fi
    elif [[ "$line" == -----BEGIN* ]]; then
      KEY_FILE="$TMPD/key"
      printf '%s\n' "$line" > "$KEY_FILE"
      while IFS= rd -r -s line; do
        line="${line//$'\r'/}"
        printf '%s\n' "$line" >> "$KEY_FILE"
        [[ "$line" == -----END* ]] && break
      done
      chmod 600 "$KEY_FILE"
    elif [ -f "$line" ]; then
      KEY_FILE="$line"
    else
      fail "файл не найден: $line"
      continue
    fi
    if ssh-keygen -y -P "" -f "$KEY_FILE" > "$TMPD/key.pub" 2>/dev/null; then
      ok "ключ принят"
      [ "$KEY_FILE" != "$TMPD/key" ] && KEY_PATH="$KEY_FILE"
      return 0
    fi
    fail "ключ не читается (неверный формат или защищён паролем — такие не поддерживаются)"
    KEY_FILE=""
  done
}

# IP, SSH-порт и ключ для доступа к BACKEND (используется в тесте и удалении)
ask_backend() {
  while true; do
    ask BACKEND_IP "IP BACKEND" "${BACKEND_IP:-}"
    valid_ip "$BACKEND_IP" && break
    fail "неверный IP"
    BACKEND_IP=""
  done
  LOCAL_BACKEND=0
  if [ "$BACKEND_IP" = "${RELAY_IP:-}" ]; then
    LOCAL_BACKEND=1
    ok "это текущий сервер: действия выполняются локально (без SSH)"
    return 0
  fi
  while true; do
    ask BACKEND_PORT "SSH-порт BACKEND" "${BACKEND_PORT:-1119}"
    valid_port "$BACKEND_PORT" && break
    fail "неверный порт"
  done
  [ -n "${KEY_FILE:-}" ] || read_key
}

ssh_opts() {
  SSH_OPTS=(-i "$KEY_FILE" -p "$BACKEND_PORT" -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 -o ServerAliveCountMax=4
    -o ConnectTimeout=15 -o ControlMaster=auto -o "ControlPath=$TMPD/cm-%C" -o ControlPersist=1800)
}

LOCAL_BACKEND=0
bk() {
  if [ "${LOCAL_BACKEND:-0}" = 1 ]; then bash -c "$*"; else ssh "${SSH_OPTS[@]}" "root@$BACKEND_IP" "$@"; fi
}
rscript() {
  local f="$1"; shift
  if [ "${LOCAL_BACKEND:-0}" = 1 ]; then bash -s -- "$@" < "$f"; else ssh "${SSH_OPTS[@]}" "root@$BACKEND_IP" bash -s -- "$@" < "$f"; fi
}

ssh_connect() {
  local err np
  ssh_opts
  while true; do
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "root@$BACKEND_IP" true >/dev/null 2>"$TMPD/ssh.err"; then
      ok "Установлено"
      ok "SSH: root@$BACKEND_IP:$BACKEND_PORT"
      return 0
    fi
    err=$(cat "$TMPD/ssh.err")
    if echo "$err" | grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED'; then
      warn "ключ хоста BACKEND изменился (сервер переустанавливали?)"
      confirm "Удалить старую запись из known_hosts и продолжить?" n || die "подключение отменено"
      ssh-keygen -R "$BACKEND_IP" >/dev/null 2>&1 || true
      ssh-keygen -R "[$BACKEND_IP]:$BACKEND_PORT" >/dev/null 2>&1 || true
    elif echo "$err" | grep -qi 'permission denied'; then
      fail "BACKEND не принял ключ: его публичная часть должна быть в authorized_keys пользователя root на BACKEND"
      confirm "Указать другой приватный ключ?" || die "без доступа по ключу к BACKEND продолжить нельзя"
      read_key
    else
      fail "SSH не удался: $(echo "$err" | tail -n 1)"
      confirm "Повторить?" || die "без SSH к BACKEND продолжить нельзя"
      ask np "SSH-порт BACKEND" "$BACKEND_PORT"
      valid_port "$np" && BACKEND_PORT="$np"
    fi
    ssh_opts
  done
}


# ───────────────────────── сохранение настроек ─────────────────────────
# Читаем только известные ключи (файл не исполняем): IP/порт/домен/ключ как подсказки по умолчанию.
load_conf() {
  local f k v
  for f in "$CONF_FILE"; do
    [ -f "$f" ] || continue
    for k in BACKEND_IP BACKEND_PORT DOMAIN KEY_PATH USER_PATH TUNNEL_PATH TUNNEL_UUID VER_PATH TUNNEL_OBFS SUB_TITLE; do
      v=$(sed -n "s/^$k=//p" "$f" 2>/dev/null | head -n1)
      [ -n "$v" ] && printf -v "$k" '%s' "$v"
    done
  done
  return 0
}

save_conf() {
  : > "$CONF_FILE"; chmod 600 "$CONF_FILE"
  cat > "$CONF_FILE" <<EOT
RELAY_IP=${RELAY_IP:-}
BACKEND_IP=${BACKEND_IP:-}
BACKEND_PORT=${BACKEND_PORT:-}
DOMAIN=${DOMAIN:-}
EMAIL=${EMAIL:-}
KEY_PATH=${KEY_PATH:-}
USER_PATH=${USER_PATH:-}
TUNNEL_PATH=${TUNNEL_PATH:-}
TUNNEL_UUID=${TUNNEL_UUID:-}
HIDE_PANEL=${HIDE_PANEL:-}
VER_PATH=${VER_PATH:-}
TUNNEL_OBFS=${TUNNEL_OBFS:-}
SUB_TITLE=${SUB_TITLE:-}
EOT
  chmod 600 "$CONF_FILE"
}

cleanup() {
  [ -n "${TMPD:-}" ] && [ -d "$TMPD" ] && {
    [ -n "${SELFTEST_PID:-}" ] && kill "$SELFTEST_PID" >/dev/null 2>&1 || true
    [ -n "${SSH_OPTS+x}" ] && ssh "${SSH_OPTS[@]}" -O exit "root@${BACKEND_IP:-x}" >/dev/null 2>&1 || true
    rm -rf "$TMPD"
  }
  printf '%s' "$R"
}


preflight() {
  # ── автопроверки окружения (без вопросов)
  echo "${B}Проверка окружения${R}"
  thin
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  if [ "${ID:-}" = "ubuntu" ]; then
    if version_ge "${VERSION_ID:-0}" 22.04; then ok "ОС: ${PRETTY_NAME:-ubuntu}"; else die "нужна Ubuntu 22.04 или новее (найдена ${VERSION_ID:-?})"; fi
  elif [ "${ID:-}" = "debian" ]; then
    warn "ОС ${PRETTY_NAME:-debian}: скрипт проверен на Ubuntu 22.04+, на Debian 12+ должен работать"
  else
    warn "ОС ${PRETTY_NAME:-?}: скрипт рассчитан на Ubuntu 22.04+"
  fi
  ensure_tools || die "не удалось установить базовые утилиты (curl, dig, ssh, openssl)"
  RELAY_IP=$(detect_relay_ip)
  valid_ip "$RELAY_IP" || die "не удалось определить внешний IP этого сервера"
  ok "IP RELAY: $RELAY_IP"
  load_conf

}

# ───────────────────────── подготовка сервера (бывший preServer.sh) ─────────────────────────
# Выполняется на ЭТОМ сервере. PREP_ROOT — только для тестов (префикс путей).
PR="${PREP_ROOT:-}"
PREP_MARKER_DIR="$PR/var/lib/preserver"
PREP_MARKER_FILE="$PREP_MARKER_DIR/.preserver-ran"   # тот же путь, что у автономного preServer.sh

# ───────────────────────── подготовка сервера: функции в файле rb-prepare.sh (подключается load_parts) ─────────────────────────
# neutralize_sshd_dropins, disable_ssh_socket_activation, verify_and_restart_sshd, prep_rollback, prep_fastfetch_ppa, prep_fastfetch_deb, run_prepare

# метки работы со скриптом на ЭТОМ сервере: подготовка сервера и настройка защищённого канала
# Описание пути трафика для «Плана установки»
print_reverse_tunnel_plan() {
  local p="                 "   # отступ под подписью (как у kv)
  printf '  %s%-14s%s %s\n' "$DIM" "Reverse Tunnel" "$R" "как идёт трафик от клиента до интернета:"
  printf '%s%s1.%s Клиент отправляет запрос на RELAY — на ваш домен, по секретному\n' "$p" "$B" "$R"
  printf '%s   пути, в Xray (VLESS поверх XHTTP). По любому другому пути\n' "$p"
  printf '%s   RELAY отдаёт «живой» сайт-приманку (honeypot). Для провайдера\n' "$p"
  printf '%s   это обычный HTTPS на сайт.\n' "$p"
  printf '%s%s2.%s BACKEND заранее открывает туннель (Xray + XHTTP) к RELAY,\n' "$p" "$B" "$R"
  printf '%s   и RELAY передаёт по нему запрос клиента.\n' "$p"
  printf '%s%s3.%s BACKEND обращается к сайту со своего IP. Сайт видит BACKEND,\n' "$p" "$B" "$R"
  printf '%s   а не вас и не RELAY.\n' "$p"
  printf '%s%s4.%s Ответ возвращается тем же путём:\n' "$p" "$B" "$R"
  printf '%s   BACKEND → туннель → RELAY → клиент.\n' "$p"
  printf '\n%s%sКто что видит:%s\n' "$p" "$B" "$R"
  printf '%s  Провайдер клиента: соединение с российским IP и вашим доменом,\n' "$p"
  printf '%s                     внутри TLS.\n' "$p"
  printf '%s  Сеть между серверами: одно долгое TLS-соединение\n' "$p"
  printf '%s                     BACKEND → RELAY:443.\n' "$p"
  printf '%s  RELAY: адреса назначения пользователей, но не содержимое HTTPS.\n' "$p"
  printf '%s  BACKEND: адреса назначения и DNS-запросы; сайт видит IP BACKEND.\n' "$p"
}

# Список служебных команд: print_service_commands relay | backend | both
print_service_commands() {
  local want=${1:-both}
  echo "  ${B}Служебные команды${R}"
  if [ "$want" != backend ]; then
    echo "   RELAY$([ "$want" = both ] && echo " (этот сервер)"):"
    echo "     chain-status                 состояние цепочки: nginx, 3x-ui, подключён ли мост, сертификат, проба сайта"
    echo "     chain-test                   сквозная проверка: клиент → туннель → BACKEND → интернет (показывает выходной IP)"
    echo "     chain-health --show          мост, сквозная проверка, нагрузка, последние сбои (обновляется раз в 30 с)"
    echo "     chain-incident --show [N]    журнал сбоев /var/log/chain-incidents.log: что упало и почему"
    echo "     chain-failclosed             проверка: без моста RELAY не выпускает трафик пользователей в интернет"
    echo "     chain-speedtest [--quick|--size МБ]   скорость цепочки, измеренная на RELAY (без вашего канала до RELAY): вниз/вверх по профилям отправки, загрузка процессора"
    echo "     chain-certcheck              срок сертификата и пробное продление (то же делает таймер раз в неделю)"
    echo "     chain-boot-test              автотест после перезагрузки (запускается сам через 3 минуты после старта)"
    echo "     chain-set-backend IP|any     сменить IP BACKEND, которому разрешён туннельный путь (any — без ограничения)"
    echo "     chain-site-refresh           обновить страницы «живого» сайта (то же делает таймер раз в 5 минут)"
    echo "     sync-sub-path                прописать пути подписки из 3x-ui в nginx (таймер; вручную — после смены путей в панели)"
    echo "     chain-xray-version           записать версию Xray релея (срабатывает сама при обновлении ядра панели)"
  fi
  if [ "$want" != relay ]; then
    echo "   BACKEND$([ "$want" = both ] && echo ":" || echo " (этот сервер):")"
    echo "     chain-set-relay IP           указать новый IP RELAY (если мост не подключится за 40 с, прежний адрес вернётся)"
    echo "     chain-update-bridge [ВЕРСИЯ|--rollback|--status]   Xray моста: к версии RELAY или к указанной (прежняя сохраняется, при неудаче откат), --rollback — вернуть прежнюю"
    echo "     chain-watchdog --status      состояние сторожа и перезапуски моста (локальные проверки раз в минуту)"
    echo "     chain-incident --show [N]    журнал сбоев /var/log/chain-incidents.log"
    echo "     chain-restart-bridge         служебная команда: её вызывает RELAY по своему ключу (перезапуск моста, версия Xray), вручную не нужна"
    echo "     systemctl status chain-bridge, journalctl -u chain-bridge   состояние и журнал моста"
  fi
}
run_service_commands() {
  local role; role=$(marker_get ROLE); role=${role:-relay}
  echo
  print_service_commands "$role"
  echo
}

# Если метка осталась с пометкой «сквозная проверка не прошла» (например, мост подключился уже после проверки при установке), а цепочка сейчас
# работает, статус исправляется и ложное предупреждение больше не показывается.
refresh_marker_status() {
  [ -f "$MARKER_FILE" ] || return 0
  [ "$(marker_get STATUS)" = "check-failed" ] || return 0
  local role rip e2e good=0
  role=$(marker_get ROLE); role=${role:-relay}
  if [ "$role" = backend ]; then
    rip=$(marker_get RELAY_IP)
    if [ -n "$rip" ] && systemctl is-active --quiet chain-bridge && ss -tnH state established "( dst $rip and dport = :443 )" 2>/dev/null | grep -q .; then good=1; fi
  else
    if [ "$(tunnel_conns)" -ge 1 ]; then
      [ -x /usr/local/bin/chain-health ] && CHAIN_HEALTH_FORCE_E2E=1 /usr/local/bin/chain-health >/dev/null 2>&1
      e2e=$(sed -n 's/^e2e=//p' /var/lib/chain/health 2>/dev/null | head -n1)
      [ "$e2e" = ok ] && good=1
    fi
  fi
  if [ "$good" -eq 1 ]; then
    marker_set STATUS "done"
    info "метка была с пометкой «сквозная проверка не прошла», сейчас цепочка работает — статус исправлен"
  fi
}

show_marks() {
  local pf=0 cf=0 role st
  [ -f "$PREP_MARKER_FILE" ] && pf=1
  [ -f "$MARKER_FILE" ] && cf=1
  [ $pf -eq 1 ] || [ $cf -eq 1 ] || return 0
  echo
  echo "${B}Найдена метка работы со скриптом${R}"
  thin
  if [ $pf -eq 1 ]; then
    ok "Подготовка сервера: выполнена $(awk -F= '/^ran_at=/{print $2}' "$PREP_MARKER_FILE"), SSH-порт $(awk -F= '/^ssh_port=/{print $2}' "$PREP_MARKER_FILE")"
  fi
  if [ $cf -eq 1 ]; then
    role=$(marker_get ROLE); role=${role:-relay}
    st=$(marker_get STATUS)
    if [ "$st" = done ]; then
      ok "Настройка защищённого канала RELAY ← BACKEND: выполнена $(marker_get INSTALLED_AT)"
    elif [ "$st" = check-failed ]; then
      warn "Настройка защищённого канала RELAY ← BACKEND: выполнена $(marker_get INSTALLED_AT), но сквозная проверка не прошла (см. chain-test)"
    else
      warn "Настройка защищённого канала RELAY ← BACKEND: начата $(marker_get INSTALLED_AT), не завершена"
    fi
    info "роль этого сервера: ${role^^}; RELAY $(marker_get RELAY_IP), BACKEND $(marker_get BACKEND_IP), домен $(marker_get DOMAIN)"
  fi
}

menu() {
  local has=0 c i role
  [ -f "$MARKER_FILE" ] && has=1
  role=$(marker_get ROLE); role=${role:-relay}
  local -a keys=(prepare install) labels=("Подготовить сервер" "Настроить защищенный канал RELAY ← BACKEND")
  if [ $has -eq 1 ] && [ "$role" != backend ] && [ "${XRAY_MISMATCH:-0}" = 1 ]; then   # только если версии Xray на серверах различаются
    keys+=(update-xray); labels+=("Обновить Xray на обоих серверах: версии различаются (проба на BACKEND, откат при неудаче)")
  fi
  if [ $has -eq 1 ]; then keys+=(commands); labels+=("Служебные команды"); fi
  if [ $has -eq 1 ]; then keys+=(uninstall); labels+=("Откат"); fi   # «Откат» всегда последний пункт
  echo
  echo "${B}Что делаем?${R}"
  thin
  for ((i = 0; i < ${#keys[@]}; i++)); do echo "  ${B}$((i + 1))${R}. ${labels[i]}"; done
  while true; do
    rd -r -p "${B}?${R} Выберите вариант: " c
    if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#keys[@]}" ]; then MODE="${keys[c-1]}"; return 0; fi
    fail "введите число от 1 до ${#keys[@]}"
  done
}


# ───────────────────────── скрипты установки: make_scripts в файле rb-deploy.sh (подключается load_parts) ─────────────────────────

# ───────────────────────── RELAY: локальные помощники ─────────────────────────
lscript() { local f="$1"; shift; bash -s -- "$@" < "$f"; }   # запуск скрипта на ЭТОМ сервере

# порты 80/443 не должны быть заняты чужими процессами (nginx свой — допустим)
relay_port_conflicts() {
  local bad="" p owner
  for p in 80 443; do
    owner=$(ss -tlnp 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" { print $0 }' | grep -v nginx | head -n1)
    [ -n "$owner" ] && bad="$bad $p"
  done
  printf '%s' "$bad"
}

relay_firewall() {
  local p ports
  ports=$(ssh_ports)
  [ -n "$ports" ] || { echo "SSH-порт RELAY не определён: firewall не включаю, чтобы не потерять доступ" >&2; return 1; }
  for p in $ports; do ufw allow "$p/tcp" || return 1; done
  ufw allow 80/tcp && ufw allow 443/tcp || return 1
  ufw default deny incoming >/dev/null && ufw default allow outgoing >/dev/null || return 1
  ufw --force enable >/dev/null && ufw --force reload >/dev/null
}

# 3x-ui на RELAY. Архив панели весит около 80 МБ, а установщик 3x-ui качает его без общего лимита времени (обрыв только после 300 с без единого байта,
# до 5 попыток) — отсюда «10+ минут». Поэтому: замер скорости до GitHub напрямую и через BACKEND (SOCKS поверх SSH), загрузка выбранным путём
# с обрывом зависшей загрузки через 30 с, проверка суммы, установка из загруженного архива.
XUI_PROXY=""; XUI_PROXY_OPEN=0
xui_pick_route() {
  local url="https://github.com/MHSanaei/3x-ui/releases/download/$XUI_VER/x-ui-linux-amd64.tar.gz" sd sp est
  XUI_PROXY=""; XUI_PROXY_OPEN=0
  probe() { curl -4 -sSL -r 0-4194303 -o /dev/null --connect-timeout 10 --max-time 25 -w '%{speed_download}' "$@" "$url" 2>/dev/null | awk '{printf "%d", $1}'; }
  sd=$(probe); sd=${sd:-0}
  sp=0
  if [ "${LOCAL_BACKEND:-0}" != 1 ] && ssh "${SSH_OPTS[@]}" -O forward -D 127.0.0.1:1080 "root@$BACKEND_IP" >>"$LOG" 2>&1; then
    XUI_PROXY_OPEN=1
    sp=$(probe --proxy socks5h://127.0.0.1:1080); sp=${sp:-0}
  fi
  info "скорость загрузки с GitHub: напрямую с RELAY $(awk -v v="$sd" 'BEGIN{printf "%.1f", v/1048576}') МБ/с, через BACKEND $(awk -v v="$sp" 'BEGIN{printf "%.1f", v/1048576}') МБ/с"
  if [ "$sp" -gt $((sd * 13 / 10)) ]; then
    XUI_PROXY="socks5h://127.0.0.1:1080"
    est=$(awk -v v="$sp" 'BEGIN{ if (v>0) printf "%d", 82/(v/1048576); else print "?" }')
    info "качаем через BACKEND (быстрее); архив около 80 МБ, ожидание порядка $est с"
  else
    [ "$XUI_PROXY_OPEN" = 1 ] && { ssh "${SSH_OPTS[@]}" -O cancel -D 127.0.0.1:1080 "root@$BACKEND_IP" >>"$LOG" 2>&1 || true; XUI_PROXY_OPEN=0; }
    est=$(awk -v v="$sd" 'BEGIN{ if (v>0) printf "%d", 82/(v/1048576); else print "?" }')
    if [ "$sd" -eq 0 ]; then warn "GitHub с RELAY напрямую не отвечает, и через BACKEND тоже: загрузка, скорее всего, не удастся"; else info "качаем напрямую с RELAY; архив около 80 МБ, ожидание порядка $est с"; fi
  fi
}
xui_stage() {
  local res rc=0
  xui_pick_route
  step_run "3x-ui $XUI_VER: загрузка установщика" env ALL_PROXY="$XUI_PROXY" bash "$TMPD/xui-fetch.sh" "$XUI_VER" || rc=1
  [ $rc -eq 0 ] && { step_run "3x-ui: загрузка архива панели (около 80 МБ; зависшая загрузка обрывается через 30 с, до 3 попыток)" env ALL_PROXY="$XUI_PROXY" bash "$TMPD/xui-download.sh" "$XUI_VER" || rc=1; }
  [ $rc -eq 0 ] && { step_run "3x-ui: проверка контрольной суммы и целостности архива" bash "$TMPD/xui-verify.sh" || rc=1; }
  [ $rc -eq 0 ] && { step_run "3x-ui: установка из загруженного архива (SQLite, порт $PANEL_PORT)" env ALL_PROXY="$XUI_PROXY" bash "$TMPD/xui-install.sh" "$PANEL_PORT" "$XUI_VER" || rc=1; }
  [ $rc -eq 0 ] && { step_run "3x-ui: запуск, панель на 127.0.0.1:$PANEL_PORT" bash "$TMPD/xui-check.sh" "$PANEL_PORT" || rc=1; }
  [ "$XUI_PROXY_OPEN" = 1 ] && { ssh "${SSH_OPTS[@]}" -O cancel -D 127.0.0.1:1080 "root@$BACKEND_IP" >>"$LOG" 2>&1 || true; XUI_PROXY_OPEN=0; }
  rm -rf /tmp/xui-cache
  [ $rc -eq 0 ] || die "3x-ui не установился"
  res=$(cat /etc/x-ui/install-result.env 2>>"$LOG")
  getv() { printf '%s\n' "$res" | sed -n "s/^$1=//p" | head -n1 | sed "s/^'//; s/'$//"; }
  xu=$(getv XUI_USERNAME); xp=$(getv XUI_PASSWORD); xw=$(getv XUI_WEB_BASE_PATH); xt=$(getv XUI_API_TOKEN)
  if ! { [ -n "$xu" ] && [ -n "$xp" ] && [ -n "$xw" ]; }; then
    warn "файл данных установщика не найден (панель уже была установлена?) — задаю новые данные входа"
    xu=$(openssl rand -hex 5); xp=$(openssl rand -hex 5); xw=$(openssl rand -hex 9)
    /usr/local/x-ui/x-ui setting -username "$xu" -password "$xp" -port "$PANEL_PORT" -webBasePath "$xw" -listenIP 127.0.0.1 >>"$LOG" 2>&1 &&
      systemctl restart x-ui >>"$LOG" 2>&1 || die "не удалось задать данные панели"
  fi
  [ -n "$xt" ] || xt=$(/usr/local/x-ui/x-ui setting -getApiToken 2>>"$LOG" | grep -Eo 'apiToken: .+' | awk '{print $2}')
}

# инбаунды и маршрутизация в 3x-ui; результат: CHAIN_USER_ID, CHAIN_SUB_ID, TUNNEL_UUID
# ВАЖНО: step_run запускает команду в подоболочке, поэтому переменные оттуда не возвращаются —
# результат передаётся через файл $TMPD/chain.env, который родительский процесс читает (chain_load)
chain_inbounds() {
  local out cu sb tu to
  [ -n "${xt:-}" ] || return 1
  out=$(python3 "$TMPD/chain-inbounds.py" "http://127.0.0.1:$PANEL_PORT/${xw#/}" "$xt" "$DOMAIN" "$USER_PATH" "$TUNNEL_PATH" "$CHAIN_USER_PORT" "$CHAIN_TUNNEL_PORT" "${TUNNEL_OBFS:-0}" 2>>"$LOG") || return 1
  cu=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["user_id"])') || return 1
  sb=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sub_id"])') || return 1
  tu=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tunnel_id"])') || return 1
  to=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tunnel_obfs"])') || return 1
  [ -n "$cu" ] && [ -n "$tu" ] || return 1
  ( umask 077; printf 'CHAIN_USER_ID=%q\nCHAIN_SUB_ID=%q\nTUNNEL_UUID=%q\nTUNNEL_OBFS=%q\n' "$cu" "$sb" "$tu" "$to" > "$TMPD/chain.env" )
}
chain_load() {  # читает результат chain_inbounds в переменные родительского процесса
  [ -s "$TMPD/chain.env" ] || return 1
  # shellcheck disable=SC1091
  . "$TMPD/chain.env"
  [ -n "${CHAIN_USER_ID:-}" ] && [ -n "${TUNNEL_UUID:-}" ]
}

# мост BACKEND: установка и запуск
backend_bridge() {
  rscript "$TMPD/bridge-install.sh" "$RELAY_IP" "$DOMAIN" "$TUNNEL_PATH" "$TUNNEL_UUID" "$VER_PATH" "${TUNNEL_OBFS:-0}" "$XRAY_VER" &&
    rscript "$TMPD/bridge-tools.sh"
}

# журнал сбоев (/var/log/chain-incidents.log) на RELAY и BACKEND
install_incident_log() {
  lscript "$TMPD/incident-install.sh" && rscript "$TMPD/incident-install.sh"
}

# SSH-ключ RELAY → BACKEND, который на BACKEND разрешает единственную команду — перезапуск моста (и ping для проверки ключа)
setup_restart_key() {
  local k=/root/.ssh/chain-restart b64
  if [ "${LOCAL_BACKEND:-0}" = 1 ]; then echo "BACKEND на этом же сервере: ключ не нужен"; return 0; fi
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  [ -f "$k" ] || ssh-keygen -q -t ed25519 -N "" -C "chain-restart@$(hostname -s)" -f "$k" || return 1
  b64=$(base64 -w0 < "$k.pub") || return 1
  rscript "$TMPD/restart-key-install.sh" "$b64" || return 1
  ssh -i "$k" -p "$BACKEND_PORT" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
    "root@$BACKEND_IP" ping 2>>"$LOG" | grep -q "ключ работает"
}

# GitHub с RELAY из РФ бывает недоступен: тогда качаем через BACKEND (SOCKS поверх SSH); печатает адрес прокси (пусто — напрямую)
github_proxy_open() {
  local p=""
  if ! curl -fsS --max-time 12 -o /dev/null -I https://github.com >>"$LOG" 2>&1; then
    if [ "${LOCAL_BACKEND:-0}" != 1 ] && ssh "${SSH_OPTS[@]}" -O forward -D 127.0.0.1:1080 "root@$BACKEND_IP" >>"$LOG" 2>&1; then p="socks5h://127.0.0.1:1080"; fi
  fi
  printf '%s' "$p"
}
github_proxy_close() { [ -n "${1:-}" ] && { ssh "${SSH_OPTS[@]}" -O cancel -D 127.0.0.1:1080 "root@$BACKEND_IP" >>"$LOG" 2>&1 || true; }; return 0; }

# идентификатор первого клиента инбаунда пользователей (нужен сквозной проверке при обновлении)
load_user_id() {
  CHAIN_USER_ID=$(python3 - 2>>"$LOG" <<'PY'
import json, sqlite3
db = sqlite3.connect("/etc/x-ui/x-ui.db")
print(json.loads(db.execute("select settings from inbounds where port = 21443 limit 1").fetchone()[0])["clients"][0]["id"])
PY
) || true
  [ -n "$CHAIN_USER_ID" ]
}

# число соединений моста, пришедших на инбаунд туннеля
tunnel_conns() { ss -tnH state established "( sport = :$CHAIN_TUNNEL_PORT )" 2>/dev/null | wc -l; }

# сквозная проверка: временный клиент на RELAY → nginx → туннель → BACKEND → интернет; выходной IP должен быть IP BACKEND
chain_selftest() {
  local xray cfg exit_ip be_ip
  xray=$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -n1)
  [ -x "$xray" ] || { echo "Xray из 3x-ui не найден" >&2; return 1; }
  cfg="$TMPD/selftest.json"
  # xhttpSettings берём из инбаунда пользователей (VPN), чтобы проверка видела те же настройки, что и клиенты
  python3 - "$DOMAIN" "$CHAIN_USER_ID" "$SELFTEST_PORT" "$cfg" <<'PY' || return 1
import json, sqlite3, sys
domain, uid, port, out = sys.argv[1:5]
db = sqlite3.connect("/etc/x-ui/x-ui.db")
st = db.execute("select stream_settings from inbounds where port = 21443 limit 1").fetchone()[0]
xh = json.loads(st)["xhttpSettings"]
json.dump({"log": {"loglevel": "warning"},
           "inbounds": [{"tag": "s", "listen": "127.0.0.1", "port": int(port), "protocol": "socks", "settings": {"udp": False}}],
           "outbounds": [{"tag": "p", "protocol": "vless", "settings": {"address": "127.0.0.1", "port": 443, "id": uid, "encryption": "none"},
                          "streamSettings": {"network": "xhttp", "security": "tls",
                                             "tlsSettings": {"serverName": domain, "fingerprint": "chrome", "alpn": ["h2"]},
                                             "xhttpSettings": xh}}]}, open(out, "w"))
PY
  "$xray" run -c "$cfg" >"$TMPD/selftest.log" 2>&1 </dev/null &
  SELFTEST_PID=$!
  sleep 2
  exit_ip=$(curl -4 -s --max-time 25 -x "socks5h://127.0.0.1:$SELFTEST_PORT" https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
  kill "$SELFTEST_PID" >/dev/null 2>&1 || true
  SELFTEST_PID=""
  be_ip=$(bk 'curl -4 -fsS --max-time 10 https://api.ipify.org' 2>>"$LOG" | tr -d '[:space:]')
  echo "выходной IP цепочки: ${exit_ip:-нет ответа}; внешний IP BACKEND: ${be_ip:-?}"
  [ -n "$exit_ip" ] && [ "$exit_ip" = "$be_ip" ]
}

# порт SSH этого сервера (для команды SSH-туннеля к панели)
relay_ssh_port() {
  local p
  p=$(echo "${SSH_CONNECTION:-}" | awk '{ print $4 }')
  [[ "$p" =~ ^[0-9]+$ ]] || p=$(ssh_ports | head -n1)
  echo "${p:-22}"
}

# ссылка первого пользователя из подписки (для Incy)
chain_client_link() {
  local port
  port=$(sqlite3 /etc/x-ui/x-ui.db "select value from settings where key='subPort'" 2>/dev/null)
  port="${port:-2096}"
  curl -s --max-time 10 -H 'Accept-Encoding: identity' "http://127.0.0.1:$port${SUB_PATHS}${CHAIN_SUB_ID}" 2>/dev/null |
    python3 -c 'import base64,sys; d=sys.stdin.buffer.read().strip(); 
try: t=base64.b64decode(d+b"==").decode()
except Exception: t=d.decode("utf-8","replace")
print(t.splitlines()[0] if t.strip() else "")' 2>/dev/null
}

check_reinstall() {
  if [ -f "$MARKER_FILE" ] && [ "$(marker_get ROLE)" = backend ]; then
    warn "этот сервер — BACKEND уже настроенного канала (метка: $(marker_get INSTALLED_AT)); настройку нужно запускать на RELAY"
    confirm "Всё равно продолжить настройку с этого сервера?" n || { echo "  Отменено."; exit 0; }
  elif [ -f "$MARKER_FILE" ]; then
    warn "установка уже выполнялась (метка: $(marker_get INSTALLED_AT), статус: $(marker_get STATUS))"
    confirm "Удалить всё и установить заново?" n || { echo "  Отменено."; exit 0; }
    do_uninstall || exit 0
    USER_PATH=""; TUNNEL_PATH=""; TUNNEL_UUID=""; VER_PATH=""   # новая установка — новые секретные пути
  fi
}

# ───────────────────────── настройка цепочки ─────────────────────────
# Диагностика моста в лог: что видит RELAY и что видит BACKEND
bridge_diag() {
  {
    echo "== диагностика моста $(date '+%F %T')"
    echo "-- RELAY: соединений моста на туннельном пути: $(tunnel_conns)"
    echo "-- RELAY: соединения с BACKEND на :443:"; ss -tn state established "( sport = :443 )" 2>&1 | grep -F "$BACKEND_IP" | head -5
    echo "-- RELAY: последние строки журнала ошибок nginx:"; tail -n 5 /var/log/nginx/error.log 2>&1
    echo "-- BACKEND: служба, соединения с RELAY, журнал моста:"
    bk "systemctl is-active chain-bridge; ss -tn dst $RELAY_IP | head -5; journalctl -u chain-bridge -n 15 --no-pager -o cat" 2>&1
  } >>"$LOG"
}

# Ждёт подключения моста: 60 с; если нет — перезапускает мост на BACKEND (до 2 раз, ожидание 45 с после каждого перезапуска).
# На практике мост после установки иногда подключается только после ещё одного перезапуска (в сторожевых записях видно: нет соединений 2–3 минуты,
# после перезапуска моста соединение появляется сразу) — раньше проверка в этот момент ложно сообщала об ошибке.
bridge_wait_or_kick() {
  local kick i n
  for kick in 0 1 2; do
    if [ "$kick" -gt 0 ]; then
      warn "мост не подключился — перезапускаю мост на BACKEND (попытка $kick из 2)"
      bridge_diag
      bk "systemctl restart chain-bridge" >>"$LOG" 2>&1 || true
    fi
    n=30; [ "$kick" -gt 0 ] && n=23
    for ((i = 0; i < n; i++)); do
      [ "$(tunnel_conns)" -ge 1 ] && return 0
      sleep 2
    done
  done
  bridge_diag
  return 1
}

# ───────────────────────── Honeypot: отдельный файл rb-honeypot.sh ─────────────────────────
# Скачивание генератора (нужен только при установке). HP_PROXY — SOCKS через BACKEND, если GitHub с RELAY недоступен.
honeypot_fetch() {
  local dst="$TMPD/rb-honeypot.sh" i
  if [ -n "$HONEYPOT_FILE" ] && [ -s "$HONEYPOT_FILE" ]; then
    cp -f "$HONEYPOT_FILE" "$dst" || return 1
  else
    for i in 1 2 3 4; do
      if curl -4 -fsSL --connect-timeout 10 --max-time 60 ${HP_PROXY:+--proxy "$HP_PROXY"} "$HONEYPOT_URL" -o "$dst" && [ -s "$dst" ]; then break; fi
      echo "rb-honeypot.sh: попытка $i не удалась, повтор" >&2
      rm -f "$dst"; sleep 2
    done
    [ -s "$dst" ] || { echo "rb-honeypot.sh не скачан с $HONEYPOT_URL" >&2; return 1; }
  fi
  head -n1 "$dst" | grep -q '^#!' || { echo "rb-honeypot.sh: неверный формат файла (нет shebang)" >&2; return 1; }
  grep -q 'Honeypot generator' "$dst" || { echo "rb-honeypot.sh: файл не похож на генератор Honeypot" >&2; return 1; }
  bash -n "$dst" || { echo "rb-honeypot.sh: синтаксическая ошибка в скачанном файле" >&2; return 1; }
  chmod 600 "$dst"
}

# Генерация сайта: только файлы (dry-run), без apt/nginx/certbot — их делает основной скрипт
honeypot_generate() {
  HONEYPOT_DRYRUN=1 HONEYPOT_WEBROOT="/var/www/honeypot/$DOMAIN" bash "$TMPD/rb-honeypot.sh" "$DOMAIN"
}

# Выбор при сбое Honeypot: 0 — повторить попытку, 1 — отменить установку с откатом
honeypot_choice() {
  local c
  echo
  echo "  ${B}1${R}. Повторить попытку"
  echo "  ${B}2${R}. Отменить установку с откатом"
  drain_tty
  while true; do
    rd -r -p "${B}?${R} Выберите вариант ${DIM}[Enter = 1]${R}: " c
    case "${c:-1}" in
      1) return 0 ;;
      2) return 1 ;;
      *) fail "введите 1 или 2" ;;
    esac
  done
}

# Откат незавершённой установки без вопросов (то же, что «Откат установки», оба сервера).
# К этому моменту SSH к BACKEND уже поднят, поэтому откатываются и RELAY, и BACKEND.
install_rollback() {
  local rm_xui=0 rm_web=1
  [ "${XUI_BY_SCRIPT:-1}" != 0 ] && [ -d /usr/local/x-ui ] && rm_xui=1
  echo
  section "Откат установки"
  step_run "BACKEND: удаление моста, служебных команд и настроек" backend_uninstall || warn "часть действий на BACKEND не выполнена (см. лог)"
  step_run "RELAY: удаление служебных команд, сайта, настроек сети" relay_uninstall "$rm_xui" "$rm_web" || warn "часть действий на RELAY не выполнена (см. лог)"
  echo
  ok "установка отменена, изменения откачены; метка установки удалена"
  info "firewall BACKEND остался закрытым (только SSH); при необходимости: ufw allow <порт>/tcp"
  echo "  ${DIM}Полный лог: $LOG${R}"
  exit 1
}

# Этап Honeypot целиком: скачивание → проверка файла → генерация сайта → проверка index.html.
# При любом сбое — выбор: повторить попытку или отменить установку с откатом.
honeypot_stage() {
  local why=""
  while true; do
    why=""
    rm -f "$TMPD/rb-honeypot.sh"; rm -rf "/var/www/honeypot/$DOMAIN"
    HP_PROXY=$(github_proxy_open)
    [ -n "$HP_PROXY" ] && [ -z "$HONEYPOT_FILE" ] && info "GitHub с RELAY недоступен: rb-honeypot.sh качаем через BACKEND"
    if step_run "Загрузка и проверка генератора Honeypot (rb-honeypot.sh)" honeypot_fetch; then
      github_proxy_close "$HP_PROXY"; HP_PROXY=""
      if ! step_run "Генерация файлов Honeypot на RELAY" honeypot_generate; then
        why="не удалось сгенерировать Honeypot"
      elif ! test -s "/var/www/honeypot/$DOMAIN/index.html"; then
        why="Honeypot не создал index.html"
      else
        ok "Главная страница создана: /var/www/honeypot/$DOMAIN/index.html"
        return 0
      fi
    else
      github_proxy_close "$HP_PROXY"; HP_PROXY=""
      why="rb-honeypot.sh недоступен или повреждён ($HONEYPOT_URL)"
    fi
    fail "$why"
    if honeypot_choice; then info "повторяем попытку…"; continue; fi
    install_rollback
  done
}

run_install() {
  INSTALL_KIND="chain"
  STEP=0; TOTAL=11
  check_reinstall
  STEP=0; TOTAL=11
  # панель 3x-ui, установленная скриптом, удаляется откатом; найденная до запуска скрипта — не трогается
  XUI_BY_SCRIPT=$(marker_get XUI_BY_SCRIPT)
  if [ -z "$XUI_BY_SCRIPT" ]; then if [ -d /usr/local/x-ui ]; then XUI_BY_SCRIPT=0; else XUI_BY_SCRIPT=1; fi; fi

  # ── вопросы
  echo
  echo "${B}Параметры${R}"
  thin
  while true; do
    ask BACKEND_IP "IP BACKEND" "${BACKEND_IP:-}"
    if [ "$BACKEND_IP" = "$RELAY_IP" ]; then fail "IP BACKEND совпадает с IP этого сервера"; BACKEND_IP=""; continue; fi
    valid_ip "$BACKEND_IP" && break
    fail "неверный IP"
    BACKEND_IP=""
  done
  while true; do
    ask BACKEND_PORT "SSH-порт BACKEND" "${BACKEND_PORT:-1119}"
    valid_port "$BACKEND_PORT" && break
    fail "неверный порт"
  done
  [ -n "${KEY_FILE:-}" ] || read_key
  while true; do
    ask DOMAIN "Домен (A-запись → IP RELAY)" "${DOMAIN:-}"
    valid_dom "$DOMAIN" && break
    fail "неверный домен"
    DOMAIN=""
  done
  EMAIL="admin@$DOMAIN"   # e-mail для Let's Encrypt: не спрашиваем
  HIDE_PANEL=0
  if confirm "Скрыть веб-доступ к панели 3x-ui (открывать только через SSH-туннель)?"; then HIDE_PANEL=1; fi
  TUNNEL_OBFS=0   # обфускация HTTP-заголовков туннеля выключена: внутри TLS 1.3 она не видна; размер padding (100-1000 Б) работает и без неё
  while true; do
    ask SUB_TITLE "Название подписки (показывается в клиентах)" "${SUB_TITLE:-VPN}"
    SUB_TITLE=$(printf '%s' "$SUB_TITLE" | tr -d '[:cntrl:]' | sed 's/^ *//; s/ *$//')
    { [ -n "$SUB_TITLE" ] && [ ${#SUB_TITLE} -le 60 ]; } && break
    fail "название должно быть от 1 до 60 символов"
    SUB_TITLE=""
  done

  # ── скрытая проверка DNS: молчит, если всё в порядке
  echo
  dns_check
  DNS_OK=$?

  USER_PATH="${USER_PATH:-$(openssl rand -hex 12)}"
  TUNNEL_PATH="${TUNNEL_PATH:-$(openssl rand -hex 12)}"
  VER_PATH="${VER_PATH:-$(openssl rand -hex 12)}"

  # ── сводка
  echo
  rule
  printf '  %sПлан установки%s\n' "$B" "$R"
  rule
  kv "RELAY" "$RELAY_IP  (nginx, 3x-ui, Honeypot; ufw: SSH, 80, 443)"
  kv "BACKEND" "$BACKEND_IP  (SSH :$BACKEND_PORT; мост Xray сам подключается к RELAY)"
  kv "Domain" "$DOMAIN"
  kv "Honeypot" "https://$DOMAIN/ — сайт на RELAY + 2–5 служебных эндпоинтов (случайный набор при установке); чужие пути — 404"
  kv "Subscription" "название в клиентах: $SUB_TITLE; инбаунды панели: VPN (пользователи), TUNNEL (служебный)"
  if [ $HIDE_PANEL -eq 1 ]; then
    kv "3x-ui panel" "скрыта из сети: только через SSH-туннель → RELAY 127.0.0.1:$PANEL_PORT; подписка для Incy доступна на https://$DOMAIN"
  else
    kv "3x-ui panel" "https://$DOMAIN/<WebBasePath> → RELAY 127.0.0.1:$PANEL_PORT; подписка для Incy там же"
  fi
  kv "E-mail" "$EMAIL"
  print_reverse_tunnel_plan
  rule
  echo
  confirm "Всё верно, начать установку?" || { echo "  Отменено."; exit 0; }
  write_marker in-progress

  make_scripts

  # [1] SSH
  section "Подключение к BACKEND"
  ssh_connect
  local bos
  bos=$(bk '. /etc/os-release; echo "$ID $VERSION_ID"' 2>>"$LOG")
  case "$bos" in
    ubuntu\ *) if version_ge "${bos#ubuntu }" 22.04; then ok "ОС BACKEND: Ubuntu ${bos#ubuntu }"; else die "BACKEND: нужна Ubuntu 22.04 или новее (найдена ${bos#ubuntu })"; fi ;;
    debian\ *) warn "ОС BACKEND: $bos (скрипт рассчитан на Ubuntu 22.04+)" ;;
    *) warn "ОС BACKEND не определена: ${bos:-?}" ;;
  esac
  rscript "$TMPD/f2b-ignore.sh" "$RELAY_IP" >>"$LOG" 2>&1 || true
  write_marker_backend in-progress
  step_run "Журнал сбоев (/var/log/chain-incidents.log) на RELAY и BACKEND" install_incident_log || warn "журнал сбоев установлен не полностью"

  # [3] сеть
  section "Сетевая оптимизация (RELAY и BACKEND)"
  step_run "RELAY: BBR, буферы TCP, MTU probing, keepalive, MPTCP выключен, лимиты журнала" tune_network || warn "твики на RELAY применены не полностью"
  step_run "BACKEND: BBR, буферы TCP, MTU probing, keepalive, MPTCP выключен, лимиты журнала" rscript "$TMPD/tune.sh" || warn "твики на BACKEND применены не полностью"

  # [4] пакеты и firewall RELAY
  section "RELAY: пакеты и firewall"
  step_run "Установка nginx, certbot, ufw, sqlite3" lscript "$TMPD/relay-pkgs.sh" || die "не удалось подготовить RELAY"
  local conflicts
  conflicts=$(relay_port_conflicts)
  [ -z "$conflicts" ] || die "на RELAY заняты порты:$conflicts (остановите чужие сервисы на этих портах)"
  step_run "ufw: SSH, 80/tcp, 443/tcp; прочее входящее закрыто" relay_firewall || die "не удалось настроить firewall RELAY"

  # [5] 3x-ui
  section "RELAY: 3x-ui"
  xui_stage

  # [6] Honeypot
  section "RELAY: «живой» сайт (Honeypot)"
  local EP_LIST
  EP_LIST=$(python3 "$TMPD/site-endpoints.py" 2>>"$LOG") || die "не удалось выбрать эндпоинты сайта"
  info "Публичный сайт: https://$DOMAIN/"
  info "Эндпоинты: $EP_LIST"
  info "Каталог сайта на RELAY: /var/www/honeypot/$DOMAIN"
  honeypot_stage

  # [7] nginx временный
  section "RELAY: nginx (временный конфиг)"
  step_run "nginx: временный HTTP-конфиг для выпуска сертификата" lscript "$TMPD/nginx-temp.sh" "$DOMAIN" "$xw" "$HIDE_PANEL" || die "nginx не настроился"

  # [8] сертификат
  section "Сертификат Let's Encrypt"
  CERT_OK=0
  if [ "$DNS_OK" -ne 0 ]; then warn "DNS не подтверждён — попытка выпуска может не удаться"; fi
  while true; do
    if step_run "certbot --webroot для $DOMAIN" lscript "$TMPD/cert.sh" "$DOMAIN" "$EMAIL"; then CERT_OK=1; break; fi
    warn "не удалось выпустить сертификат (DNS ещё не разошёлся? порт 80 недоступен?)"
    confirm "Повторить?" || break
  done
  [ $CERT_OK -eq 1 ] || die "без сертификата канал HTTPS не заработает: исправьте DNS и запустите установку снова"

  # [9] служебные команды, подписка, инбаунды, финальный nginx
  section "RELAY: подписка, инбаунды 3x-ui, nginx"
  step_run "Служебные команды: chain-status, chain-set-backend, sync-sub-path, обновление «живых» страниц" lscript "$TMPD/helper-relay.sh" || warn "служебные команды установлены не полностью"
  printf '%s\n' "$DOMAIN" > /etc/chain-site.domain
  /usr/local/bin/chain-site-refresh >>"$LOG" 2>&1 || warn "страницы статуса не созданы"
  SUB_PATHS=$(lscript "$TMPD/sub-setup.sh" "$DOMAIN" https "$SUB_TITLE" 2>>"$LOG" | tail -n1)
  if [ -n "$SUB_PATHS" ]; then ok "подписка: путь из панели $SUB_PATHS (nginx подхватит за ~15 с)"; else warn "не удалось настроить подписку (см. лог)"; fi
  step_run "3x-ui: инбаунд пользователей (VLESS+XHTTP), инбаунд туннеля (reverse), маршрутизация" chain_inbounds || die "не удалось настроить 3x-ui через API (см. лог)"
  chain_load || die "3x-ui не вернул идентификаторы инбаундов (см. лог)"
  save_conf
  step_run "nginx: сертификат, секретные пути, «живые» эндпоинты, автопродление (панель: $([ $HIDE_PANEL -eq 1 ] && echo скрыта || echo опубликована))" python3 "$TMPD/nginx-final.py" "$DOMAIN" "$xw" "$USER_PATH" "$TUNNEL_PATH" "$CHAIN_USER_PORT" "$CHAIN_TUNNEL_PORT" "$BACKEND_IP" "$HIDE_PANEL" "$VER_PATH" || die "не удалось включить финальный конфиг nginx"
  step_run "nginx: возврат освобождённой памяти системе (MALLOC_*), окно HTTP/2 1 МБ; перезапуск nginx" lscript "$TMPD/nginx-malloc.sh" || warn "ограничение памяти nginx не применено (см. лог)"
  /usr/local/bin/sync-sub-path >>"$LOG" 2>&1 || true
  step_run "3x-ui: журнал доступа и DNS-журнал Xray отключены" python3 "$TMPD/relay-harden.py" || warn "журналы Xray не отключены (см. лог)"
  step_run "Параметры отправки в инбаунде пользователей (POST 1,2–2 МБ, пауза 8–14 мс)" python3 "$TMPD/speed-tune.py" apply || warn "параметры отправки не заданы (см. лог)"
  step_run "Перезапуск 3x-ui (применение маршрутизации)" bash -c 'systemctl restart x-ui && sleep 4 && systemctl is-active --quiet x-ui' || warn "x-ui не перезапустился"
  step_run "chain-health, автотест после перезагрузки, проверка сертификата, счётчик соединений" lscript "$TMPD/health-relay.sh" "$VER_PATH" || warn "chain-health установлен не полностью (см. лог)"
  install -m 755 "$TMPD/failclosed.py" /usr/local/bin/chain-failclosed
  install -m 755 "$TMPD/speedtest.py" /usr/local/bin/chain-speedtest

  # [10] мост на BACKEND
  section "BACKEND: мост Xray"
  step_run "Установка Xray $XRAY_VER (проверка SHA-256), запуск chain-bridge, инструменты обновления" backend_bridge || die "мост не запустился (journalctl -u chain-bridge на BACKEND)"
  step_run "Сторож моста (локальный, в сеть ничего не отправляет), keepalive HTTP/2, защита моста" rscript "$TMPD/watchdog-install.sh" || warn "сторож моста установлен не полностью (см. лог)"
  step_run "SSH-ключ RELAY для перезапуска моста (разрешена только эта команда)" setup_restart_key || warn "ключ для перезапуска моста не настроен (см. лог): RELAY не сможет сам перезапустить мост"

  # [11] проверка цепочки
  section "Проверка цепочки"
  local i
  if bridge_wait_or_kick; then
    ok "мост подключился к RELAY (туннельный путь, HTTP/2)"
  else
    warn "мост не подключился даже после перезапусков; журнал BACKEND:"
    bk "journalctl -u chain-bridge -n 6 --no-pager -o cat" 2>>"$LOG" | sed 's/^/      /'
    warn "подробная диагностика записана в $LOG; chain-test на RELAY, journalctl -u chain-bridge на BACKEND"
  fi
  local st=1 stout=""
  for i in 1 2 3; do
    if stout=$(chain_selftest 2>>"$LOG"); then st=0; break; fi
    sleep 5
  done
  [ -n "$stout" ] && info "$stout"
  CHECK_FAIL=0
  if [ $st -eq 0 ]; then
    ok "поток через цепочку работает: выходной IP совпадает с BACKEND"
  elif [ -z "$stout" ] || [[ "$stout" == *"цепочки: нет ответа"* ]]; then
    fail "трафик через цепочку не проходит (ответа нет). Диагностика: chain-test на RELAY; journalctl -u chain-bridge -n 50 на BACKEND"
    CHECK_FAIL=1
  else
    warn "выходной IP цепочки отличается от внешнего IP BACKEND (общий NAT или несколько адресов); если у клиента интернет работает, это не ошибка"
  fi

  if [ -x /usr/local/bin/chain-failclosed ]; then
    local fcr=0 fcout
    fcout=$(/usr/local/bin/chain-failclosed 2>>"$LOG") || fcr=$?
    [ -n "$fcout" ] && printf '%s\n' "$fcout" >>"$LOG"
    case $fcr in
      0) ok "без моста RELAY трафик пользователей в интернет не выпускает (проверено на копии настроек)" ;;
      1) fail "УТЕЧКА: без моста трафик пользователей выходит в интернет с IP RELAY (подробности: chain-failclosed)"; CHECK_FAIL=1 ;;
      *) warn "проверка «без моста нет выхода» не выполнена (запустите chain-failclosed вручную)" ;;
    esac
  fi

  # [12] firewall BACKEND и итог
  section "BACKEND: firewall и итог"
  step_run "ufw: SSH сохранён, все остальные входящие закрыты" rscript "$TMPD/ufw-backend.sh" || warn "firewall BACKEND не настроен (см. лог)"
  if [ $CHECK_FAIL -eq 1 ]; then write_marker "check-failed"; else write_marker "done"; fi
  ok "настройки сохранены: $CONF_FILE, метка установки: $MARKER_FILE"

  local site_code panel_url link
  if [ $HIDE_PANEL -eq 1 ]; then panel_url="скрыта (только SSH-туннель)"; else panel_url="https://$DOMAIN/$xw"; fi
  local tun_port=8999 tun_cmd tun_url
  local rp rk
  rp=$(relay_ssh_port)
  if [ "$rp" = 22 ]; then rk="$RELAY_IP"; else rk="[$RELAY_IP]:$rp"; fi
  tun_cmd="ssh-keygen -R \"$rk\" >/dev/null 2>&1; ssh -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -N -L $tun_port:127.0.0.1:$PANEL_PORT -p $rp -i \"ПУТЬ_К_КЛЮЧУ\" root@$RELAY_IP"
  tun_url="http://127.0.0.1:$tun_port/${xw#/}"
  site_code=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" 2>/dev/null || true)
  link=$(chain_client_link)
  {
    echo "RatBurrow v$RB_VERSION — $(date '+%F %T')"
    echo "RELAY:        $RELAY_IP"
    echo "BACKEND:      $BACKEND_IP (SSH :$BACKEND_PORT)"
    echo "Domain:       $DOMAIN"
    echo "Honeypot URL: https://$DOMAIN/ (HTTP ${site_code:-000})"
    echo "Panel URL:    $panel_url"
    echo "SSH-туннель:  $tun_cmd"
    echo "Панель через туннель: $tun_url"
    echo "Username:     $xu"
    echo "Password:     $xp"
    echo "API Token:    ${xt:-—}"
    echo "Подписка:     https://$DOMAIN${SUB_PATHS}${CHAIN_SUB_ID}"
    echo "Ссылка:       ${link:-—}"
    echo "Путь клиентов: /$USER_PATH/"
    echo "Путь туннеля:  /$TUNNEL_PATH/"
  } > "$REPORT_FILE"
  chmod 600 "$REPORT_FILE"

  echo
  rule
  if [ $CHECK_FAIL -eq 1 ]; then printf '  %sУСТАНОВКА ЗАВЕРШЕНА С ОШИБКОЙ: цепочка не пропускает трафик%s\n' "$YLW" "$R"; else printf '  %sУСТАНОВКА ЗАВЕРШЕНА%s\n' "$GRN" "$R"; fi
  rule
  printf '  %sСАЙТ HONEYPOT%s\n' "$B" "$R"
  printf '  URL:       %shttps://%s/%s\n' "$GRN" "$DOMAIN" "$R"
  printf '  Каталог:   %s/var/www/honeypot/%s%s (RELAY)\n' "$DIM" "$DOMAIN" "$R"
  if [ "$site_code" = "200" ]; then ok "Проверка сайта: HTTP 200"; else warn "Проверка сайта вернула HTTP ${site_code:-000}; проверьте DNS, nginx и лог"; fi
  echo
  printf '  %sПАНЕЛЬ 3X-UI%s\n' "$B" "$R"
  if [ "$HIDE_PANEL" -eq 1 ]; then
    printf '  SSH подключение: %s%s%s\n' "$GRN" "$tun_cmd" "$R"
    printf '  %s(замените ПУТЬ_К_КЛЮЧУ на путь к приватному ключу; окно с туннелем оставьте открытым)%s\n' "$DIM" "$R"
    printf '  URL:       %s%s%s\n' "$GRN" "$tun_url" "$R"
  else
    printf '  URL:       %s%s%s\n' "$GRN" "$panel_url" "$R"
  fi
  printf '  Username:  %s%s%s\n' "$GRN" "$xu" "$R"
  printf '  Password:  %s%s%s\n' "$GRN" "$xp" "$R"
  echo
  printf '  %sКЛИЕНТ (Incy)%s\n' "$B" "$R"
  printf '  Подписка:  %shttps://%s%s%s%s\n' "$GRN" "$DOMAIN" "${SUB_PATHS:-/}" "$CHAIN_SUB_ID" "$R"
  [ -n "$link" ] && printf '  Ссылка:    %s%s%s\n' "$GRN" "$link" "$R"
  echo
  printf '  %sТУННЕЛЬ%s\n' "$B" "$R"
  if [ "$(tunnel_conns)" -ge 1 ]; then ok "BACKEND → RELAY: мост подключён"; else warn "мост не подключён"; fi
  rule
  echo "  ${DIM}Отчёт: $REPORT_FILE (права 600)${R}"
  echo "  ${DIM}Лог:   $LOG${R}"
  echo
  print_service_commands both
  echo
  echo "  ${B}Дальше:${R}"
  echo "   • В Incy добавьте подписку по ссылке выше; новых пользователей создавайте в панели в инбаунде VPN"
  echo "   • Инбаунд TUNNEL служебный (туннель) — не удаляйте и не меняйте"
  echo "   • Сменили IP BACKEND у провайдера: на RELAY выполните chain-set-backend НОВЫЙ_IP (мост подключится сам)"
  echo
  return $CHECK_FAIL
}

# ───────────────────────── обновление компонентов уже настроенной цепочки ─────────────────────────
# Предлагается при запуске на RELAY, если в метке нет версии компонентов (установка 4.3 или 4.4). Пользователи, пути клиентов, подписка
# и сертификат не меняются; мост и 3x-ui не перезапускаются.
component_markers() {
  local lv bv now; now=$(date +%s)
  lv=$(local_xray_version); bv=$(backend_xray_version)
  marker_set_backend COMPONENTS "$RB_VERSION"
  [ -n "$bv" ] && { marker_set_backend XRAY_VERSION "$bv"; marker_set_backend XRAY_SOURCE detected; marker_set_backend XRAY_UPDATED "$now"; marker_set_backend PEER_XRAY_VERSION "${lv:-}"; marker_set_backend PEER_XRAY_SEEN "$now"; }
  [ -n "$lv" ] && { marker_set XRAY_VERSION "$lv"; marker_set XRAY_SOURCE detected; marker_set XRAY_UPDATED "$now"; }
  [ -n "$bv" ] && { marker_set PEER_XRAY_VERSION "$bv"; marker_set PEER_XRAY_SEEN "$now"; }
  marker_set COMPONENTS "$RB_VERSION"   # RELAY — последним: пока его нет, RELAY не обращается к BACKEND командой «версия»
}
run_component_update() {
  INSTALL_KIND="chain"
  STEP=0; TOTAL=5
  if [ -z "${DOMAIN:-}" ] || [ -z "${VER_PATH:-}" ] || [ ! -f /etc/nginx/sites-available/xpn.conf ]; then
    fail "не найдены данные установки (домен, секретный путь, конфиг nginx): обновление возможно только на RELAY, настроенном этим скриптом"
    return 1
  fi
  echo
  echo "${B}Обновление компонентов до v$RB_VERSION${R}"
  thin
  info "RELAY: chain-health запоминает версию Xray в метке (в том числе после обновления через панель 3x-ui); с BACKEND версия сверяется только при запуске скрипта; изменения — в журнале сбоев"
  info "BACKEND: сторож запоминает версию Xray моста; при запуске скрипта RELAY спрашивает её по тому же ограниченному SSH-ключу (команда «версия»)"
  info "RELAY: chain-speedtest (скорость цепочки без вашего канала до RELAY); в инбаунде пользователей задаются параметры отправки (POST 1,2–2 МБ, пауза 8–14 мс), клиенты получают их с подпиской — при неудачной проверке всё возвращается"
  info "RELAY: nginx перезапустится с MALLOC_* (иначе память воркера раздувается до сотен МБ из-за фрагментации heap) и окном HTTP/2 1 МБ вместо 4 МБ: соединения оборвутся на несколько секунд"
  info "пользователи, пути клиентов, подписка и сертификат не меняются; 3x-ui перезапустится один раз (потоки оборвутся на несколько секунд, мост переподключится сам)"
  confirm "Обновить компоненты?" || { echo "  Отменено."; return 0; }
  section "Подключение к BACKEND"
  ask_backend
  [ "${LOCAL_BACKEND:-0}" = 1 ] || ssh_connect
  make_scripts
  section "Журнал сбоев и версии Xray на RELAY"
  step_run "Журнал сбоев на RELAY и BACKEND (записи «ИНФО»)" install_incident_log || die "журнал сбоев не обновлён (см. лог)"
  step_run "RELAY: chain-health (версия Xray, сверка с BACKEND)" lscript "$TMPD/health-relay.sh" "$VER_PATH" || die "RELAY не обновлён (см. лог)"
  step_run "RELAY: nginx — возврат освобождённой памяти системе (MALLOC_*), окно HTTP/2 1 МБ; перезапуск nginx" lscript "$TMPD/nginx-malloc.sh" || warn "ограничение памяти nginx не применено (см. лог)"
  step_run "RELAY: chain-speedtest (скорость цепочки без вашего канала до RELAY)" install -m 755 "$TMPD/speedtest.py" /usr/local/bin/chain-speedtest || warn "chain-speedtest не установлен"
  section "BACKEND"
  step_run "Инструменты моста (chain-update-bridge записывает версию Xray)" rscript "$TMPD/bridge-tools.sh" || die "инструменты моста не обновлены (см. лог)"
  step_run "Сторож моста (запоминает версию Xray) и команда «версия» для RELAY" rscript "$TMPD/watchdog-install.sh" || die "BACKEND не обновлён (см. лог)"
  section "Скорость отправки"
  step_run "Параметры отправки в инбаунде пользователей: применение и проверка (при неудаче откат)" apply_speed_tuning || warn "параметры отправки не применены (подробности в логе); остальное обновлено"
  section "Метка установки"
  step_run "Версии Xray и версия компонентов записаны в метку на RELAY и BACKEND" component_markers || warn "метка обновлена не полностью"
  echo
  rule
  ok "компоненты обновлены до v$RB_VERSION"
  /usr/local/bin/chain-health --show 2>/dev/null || true
  rule
  echo
}

components_old() {  # метка есть, а версии компонентов нет или она старше текущей
  local c; c=$(marker_get COMPONENTS)
  [ -z "$c" ] && return 0
  [ "$c" != "$RB_VERSION" ] && [ "$(printf '%s\n%s\n' "$c" "$RB_VERSION" | sort -V | head -n1)" = "$c" ]
}

# Версии Xray при запуске на RELAY: версия RELAY записывается в метку (в том числе после обновления вне скрипта), версия BACKEND спрашивается по
# ограниченному ключу. При совпадении ничего не выводится; при расхождении — предупреждение, запись в журнале и пункт меню «Обновить Xray» (XRAY_MISMATCH=1).
XRAY_MISMATCH=0
xray_notice() {
  local lv pv now out key=/root/.ssh/chain-restart ip port tried=0
  XRAY_MISMATCH=0
  now=$(date +%s)
  lv=$(marker_get XRAY_VERSION); pv=$(marker_get PEER_XRAY_VERSION)
  out=$(local_xray_version)
  if [ -n "$out" ] && [ "$out" != "$lv" ]; then
    marker_set XRAY_VERSION "$out"; marker_set XRAY_UPDATED "$now"; marker_set XRAY_SOURCE external
    [ -n "$lv" ] && /usr/local/bin/chain-incident --info "Xray" "Xray на RELAY изменён: $lv → $out (обнаружено при запуске скрипта)" >/dev/null 2>&1
    lv=$out
  fi
  # версия BACKEND проверяется только при запуске скрипта (в фоне по сети ничего не проверяется); к BACKEND обращаемся лишь если его компоненты
  # уже обновлены (иначе старый скрипт на BACKEND принял бы «версию» за запрос на перезапуск моста)
  if [ -n "$(marker_get COMPONENTS)" ]; then
    tried=1
    ip=$(marker_get BACKEND_IP); port=$(marker_get BACKEND_PORT); out=""
    if systemctl cat chain-bridge >/dev/null 2>&1; then
      out=$(/usr/local/bin/chain-xray version 2>/dev/null | awk 'NR==1{print $2}')
    elif [ -r "$key" ] && [ -n "$ip" ]; then
      out=$(timeout 25 ssh -i "$key" -p "${port:-22}" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "root@$ip" version 2>/dev/null | sed -n 's/^xray=//p' | head -n1)
    fi
    if [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then marker_set PEER_XRAY_VERSION "$out"; marker_set PEER_XRAY_SEEN "$now"; pv=$out; else pv=""; fi
  fi
  [ -n "$lv" ] || return 0
  if [ -n "$pv" ] && [ "$lv" != "$pv" ]; then
    XRAY_MISMATCH=1
    warn "Версии Xray различаются: RELAY $lv, BACKEND $pv. В меню есть пункт «Обновить Xray» (сначала проба на BACKEND, при неудаче откат)."
    /usr/local/bin/chain-incident "Xray" "версии Xray на RELAY и BACKEND различаются" "RELAY $lv, BACKEND $pv (обнаружено при запуске скрипта): выберите в меню «Обновить Xray»" >/dev/null 2>&1
  elif [ "$tried" = 1 ] && [ -z "$pv" ]; then
    warn "Не удалось узнать версию Xray на BACKEND (по SSH-ключу $key); сравнить версии нельзя"
  fi
}

startup_checks() {
  [ -f "$MARKER_FILE" ] || return 0
  local st role
  st=$(marker_get STATUS); [ "$st" = "done" ] || [ "$st" = "check-failed" ] || return 0
  role=$(marker_get ROLE); role=${role:-relay}
  if [ "$role" = backend ]; then
    info "Xray на BACKEND: $(marker_get XRAY_VERSION | sed 's/^$/версия не записана/')"
    components_old && info "компоненты на этом сервере обновляются со стороны RELAY (при запуске скрипта на RELAY)"
    return 0
  fi
  if components_old; then
    echo
    warn "Эта установка сделана более ранней версией скрипта: в метке нет версий Xray, оповещения о расхождении версий не работают"
    run_component_update
  fi
  xray_notice
}

# Параметры отправки (POST 1,2–2 МБ, пауза 8–14 мс) в инбаунде пользователей: применение, перезапуск x-ui, проверка (скорость и сквозная проверка),
# откат при неудаче. Серверу значения нужны, чтобы принимать крупные POST, клиентам они приходят с подпиской.
apply_speed_tuning() {
  local out rc=0 i
  out=$(python3 "$TMPD/speed-tune.py" apply 2>>"$LOG") || { echo "не удалось изменить инбаунд пользователей"; return 1; }
  echo "$out"
  case "$out" in unchanged*) return 0 ;; esac
  load_user_id >/dev/null 2>&1 || true
  systemctl restart x-ui
  for i in $(seq 1 20); do
    systemctl is-active --quiet x-ui && ss -tlnH "( sport = :21443 )" 2>/dev/null | grep -q . && break
    sleep 2
  done
  wait_bridge || true
  /usr/local/bin/chain-speedtest --check >"$TMPD/speedcheck.out" 2>&1 || rc=$?
  cat "$TMPD/speedcheck.out"
  if [ "$rc" -ne 1 ] && [ -n "${CHAIN_USER_ID:-}" ] && ! selftest_retry; then rc=1; echo "сквозная проверка после изменения не прошла"; fi
  if [ "$rc" -eq 1 ]; then
    python3 "$TMPD/speed-tune.py" revert >>"$LOG" 2>&1 || true
    systemctl restart x-ui
    for i in $(seq 1 20); do systemctl is-active --quiet x-ui && break; sleep 2; done
    /usr/local/bin/chain-incident "скорость" "изменение параметров отправки отменено" "проверка после изменения не прошла, возвращены прежние значения" >/dev/null 2>&1 || true
    echo "возвращены прежние значения"
    return 1
  fi
  [ "$rc" -eq 3 ] && echo "тестовый сервер скорости недоступен: параметры оставлены (сквозная проверка прошла)"
  return 0
}

# ───────────────────────── обновление Xray с пробой на BACKEND ─────────────────────────
wait_bridge() { local i; for i in $(seq 1 25); do [ "$(tunnel_conns)" -ge 1 ] && return 0; sleep 2; done; return 1; }
selftest_retry() {  # сквозная проверка с тремя попытками; вывод — в $TMPD/st.out
  local i
  for i in 1 2 3; do
    if chain_selftest >"$TMPD/st.out" 2>>"$LOG"; then return 0; fi
    sleep 5
  done
  return 1
}
run_update_xray() {
  INSTALL_KIND="chain"
  STEP=0; TOTAL=4
  if [ "$(marker_get ROLE)" = backend ]; then
    fail "этот сервер — BACKEND: обновление Xray запускают на RELAY"
    return 1
  fi
  if [ -z "${DOMAIN:-}" ] || [ ! -f /etc/nginx/sites-available/xpn.conf ]; then
    fail "не найдены данные установки: обновление возможно только на RELAY, настроенном этим скриптом"
    return 1
  fi
  local target cur_b cur_r xr px
  for xr in /usr/local/x-ui/bin/xray-linux-*; do case "$xr" in *.prev) continue ;; esac; break; done
  [ -x "$xr" ] || { fail "Xray из 3x-ui не найден"; return 1; }
  cur_r=$("$xr" version 2>/dev/null | awk 'NR==1{print $2}')
  echo
  echo "${B}Обновление Xray на RELAY и BACKEND${R}"
  thin
  info "порядок: 1) проверка, что цепочка работает; 2) BACKEND — проба: обновление, сквозная проверка, при неудаче автоматический откат и остановка; 3) RELAY — загрузка и проверки на новой версии, затем замена и сквозная проверка (при неудаче откат)"
  info "на каждом сервере сохраняется прежняя версия; при каждом перезапуске потоки оборвутся на несколько секунд"
  local defv
  defv=$(printf '%s\n%s\n' "$cur_r" "$(marker_get PEER_XRAY_VERSION)" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)
  defv=${defv:-$XRAY_VER}
  info "по умолчанию предлагается более новая из двух версий: $defv"
  ask target "Версия Xray (без v)" "$defv"
  target="${target#v}"
  [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { fail "неверная версия: $target (нужен вид 26.10.31)"; return 1; }
  confirm "Обновить Xray до $target?" || { echo "  Отменено."; return 0; }
  section "Подключение к BACKEND"
  ask_backend
  [ "${LOCAL_BACKEND:-0}" = 1 ] || ssh_connect
  make_scripts
  section "Проверка перед обновлением"
  cur_b=$(bk "/usr/local/bin/chain-update-bridge --status" 2>>"$LOG" | sed -n 's/^Xray на BACKEND: //p' | head -n1)
  info "Xray сейчас: RELAY ${cur_r:-?}, BACKEND ${cur_b:-?}; целевая версия $target"
  if [ "$cur_r" = "$target" ] && [ "$cur_b" = "$target" ]; then ok "на обоих серверах уже $target"; return 0; fi
  load_user_id || { fail "не удалось прочитать клиента из базы 3x-ui"; return 1; }
  if ! selftest_retry; then
    fail "цепочка сейчас не работает: обновление не начато (сначала chain-test на RELAY и journalctl -u chain-bridge на BACKEND)"
    return 1
  fi
  ok "цепочка работает: $(cat "$TMPD/st.out")"
  section "BACKEND — проба"
  if [ "$cur_b" = "$target" ]; then
    info "на BACKEND уже $target"
  else
    if ! step_run "Xray на BACKEND: ${cur_b:-?} → $target (прежняя версия сохраняется)" bk "/usr/local/bin/chain-update-bridge $target"; then
      fail "обновление на BACKEND не удалось (откат выполнен автоматически), RELAY не тронут"
      return 1
    fi
    wait_bridge || warn "мост подключается дольше обычного"
    if ! selftest_retry; then
      bk "/usr/local/bin/chain-update-bridge --rollback" >>"$LOG" 2>&1 || true
      bk "/usr/local/bin/chain-incident 'обновление Xray' 'сквозная проверка не прошла на версии $target' 'BACKEND возвращён на прежнюю версию'" >>"$LOG" 2>&1 || true
      fail "на BACKEND с версией $target цепочка не работает: выполнен откат BACKEND, RELAY не тронут"
      return 1
    fi
    ok "BACKEND на $target, цепочка работает"
  fi
  section "RELAY"
  if [ "$cur_r" = "$target" ]; then
    info "на RELAY уже $target"
  else
    px=$(github_proxy_open)
    if ! step_run "RELAY: загрузка $target и проверки на новой версии (в том числе «без моста нет выхода»)" env ALL_PROXY="$px" bash "$TMPD/xray-update-relay.sh" prepare "$target"; then
      github_proxy_close "$px"
      fail "RELAY не обновлён: версия не прошла проверки; BACKEND остаётся на $target (допустимо)"
      return 1
    fi
    github_proxy_close "$px"
    if ! step_run "RELAY: установка $target и перезапуск 3x-ui (прежняя версия сохраняется)" bash "$TMPD/xray-update-relay.sh" apply; then
      fail "RELAY не обновлён (прежняя версия возвращена автоматически)"
      return 1
    fi
    wait_bridge || warn "мост подключается дольше обычного"
    if ! selftest_retry; then
      bash "$TMPD/xray-update-relay.sh" rollback >>"$LOG" 2>&1 || true
      /usr/local/bin/chain-incident "обновление Xray" "сквозная проверка не прошла на RELAY с версией $target" "RELAY возвращён на прежнюю версию" >/dev/null 2>&1 || true
      fail "на RELAY с версией $target цепочка не работает: выполнен откат RELAY"
      return 1
    fi
    ok "RELAY на $target, цепочка работает"
  fi
  marker_set PEER_XRAY_VERSION "$target"; marker_set PEER_XRAY_SEEN "$(date +%s)"
  echo
  rule
  ok "Xray обновлён до $target на обоих серверах; прежние версии сохранены (RELAY: bin/xray-linux-*.prev; BACKEND: chain-update-bridge --rollback)"
  rule
}

# ───────────────────────── откат ─────────────────────────
backend_uninstall() {
  local rc=0
  rscript "$TMPD/uninstall-backend.sh" || rc=$?
  bk "rm -f '$MARKER_FILE'" || true
  return $rc
}

relay_uninstall() {  # relay_uninstall rm_xui rm_web
  local rm_xui="$1" rm_web="$2" d="${DOMAIN:-$(marker_get DOMAIN)}"
  systemctl disable --now chain-site-refresh.timer sync-sub-path.timer chain-xray-version.timer chain-xray-version.path chain-health.timer chain-certcheck.timer chain-boot-test.timer >/dev/null 2>&1 || true
  rm -rf /var/lib/chain /var/lib/chain-incident
  rm -f /etc/systemd/system/chain-certcheck.service /etc/systemd/system/chain-certcheck.timer /etc/systemd/system/chain-boot-test.service /etc/systemd/system/chain-boot-test.timer \
    /usr/local/bin/chain-certcheck /usr/local/bin/chain-boot-test /usr/local/bin/chain-failclosed /usr/local/bin/chain-incident /etc/logrotate.d/chain-incidents \
    /etc/nginx/conf.d/chain-status.conf /etc/systemd/journald.conf.d/chain-limits.conf /root/.ssh/chain-restart /root/.ssh/chain-restart.pub
  rm -f /var/log/chain-incidents.log /var/log/chain-incidents.log.*
  rm -f /etc/systemd/system/chain-health.service /etc/systemd/system/chain-health.timer /usr/local/bin/chain-health /run/chain-health.lock
  rm -f /etc/systemd/system/chain-xray-version.service /etc/systemd/system/chain-xray-version.timer /etc/systemd/system/chain-xray-version.path \
    /usr/local/bin/chain-xray-version /etc/chain-site.endpoints
  rm -f /etc/systemd/system/chain-site-refresh.service /etc/systemd/system/chain-site-refresh.timer \
    /etc/systemd/system/sync-sub-path.service /etc/systemd/system/sync-sub-path.timer \
    /usr/local/bin/chain-status /usr/local/bin/chain-test /usr/local/bin/chain-set-backend /usr/local/bin/chain-site-refresh /usr/local/bin/sync-sub-path \
    /etc/chain-site.domain
  if [ "$rm_web" = 1 ]; then
    rm -f /etc/systemd/system/nginx.service.d/chain-malloc.conf; rmdir /etc/systemd/system/nginx.service.d 2>/dev/null || true
    rm -f /etc/nginx/sites-enabled/xpn.conf /etc/nginx/sites-available/xpn.conf /etc/nginx/sites-enabled/apex.conf /etc/nginx/sites-available/apex.conf \
      /etc/nginx/conf.d/chain-limit.conf /etc/nginx/snippets/chain-headers.conf /etc/nginx/chain-backend.conf
    [ -n "$d" ] && { certbot delete --cert-name "$d" --non-interactive >/dev/null 2>&1 || true; rm -rf "/var/www/honeypot/$d"; }
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    ufw delete allow 80/tcp >/dev/null 2>&1 || true
    ufw delete allow 443/tcp >/dev/null 2>&1 || true
  fi
  if [ "$rm_xui" = 1 ]; then
    systemctl disable --now x-ui >/dev/null 2>&1 || true
    rm -rf /usr/local/x-ui /etc/x-ui /etc/systemd/system/x-ui.service /usr/bin/x-ui
  fi
  rm -f /etc/sysctl.d/99-relay-network-tuning.conf /etc/modules-load.d/relay-bbr.conf
  systemctl daemon-reload
  ufw --force reload >/dev/null 2>&1 || true
  rm -f "$CONF_FILE" "$REPORT_FILE" "$MARKER_FILE"
}

# откат на самом BACKEND (запускается на BACKEND, доступ к RELAY не нужен)
do_uninstall_backend() {
  echo
  echo "${B}Будет удалено${R}"
  thin
  echo "  ${B}BACKEND${R} (этот сервер):"
  info "мост chain-bridge и его Xray (chain-xray), команды chain-set-relay и chain-update-bridge"
  info "журнал сбоев, ключ перезапуска моста, сетевые настройки (BBR, буферы TCP); firewall остаётся закрытым, только SSH"
  info "RELAY этим откатом не затрагивается"
  echo
  confirm "Удалить всё перечисленное?" n || { echo "  Отменено."; return 1; }
  LOCAL_BACKEND=1
  make_scripts
  STEP=0; TOTAL=1
  section "BACKEND (этот сервер)"
  step_run "Удаление моста, служебных команд и настроек" backend_uninstall || warn "часть действий не выполнена (см. лог)"
  echo
  ok "метка установки удалена"
  info "firewall остался закрытым (только SSH); при необходимости: ufw allow <порт>/tcp"
  return 0
}

do_uninstall() {
  STEP=0; TOTAL=2
  echo
  echo "${B}Откат установки${R}"
  thin
  if [ "$(marker_get ROLE)" = backend ]; then do_uninstall_backend; return $?; fi
  local scope
  echo "  Что откатываем?"
  echo "  ${B}1${R}. Только RELAY (доступ к BACKEND не нужен)"
  echo "  ${B}2${R}. Оба сервера: RELAY и BACKEND"
  while true; do
    rd -r -p "${B}?${R} Выберите вариант: " scope
    case "$scope" in 1 | 2) break ;; *) fail "введите 1 или 2" ;; esac
  done
  local rm_xui=0 rm_web=0 reach=0 d
  d="${DOMAIN:-$(marker_get DOMAIN)}"
  if [ "$scope" = 2 ]; then
    echo
    ask_backend
    if [ "${LOCAL_BACKEND:-0}" = 1 ]; then
      reach=1
    else
      ssh_opts
      if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "root@$BACKEND_IP" true >/dev/null 2>"$TMPD/ssh.err"; then
        reach=1
        ok "SSH: root@$BACKEND_IP:$BACKEND_PORT"
      else
        fail "BACKEND недоступен: $(tail -n1 "$TMPD/ssh.err")"
      fi
    fi
  fi
  # на RELAY удаляется только то, что установил скрипт
  if [ "$(marker_get XUI_BY_SCRIPT)" != 0 ] && [ -d /usr/local/x-ui ]; then rm_xui=1; fi
  if [ -f /etc/nginx/sites-available/xpn.conf ] || [ -f /etc/nginx/sites-available/apex.conf ] || { [ -n "$d" ] && [ -d "/var/www/honeypot/$d" ]; }; then rm_web=1; fi
  echo
  echo "${B}Будет удалено${R}"
  thin
  echo "  ${B}RELAY${R} (этот сервер, $RELAY_IP):"
  [ $rm_xui -eq 1 ] && info "3x-ui: панель, пользователи и инбаунды VPN и TUNNEL"
  [ $rm_web -eq 1 ] && info "nginx: конфиг xpn.conf, сайт-приманка, сертификат Let's Encrypt для ${d:-домена}, разрешения ufw для портов 80 и 443"
  info "служебные команды chain-status, chain-test, chain-set-backend, chain-site-refresh, sync-sub-path, chain-xray-version и их таймеры"
  info "сетевые настройки (BBR, буферы TCP)"
  if [ "$scope" = 1 ]; then
    echo "  ${B}BACKEND${R}: не затрагивается"
  elif [ $reach -eq 1 ]; then
    echo "  ${B}BACKEND${R} ($BACKEND_IP):"
    info "мост chain-bridge и его Xray (chain-xray), команды chain-set-relay и chain-update-bridge"
    info "сетевые настройки (BBR, буферы TCP); firewall остаётся закрытым, только SSH"
  else
    echo "  ${B}BACKEND${R} ($BACKEND_IP): недоступен, его настройки останутся"
  fi
  echo
  confirm "Удалить всё перечисленное?" n || { echo "  Отменено."; return 1; }
  make_scripts
  section "BACKEND"
  if [ $reach -eq 1 ]; then
    step_run "Удаление моста, служебных команд и настроек" backend_uninstall || warn "часть действий на BACKEND не выполнена (см. лог)"
  elif [ "$scope" = 1 ]; then
    info "пропущено: выбран откат только RELAY (мост и метка на BACKEND остались; очистить позже — запустить скрипт на BACKEND и выбрать «Откат»)"
  else
    warn "пропущено: BACKEND недоступен"
  fi
  section "RELAY"
  step_run "Удаление служебных команд, сайта, настроек сети" relay_uninstall "$rm_xui" "$rm_web" || warn "часть действий на RELAY не выполнена (см. лог)"
  echo
  ok "метка установки удалена"
  [ $reach -eq 1 ] && info "firewall BACKEND остался закрытым (только SSH); при необходимости: ufw allow <порт>/tcp"
  [ $rm_web -eq 0 ] && info "конфиг nginx и сертификат оставлены (каналы пользователей без моста не работают)"
  return 0
}

# ───────────────────────── части скрипта (отдельные файлы репозитория) ─────────────────────────
# rb-deploy.sh — make_scripts: служебные скрипты RELAY и BACKEND (создаются в $TMPD)
# rb-prepare.sh — «Подготовить сервер»: run_prepare и помощники sshd
# Поиск части: $RB_PARTS_DIR, каталог рядом со скриптом, затем скачивание с $RB_PARTS_URL.
# RB_PART_VERSION в части должен совпадать с RB_VERSION: части разных версий не смешиваются.
RB_PARTS_URL="${RB_PARTS_URL:-https://raw.githubusercontent.com/cryptonoise/ratburrow/refs/heads/main}"
RB_PARTS_DIR="${RB_PARTS_DIR:-}"
RB_PARTS="rb-deploy.sh rb-prepare.sh"
RB_SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then RB_SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || RB_SELF_DIR=""; fi

part_valid() {  # part_valid ФАЙЛ — версия совпадает с RB_VERSION и синтаксис верный
  [ -s "$1" ] || return 1
  [ "$(sed -n 's/^RB_PART_VERSION="\(.*\)"$/\1/p' "$1" | head -n1)" = "$RB_VERSION" ] || return 1
  bash -n "$1" 2>/dev/null
}

part_fetch() {  # part_fetch ИМЯ — кладёт часть в $TMPD/ИМЯ
  local n="$1" dst="$TMPD/$1" d i
  for d in "$RB_PARTS_DIR" "$RB_SELF_DIR"; do
    [ -n "$d" ] && [ -s "$d/$n" ] || continue
    if cp -f "$d/$n" "$dst" 2>/dev/null && part_valid "$dst"; then return 0; fi
  done
  for i in 1 2 3 4; do
    if curl -4 -fsSL --connect-timeout 10 --max-time 60 "$RB_PARTS_URL/$n" -o "$dst" 2>>"$LOG" && part_valid "$dst"; then return 0; fi
    rm -f "$dst"; sleep 2
  done
  return 1
}

load_parts() {
  local n
  for n in $RB_PARTS; do
    part_fetch "$n" || die "не удалось получить $n версии $RB_VERSION ($RB_PARTS_URL). Положите файлы $RB_PARTS рядом со скриптом или задайте RB_PARTS_DIR"
    # shellcheck disable=SC1090
    . "$TMPD/$n" || die "ошибка при подключении $n"
  done
  ok "части скрипта загружены: $RB_PARTS (версия $RB_VERSION)"
}

main() {
  [ "$(id -u)" -eq 0 ] || { echo "Запустите от root: sudo bash $0"; exit 1; }
  mkdir -p "$(dirname "$LOG")"
  ( umask 077; : > "$LOG" ); chmod 600 "$LOG"
  TMPD=$(mktemp -d /tmp/chain-setup.XXXXXX)
  trap cleanup EXIT
  trap 'echo; warn "прервано"; exit 130' INT TERM

  banner

  preflight
  load_parts
  refresh_marker_status
  show_marks
  startup_checks
  menu
  case "$MODE" in
    prepare) run_prepare ;;
    install) run_install ;;
    uninstall) do_uninstall ;;
    update-xray) run_update_xray ;;
    commands) run_service_commands ;;
  esac
}

if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
