#!/usr/bin/env bash

RB_VERSION="4.6"
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
SUB_TITLE="${SUB_TITLE:-}"   # название подписки в клиентах (Incy, Happ): спрашивается при установке
CHAIN_USER_PORT=21443     # 127.0.0.1: инбаунд пользователей (за nginx)
CHAIN_TUNNEL_PORT=21444   # 127.0.0.1: инбаунд туннеля, к которому подключается мост BACKEND (за nginx)
SELFTEST_PORT=21481       # 127.0.0.1: временный клиент для проверки цепочки
XRAY_VER="${XRAY_VER:-26.10.31}"   # закреплённая версия Xray для моста BACKEND (проверена; меняется пунктом меню «Обновить Xray»)
XUI_VER="${XUI_VER:-v3.11.0}"       # закреплённая версия панели 3x-ui для новой установки
TOTAL=12
STEP=0
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

# ───────────────────────── выполнение шагов с анимацией ─────────────────────────
step_run() {  # step_run [-s] "Описание" команда args...   (-s: при ошибке только предупреждение)
  local soft=0
  if [ "${1:-}" = "-s" ]; then soft=1; shift; fi
  local label="$1"
  shift
  local t0=$SECONDS pid rc i=0 clr=""
  [ -t 1 ] && clr=$'\r\033[2K'
  ( "$@" </dev/null >>"$LOG" 2>&1 ) &
  pid=$!
  if [ -t 1 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s%s%s %s %s(%ds)%s\033[K' "$CYN" "${SPIN[i % 10]}" "$R" "$label" "$DIM" $((SECONDS - t0)) "$R"
      i=$((i + 1))
      sleep 0.1
    done
  fi
  wait "$pid"
  rc=$?
  # очистка строки спиннера и итог — одним printf, чтобы ничто не вклинилось между ними
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

# Убираем противоречащие настройки в drop-in конфигах sshd: Include стоит в начале sshd_config,
# и sshd берёт ПЕРВОЕ встреченное значение — правки в основном файле иначе молча игнорируются.
neutralize_sshd_dropins() {
  local f
  for f in "$PR"/etc/ssh/sshd_config.d/*.conf; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "99-preserver.conf" ] && continue
    sed -i -E 's/^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)\b/# [preServer disabled] \1/' "$f"
    if ! grep -qE '^[^#[:space:]]' "$f" 2>/dev/null; then
      rm -f "$f"
      info "удалён пустой drop-in конфиг: $f"
    fi
  done
}

disable_ssh_socket_activation() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.socket'; then
    if systemctl is-enabled ssh.socket &>/dev/null || systemctl is-active ssh.socket &>/dev/null; then
      systemctl stop ssh.socket >/dev/null 2>&1 || true
      systemctl disable ssh.socket >/dev/null 2>&1 || true
      info "обнаружена socket activation (ssh.socket) — отключена, чтобы смена порта применялась без перезагрузки"
    fi
  fi
}

verify_and_restart_sshd() {
  local want_port="$1" want_pwauth="$2" want_rootlogin="$3"
  mkdir -p /run/sshd
  chmod 0755 /run/sshd

  local eff
  eff="$(sshd -T 2>&1)" || {
    fail "sshd -T завершился с ошибкой, перезапуск отменён"
    printf '    Вывод sshd -T:\n%s\n' "$eff"
    return 1
  }

  local eff_port eff_pwauth eff_rootlogin eff_ports
  eff_ports=$(awk '/^port /{print $2}' <<< "$eff")
  eff_port=$(tr '\n' ',' <<< "$eff_ports")
  eff_port="${eff_port%,}"
  eff_pwauth=$(awk '/^passwordauthentication /{print $2; exit}' <<< "$eff")
  eff_rootlogin=$(awk '/^permitrootlogin /{print $2; exit}' <<< "$eff")

  local nw="$want_rootlogin" ne="$eff_rootlogin"
  [ "$nw" = "prohibit-password" ] && nw="without-password"
  [ "$ne" = "prohibit-password" ] && ne="without-password"

  if ! grep -qx "$want_port" <<< "$eff_ports" || [ "$eff_pwauth" != "$want_pwauth" ] || [ "$ne" != "$nw" ]; then
    fail "эффективный конфиг sshd НЕ совпадает с ожидаемым (port=$eff_port pwauth=$eff_pwauth rootlogin=$eff_rootlogin)"
    echo "    Проверьте /etc/ssh/sshd_config.d/*.conf вручную. Перезапуск sshd ОТМЕНЁН."
    return 1
  fi

  local svc="ssh"
  systemctl list-unit-files | grep -q "sshd.service" && svc="sshd"

  disable_ssh_socket_activation

  # остановка ssh.socket/ssh.service удаляет /run/sshd — создаём заново перед sshd -t
  mkdir -p /run/sshd
  chmod 0755 /run/sshd

  if ! sshd -t 2>&1; then
    fail "sshd -t: синтаксическая ошибка, перезапуск отменён"
    return 1
  fi

  systemctl enable "$svc" >/dev/null 2>&1 || true
  systemctl restart "$svc" 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  ok "sshd перезапущен, эффективный конфиг подтверждён (port=$eff_port pwauth=$eff_pwauth rootlogin=$eff_rootlogin)"
  return 0
}

prep_rollback() {
  local cfg="$PR/etc/ssh/sshd_config" old_port=""
  echo
  echo "${B}Откат настроек подготовки сервера${R}"
  thin
  [ -f "$PREP_MARKER_FILE" ] && old_port="$(awk -F= '/^ssh_port=/{print $2; exit}' "$PREP_MARKER_FILE" 2>/dev/null || true)"

  mkdir -p /run/sshd
  chmod 0755 /run/sshd

  if [ -f "$cfg" ]; then
    cp "$cfg" "${cfg}.bak.$(date +%s)"
    neutralize_sshd_dropins

    if grep -qE '^\s*#?\s*Port\b' "$cfg"; then
      sed -i -E 's/^\s*#?\s*Port\b.*/Port 22/' "$cfg"
    else
      echo "Port 22" >> "$cfg"
    fi
    sed -i -E 's/^\s*#?\s*PermitRootLogin\b.*/PermitRootLogin yes/' "$cfg"
    sed -i -E 's/^\s*#?\s*PasswordAuthentication\b.*/PasswordAuthentication yes/' "$cfg"
    sed -i -E 's/^\s*#?\s*PrintMotd\b.*/PrintMotd yes/' "$cfg"
    sed -i -E 's/^\s*#?\s*PrintLastLog\b.*/PrintLastLog yes/' "$cfg"

    if passwd -S root 2>/dev/null | awk '{print $2}' | grep -qE '^(L|LK|NP)$'; then
      warn "у root не задан пароль. Вход по паролю не заработает без: passwd root"
    fi

    if command -v ufw &>/dev/null; then
      ufw allow 22/tcp comment 'SSH (preServer rollback)' >/dev/null 2>&1 || true
      if [[ "$old_port" =~ ^[0-9]+$ ]] && [ "$old_port" != "22" ]; then
        ufw --force delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
        info "правило ufw для порта $old_port (подготовка) удалено, остальные правила не тронуты"
      fi
    fi

    verify_and_restart_sshd 22 yes yes || warn "порт/пароль отредактированы, но перезапуск не выполнен — проверьте вручную!"
  fi

  if dpkg -s fail2ban &>/dev/null; then
    systemctl stop fail2ban >/dev/null 2>&1 || true
    systemctl disable fail2ban >/dev/null 2>&1 || true
    apt-get purge -y fail2ban >/dev/null 2>&1 || true
    rm -f "$PR/etc/fail2ban/jail.local"
    ok "fail2ban удалён"
  fi

  if dpkg -s fastfetch &>/dev/null; then
    apt-get purge -y fastfetch >/dev/null 2>&1 || true
    ok "fastfetch удалён"
  elif command -v fastfetch &>/dev/null; then
    rm -f "$(command -v fastfetch)"
  fi
  rm -rf "$PR/root/.config/fastfetch"
  rm -f "$PR/etc/profile.d/fastfetch-ssh.sh"
  if [ -d "$PR/etc/update-motd.d" ]; then
    chmod +x "$PR"/etc/update-motd.d/* 2>/dev/null || true
  fi

  rm -f "$PR/usr/local/sbin/daily-security-update.sh"
  rm -f "$PR/etc/cron.d/daily-security-update"
  rm -f "$PREP_MARKER_FILE"

  echo
  ok "откат завершён"
  [ -f "$MARKER_FILE" ] && info "установка туннеля/панели этим откатом не затрагивается (для неё — пункт «Отменить установку»)"
  return 0
}

prep_fastfetch_ppa() {
  add-apt-repository -y ppa:zhangsongcui3371/fastfetch &&
    apt-get -o DPkg::Lock::Timeout=300 update -qq &&
    apt-get -o DPkg::Lock::Timeout=300 install -y fastfetch
}

prep_fastfetch_deb() {
  local arch url tmp
  arch=$(dpkg --print-architecture)
  url=$(curl -fsSL "https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest" |
    grep "browser_download_url" | grep "linux-${arch}.deb" | head -1 | cut -d '"' -f 4) || true
  [ -n "$url" ] || return 1
  tmp=$(mktemp)
  curl -fsSL "$url" -o "$tmp"
  dpkg -i "$tmp" || apt-get install -f -y
  rm -f "$tmp"
}

run_prepare() {
  STEP=0; TOTAL=7
  if [ -f "$PREP_MARKER_FILE" ]; then
    echo
    warn "обнаружена метка предыдущей подготовки сервера:"
    sed 's/^/     /' "$PREP_MARKER_FILE"
    echo
    if confirm "Выполнить откат настроек подготовки?" n; then
      prep_rollback
    else
      echo "  Отменено."
    fi
    return 0
  fi

  echo
  echo "${B}Подготовка сервера${R}"
  thin
  info "обновление системы, fail2ban, SSH (свой порт, вход только по ключу), автообновления, fastfetch"
  info "выполняется на ЭТОМ сервере: запустите скрипт отдельно на RELAY и на BACKEND"
  [ -f "$MARKER_FILE" ] && warn "установка туннеля/панели уже выполнена: после смены SSH-порта укажите новый порт при следующих запусках"
  confirm "Начать подготовку?" || { echo "  Отменено."; return 0; }

  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
  export PYTHONWARNINGS="ignore::SyntaxWarning"
  local APT_OPTS=(-o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

  # [1] пакетная база
  section "Проверка пакетной базы"
  if [ -d "$PR/var/lib/dpkg/updates" ] && ls "$PR"/var/lib/dpkg/updates/* >/dev/null 2>&1; then
    warn "обнаружены незавершённые операции dpkg, восстанавливаю..."
    if pgrep -x dpkg >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1; then
      info "apt/dpkg сейчас занят другим процессом — блокировки не трогаю, ждём освобождения"
    else
      rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/apt/lists/lock
    fi
    step_run -s "dpkg --configure -a" dpkg --configure -a --force-confdef --force-confold
    rm -f "$PR"/var/lib/dpkg/updates/*
    step_run -s "dpkg --configure -a (повторно)" dpkg --configure -a
  fi
  ok "пакетная база в порядке"

  # [2] обновление системы
  section "Обновление системы"
  step_run "Обновление списков пакетов" apt-get "${APT_OPTS[@]}" update -qq || die "apt update не удался"
  step_run "Обновление пакетов (upgrade)" apt-get "${APT_OPTS[@]}" upgrade -y || die "apt upgrade не удался"
  step_run "Обновление дистрибутива (dist-upgrade, лимит 30 минут)" timeout --foreground 1800 apt-get "${APT_OPTS[@]}" dist-upgrade -y || {
    rc=$?
    if [ "$rc" -eq 124 ]; then die "apt dist-upgrade завис или превысил лимит 30 минут. Проверьте /var/log/apt/term.log и /var/log/dpkg.log; возможен незавершённый dpkg или запрос действия.";
    else die "apt dist-upgrade завершился с ошибкой (код $rc). Подробности — в $LOG и /var/log/apt/term.log"; fi
  }
  step_run "Удаление ненужных пакетов" apt-get "${APT_OPTS[@]}" autoremove -y || warn "autoremove не выполнен"

  # [3] утилиты и fail2ban
  section "Установка утилит"
  local PACKAGES=(unattended-upgrades fail2ban htop iotop nethogs curl wget git cron ripgrep)
  local missing=() pkg
  for pkg in "${PACKAGES[@]}"; do
    dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    step_run "Установка пакетов: ${missing[*]}" apt-get "${APT_OPTS[@]}" install -y --no-install-recommends "${missing[@]}" || die "не удалось установить пакеты"
  else
    ok "все утилиты уже установлены"
  fi
  mkdir -p "$PR/etc/fail2ban"
  cat > "$PR/etc/fail2ban/jail.local" << 'F2BEOF'
[sshd]
enabled = true
port = 1119
backend = systemd
maxretry = 5
bantime = 1h
findtime = 10m
F2BEOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban >/dev/null 2>&1 || true
  systemctl enable cron >/dev/null 2>&1 || true
  systemctl start cron >/dev/null 2>&1 || true
  ok "fail2ban и утилиты настроены"

  # [4] SSH
  section "Настройка SSH"
  mkdir -p /run/sshd
  chmod 0755 /run/sshd
  local cfg="$PR/etc/ssh/sshd_config" in_port ssh_port key tmpf p
  while true; do
    ask in_port "Введите внутренний порт SSH" "1119"
    ssh_port="$in_port"
    if [[ "$ssh_port" =~ ^[0-9]+$ ]] && [ "$ssh_port" -ge 1 ] && [ "$ssh_port" -le 65535 ]; then
      if command -v ss &>/dev/null && ss -tulnp | grep ":${ssh_port} " | grep -vq sshd; then
        warn "порт $ssh_port занят."
        confirm "Продолжить?" && break || continue
      fi
      break
    else
      fail "порт должен быть числом 1-65535"
    fi
  done
  ok "выбран порт SSH: $ssh_port"

  while true; do
    rd -r -p "${B}?${R} Введите SSH публичный ключ: " key
    if [[ "$key" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\  ]]; then
      break
    else
      fail "неверный формат ключа"
    fi
  done
  ok "ключ принят"

  if [ -f "$cfg" ]; then
    info "sshd будет слушать только порт: $ssh_port (старые порты, включая 22, не сохраняются)"
    cp "$cfg" "${cfg}.bak.$(date +%s)"
    ls -1t "${cfg}".bak.* 2>/dev/null | tail -n +6 | xargs -r rm -f
    neutralize_sshd_dropins

    # Port-строка — в начало файла (чтобы не попасть внутрь блока Match)
    sed -i -E '/^[[:space:]]*#?[[:space:]]*Port[[:space:]]/d' "$cfg"
    tmpf=$(mktemp)
    echo "Port $ssh_port" | cat - "$cfg" > "$tmpf"
    cat "$tmpf" > "$cfg"
    rm -f "$tmpf"

    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$cfg"
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$cfg"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$cfg"
    sed -i 's/^#\?UseDNS.*/UseDNS no/' "$cfg"

    mkdir -p "$PR/root/.ssh" && chmod 700 "$PR/root/.ssh"
    grep -qF "$key" "$PR/root/.ssh/authorized_keys" 2>/dev/null || echo "$key" >> "$PR/root/.ssh/authorized_keys"
    chmod 600 "$PR/root/.ssh/authorized_keys"

    if [ -f "$PR/etc/fail2ban/jail.local" ]; then
      sed -i "s/^port = .*/port = $ssh_port/" "$PR/etc/fail2ban/jail.local"
      systemctl restart fail2ban >/dev/null 2>&1 || true
    fi

    if command -v ufw &>/dev/null; then
      ufw allow "${ssh_port}/tcp" comment 'SSH (preServer)' >/dev/null 2>&1 || true
      ok "порт $ssh_port открыт в ufw"
    fi

    verify_and_restart_sshd "$ssh_port" no prohibit-password || die "ошибка применения настроек SSH: проверьте конфиги вручную"
  else
    warn "файл $cfg не найден — настройка SSH пропущена"
  fi

  # [5] автообновления
  section "Автообновления"
  local UPDATE_SCRIPT="$PR/usr/local/sbin/daily-security-update.sh"
  mkdir -p "$(dirname "$UPDATE_SCRIPT")" "$PR/etc/cron.d"
  cat > "$UPDATE_SCRIPT" << 'EOF'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
LOG_FILE="/var/log/auto-update.log"
{
    echo "===== $(date '+%F %T') start ====="
    apt-get -o DPkg::Lock::Timeout=600 update -qq
    apt-get -o DPkg::Lock::Timeout=600 upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    apt-get autoremove -y
    echo "===== $(date '+%F %T') done ====="
} >> "$LOG_FILE" 2>&1
EOF
  chmod 0755 "$UPDATE_SCRIPT"
  cat > "$PR/etc/cron.d/daily-security-update" << EOF
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root /usr/local/sbin/daily-security-update.sh
EOF
  chmod 0644 "$PR/etc/cron.d/daily-security-update"
  systemctl is-active --quiet cron || systemctl start cron >/dev/null 2>&1 || true
  ok "автообновления настроены (ежедневно в 03:00)"

  # [6] fastfetch
  section "Fastfetch"
  local ff=false
  if command -v fastfetch &>/dev/null; then
    ff=true
    ok "fastfetch уже установлен"
  else
    if command -v add-apt-repository &>/dev/null; then
      step_run -s "Установка Fastfetch (PPA)" prep_fastfetch_ppa && ff=true
    fi
    if ! $ff; then
      step_run -s "Установка Fastfetch (.deb с GitHub)" prep_fastfetch_deb && ff=true
    fi
  fi

  if $ff; then
    mkdir -p "$PR/root/.config/fastfetch"
    cat > "$PR/root/.config/fastfetch/logo.txt" << 'ASCII_LOGO'
+------------------------------+
| +--------------------------+ |
| | +----------------------+ | |
| | | +------------------+ | | |
| | | | +--------------+ | | | |
| | | | | +----------+ | | | | |
| | | | | |          | | | | | |
| | | | | |    ●●    | | | | | |
| | | | | |          | | | | | |
| | | | | +----------+ | | | | |
| | | | +--------------+ | | | |
| | | +------------------+ | | |
| | +----------------------+ | |
| +--------------------------+ |
+------------------------------+
ASCII_LOGO

    cat > "$PR/root/.config/fastfetch/config.jsonc" << 'FFCONFIG'
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": {
        "type": "file",
        "source": "/root/.config/fastfetch/logo.txt",
        "padding": { "top": 1, "left": 2, "right": 4 }
    },
    "display": {
        "color": { "keys": "blue", "title": "bright_magenta", "separator": "white" }
    },
    "modules": [
        { "type": "custom", "format": "\u001b[97m┌──────────────────────────────────────Hardware──────────────────────────────────────┐\u001b[0m" },
        { "type": "host", "key": "▣ PC : ", "keyColor": "green" },
        { "type": "cpu", "key": "   ├▢ CPU: ", "keyColor": "green" },
        { "type": "cpuusage", "key": "   ├▢ Usage: ", "keyColor": "green" },
        { "type": "loadavg", "key": "   ├▢ Load: ", "keyColor": "green" },
        { "type": "gpu", "key": "   ├▢ GPU: ", "keyColor": "green" },
        { "type": "memory", "key": "   ├▢ RAM: ", "keyColor": "green" },
        { "type": "swap", "key": "   ├▢ Swap: ", "keyColor": "green" },
        { "type": "disk", "key": "   ├▢ Disk: ", "keyColor": "green" },
        { "type": "custom", "format": "\u001b[97m└────────────────────────────────────────────────────────────────────────────────────┘\u001b[0m" },
        "break",
        { "type": "custom", "format": "\u001b[97m┌──────────────────────────────────────Software──────────────────────────────────────┐\u001b[0m" },
        { "type": "os", "key": "▣ OS : ", "keyColor": "yellow" },
        { "type": "kernel", "key": "   ├▢ Kernel: ", "keyColor": "yellow" },
        { "type": "packages", "key": "   ├▢ Packages: ", "keyColor": "yellow" },
        { "type": "shell", "key": "   ├▢ Shell: ", "keyColor": "yellow" },
        { "type": "custom", "format": "\u001b[97m└────────────────────────────────────────────────────────────────────────────────────┘\u001b[0m" },
        "break",
        { "type": "custom", "format": "\u001b[97m┌───────────────────────────────────────Network──────────────────────────────────────┐\u001b[0m" },
        { "type": "localip", "key": "▣ IP : ", "keyColor": "cyan" },
        { "type": "command", "key": "   └▢ Location: ", "keyColor": "cyan", "text": "curl -s --max-time 2 https://ipinfo.io/city" },
        { "type": "custom", "format": "\u001b[97m└────────────────────────────────────────────────────────────────────────────────────┘\u001b[0m" },
        "break",
        { "type": "uptime", "key": "▣ UP : ", "keyColor": "magenta" },
        { "type": "datetime", "key": "   └⏰ : ", "keyColor": "magenta" },
        { "type": "colors", "paddingLeft": 2, "symbol": "circle" }
    ]
}
FFCONFIG

    if [ -d "$PR/etc/update-motd.d" ]; then
      chmod -x "$PR"/etc/update-motd.d/* 2>/dev/null || true
    fi
    truncate -s 0 "$PR/etc/motd" 2>/dev/null || true
    if [ -f "$cfg" ]; then
      if grep -q "^PrintMotd" "$cfg" 2>/dev/null; then
        sed -i 's/^PrintMotd.*/PrintMotd no/' "$cfg"
      else
        echo "PrintMotd no" >> "$cfg"
      fi
    fi

    mkdir -p "$PR/etc/profile.d"
    cat > "$PR/etc/profile.d/fastfetch-ssh.sh" << 'PROFEOF'
if [ -n "${FASTFETCH_RAN:-}" ]; then return 0; fi
if [ -n "$SSH_CONNECTION" ] && command -v fastfetch >/dev/null 2>&1; then
    fastfetch
    export FASTFETCH_RAN=1
fi
PROFEOF
    chmod 0644 "$PR/etc/profile.d/fastfetch-ssh.sh"
    ok "fastfetch настроен"
  fi

  # [7] итог
  section "Завершение"
  ok "подготовка сервера завершена"
  kv "SSH port" "${ssh_port:-пропущено}"
  kv "Fail2ban" "активен"
  kv "Fastfetch" "$($ff && echo 'установлен' || echo 'пропущен')"
  kv "Log" "$LOG"
  mkdir -p "$PREP_MARKER_DIR"
  {
    echo "version=$RB_VERSION"
    echo "ran_at=$(date '+%F %T')"
    echo "ssh_port=${ssh_port:-skipped}"
  } > "$PREP_MARKER_FILE"
  warn "проверьте вход по ключу на новом порту ($ssh_port) ДО перезагрузки!"

  if [ -z "$PR" ] && [ -t 1 ] && [ -e /dev/tty ]; then
    echo
    if confirm "Перезагрузить сейчас?" n; then
      reboot
    fi
  fi
  return 0
}

# метки работы со скриптом на ЭТОМ сервере: подготовка сервера и настройка защищённого канала
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


# ───────────────────────── скрипты установки (создаются в $TMPD) ─────────────────────────
make_scripts() {
  local D="$TMPD"

  # Встроенный генератор Honeypot: исходник хранится в читаемом виде без сжатия.
  cat > "$D/honeypot-generator.source.sh" <<'__HONEYPOT_GENERATOR_SOURCE_20261027__'
#!/bin/bash
set -e

# ============================================================
#  Honeypot generator v.0.4
#  Генерация случайного сайта-визитки + nginx + Let's Encrypt
#
#  Использование:
#    ./honeypot-generator.sh [домен]
#
#  Переменные окружения (необязательно):
#    HONEYPOT_SEED=12345     повторить ранее сгенерированный сайт
#    HONEYPOT_DRYRUN=1       только сгенерировать файлы сайта
#                            (без apt / nginx / certbot, root не нужен)
#    HONEYPOT_WEBROOT=/path  каталог сайта (по умолчанию /var/www/honeypot)
# ============================================================

WEBROOT=""
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
DRY_RUN="${HONEYPOT_DRYRUN:-0}"
C_RESET="\\033[0m"; C_CYAN="\\033[36m"; C_GREEN="\\033[32m"; C_YELLOW="\\033[33m"; C_RED="\\033[31m"; C_BOLD="\\033[1m"
if [[ -t 1 ]]; then COLOR=1; else COLOR=0; fi
paint(){ if [ "$COLOR" -eq 1 ]; then printf '%b%s%b\n' "$1" "$2" "$C_RESET"; else printf '%s\n' "$2"; fi; }
line(){ printf '%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'; }
step(){ if [ "$COLOR" -eq 1 ]; then printf '\n%b▶ %s%b\n' "$C_CYAN$C_BOLD" "$1" "$C_RESET"; else printf '\n▶ %s\n' "$1"; fi; }

if [ "$DRY_RUN" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    echo "Запустите скрипт от root (sudo)."
    exit 1
fi

DOMAIN="${1:-}"

if [ -z "$DOMAIN" ]; then
    [[ -t 1 ]] && clear
    paint "$C_CYAN$C_BOLD" "╭────────────────────────────────────────────────────────────╮"
    paint "$C_CYAN$C_BOLD" "│                 HONEYPOT GENERATOR v0.4                    │"
    paint "$C_CYAN$C_BOLD" "╰────────────────────────────────────────────────────────────╯"
    echo "  Генерация сайта • безопасная настройка nginx • HTTPS"
    echo
    read -rp "  Домен (например site.example.com): " DOMAIN
fi

DOMAIN="${DOMAIN,,}"
if [ -z "$DOMAIN" ]; then
    echo "Домен не может быть пустым."
    exit 1
fi
if ! [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]]; then
    echo "Некорректный домен: $DOMAIN"
    exit 1
fi

WEBROOT="${HONEYPOT_WEBROOT:-/var/www/honeypot/$DOMAIN}"
step "1/6  Проверка окружения"
printf "  Домен:     %s\\n  Каталог:   %s\\n  Режим:     %s\\n" "$DOMAIN" "$WEBROOT" "$([ "$DRY_RUN" = "1" ] && echo "dry-run" || echo "установка")"
if [ "$DRY_RUN" != "1" ]; then
    if ! command -v apt-get >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
        paint "$C_RED" "✖ Ожидается Debian/Ubuntu с apt-get и systemd."
        exit 1
    fi
    # ---------- поиск следов ранее настроенного домена ----------
    NGINX_CONFD="/etc/nginx/conf.d"
    LE_DIR="/etc/letsencrypt"
    RENEW_SCRIPT="/usr/local/bin/renew-${DOMAIN}.sh"
    RENEW_LOG="/var/log/renew-${DOMAIN}.log"
    DEFAULT_WEBROOT="/var/www/honeypot/${DOMAIN}"
    DOMAIN_RE="${DOMAIN//./\\.}"
    NGINX_HITS=(); DEL_NGINX=(); BLOCKED=(); CERT_PATHS=(); CERT_NAMES=()
    HAS_WEBROOT=0; HAS_RENEW=0; HAS_CRON=0

    add_uniq() {
        local -n _arr="$1"
        local x
        for x in "${_arr[@]}"; do
            if [ "$x" = "$2" ]; then return 0; fi
        done
        _arr+=("$2")
    }
    # 0, если в server_name файла нет никаких доменов, кроме $2
    only_this_domain() {
        local other
        other="$(grep -hE '^[[:space:]]*server_name[[:space:]]' "$1" 2>/dev/null \
            | sed -E 's/#.*//; s/^[[:space:]]*server_name[[:space:]]+//; s/;.*//' \
            | tr -s ' \t' '\n\n' | grep -v '^$' | grep -vxF "$2" || true)"
        [ -z "$other" ]
    }

    # 1) nginx: конфиги с именем домена, симлинки на них и любые файлы с этим server_name
    for _f in "$NGINX_AVAILABLE/${DOMAIN}.conf" "$NGINX_ENABLED/${DOMAIN}.conf" "$NGINX_CONFD/${DOMAIN}.conf"; do
        if [ -e "$_f" ] || [ -L "$_f" ]; then add_uniq NGINX_HITS "$_f"; fi
    done
    if [ -d "$NGINX_ENABLED" ]; then
        _exact_real="$(readlink -f "$NGINX_AVAILABLE/${DOMAIN}.conf" 2>/dev/null || true)"
        for _f in "$NGINX_ENABLED"/*; do
            if [ -L "$_f" ] && [ "$(readlink -f "$_f" 2>/dev/null || true)" = "$_exact_real" ]; then
                add_uniq NGINX_HITS "$_f"
            fi
        done
    fi
    _dirs=()
    for _d in "$NGINX_AVAILABLE" "$NGINX_ENABLED" "$NGINX_CONFD"; do
        if [ -d "$_d" ]; then _dirs+=("$_d"); fi
    done
    if [ "${#_dirs[@]}" -gt 0 ]; then
        while IFS= read -r _f; do
            if [ -n "$_f" ]; then add_uniq NGINX_HITS "$_f"; fi
        done < <(grep -RIlE "^[[:space:]]*server_name[[:space:]]([^;]*[[:space:]])?${DOMAIN_RE}[[:space:];]" "${_dirs[@]}" 2>/dev/null || true)
    fi
    for _f in "${NGINX_HITS[@]}"; do
        if [ -L "$_f" ] && [ ! -e "$_f" ]; then
            add_uniq DEL_NGINX "$_f"                  # битая ссылка
        elif only_this_domain "$_f" "$DOMAIN"; then
            add_uniq DEL_NGINX "$_f"
        else
            add_uniq BLOCKED "$_f"                    # в файле есть другие домены
        fi
    done
    if [ "${#BLOCKED[@]}" -gt 0 ]; then
        paint "$C_RED" "✖ Домен указан в конфигурации nginx вместе с другими доменами:"
        printf '    %s\n' "${BLOCKED[@]}"
        echo "  Автоматическое удаление небезопасно. Уберите домен из server_name вручную и запустите скрипт снова."
        exit 1
    fi

    # 2) сертификаты Let's Encrypt (live / archive / renewal)
    for _p in "$LE_DIR/live/${DOMAIN}" "$LE_DIR"/live/"${DOMAIN}"-[0-9][0-9][0-9][0-9] \
              "$LE_DIR/archive/${DOMAIN}" "$LE_DIR"/archive/"${DOMAIN}"-[0-9][0-9][0-9][0-9] \
              "$LE_DIR/renewal/${DOMAIN}.conf" "$LE_DIR"/renewal/"${DOMAIN}"-[0-9][0-9][0-9][0-9].conf; do
        if [ -e "$_p" ] || [ -L "$_p" ]; then
            add_uniq CERT_PATHS "$_p"
            _n="$(basename "$_p")"
            case "$_p" in */renewal/*) _n="${_n%.conf}" ;; esac
            add_uniq CERT_NAMES "$_n"
        fi
    done

    # 3) каталог сайта, скрипт автообновления, cron
    if [ -d "$WEBROOT" ] && [ -n "$(find "$WEBROOT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then HAS_WEBROOT=1; fi
    if [ -e "$RENEW_SCRIPT" ]; then HAS_RENEW=1; fi
    if crontab -l 2>/dev/null | grep -qF "$RENEW_SCRIPT"; then HAS_CRON=1; fi

    if [ $(( ${#DEL_NGINX[@]} + ${#CERT_PATHS[@]} + HAS_WEBROOT + HAS_RENEW + HAS_CRON )) -gt 0 ]; then
        paint "$C_YELLOW" "⚠ Домен уже настраивался на этом сервере. Найдено:"
        for _f in "${DEL_NGINX[@]}"; do echo "    nginx:        $_f"; done
        for _p in "${CERT_PATHS[@]}"; do echo "    сертификат:   $_p"; done
        if [ "$HAS_WEBROOT" -eq 1 ]; then
            if [ "$WEBROOT" = "$DEFAULT_WEBROOT" ]; then
                echo "    каталог:      $WEBROOT"
            else
                echo "    каталог:      $WEBROOT (нестандартный путь — удалён не будет, файлы будут перезаписаны)"
            fi
        fi
        if [ "$HAS_RENEW" -eq 1 ]; then echo "    автообновление: $RENEW_SCRIPT"; fi
        if [ "$HAS_CRON" -eq 1 ]; then echo "    cron:         задание для $RENEW_SCRIPT"; fi
        echo

        while :; do
            if ! read -rp "  Удалить конфигурацию для этого домена и создать заново? [Y/n] (Enter = да): " ANSWER; then
                echo; echo "Отменено."; exit 1
            fi
            case "$ANSWER" in
                ""|y|Y|yes|YES|Yes|д|Д|да|Да|ДА) break ;;
                n|N|no|NO|No|н|Н|нет|Нет|НЕТ) echo "Отменено. Ничего не изменено."; exit 0 ;;
                *) echo "  Введите y или n (Enter = да)." ;;
            esac
        done

        # --- удаление: nginx (сначала ссылки, затем сами конфиги) ---
        for _f in "${DEL_NGINX[@]}"; do
            if [ -L "$_f" ]; then rm -f -- "$_f"; fi
        done
        for _f in "${DEL_NGINX[@]}"; do
            rm -f -- "$_f"
        done
        # --- сертификаты: штатно через certbot, запасной вариант — вручную ---
        for _n in "${CERT_NAMES[@]}"; do
            if command -v certbot >/dev/null 2>&1; then
                certbot delete --cert-name "$_n" --non-interactive >/dev/null 2>&1 || true
            fi
            rm -rf -- "$LE_DIR/live/$_n" "$LE_DIR/archive/$_n" "$LE_DIR/renewal/$_n.conf"
        done
        # --- автообновление и cron ---
        if [ "$HAS_CRON" -eq 1 ]; then
            ( crontab -l 2>/dev/null | grep -vF "$RENEW_SCRIPT" || true ) | crontab -
        fi
        rm -f -- "$RENEW_SCRIPT" "$RENEW_LOG"
        # --- каталог сайта: только стандартный путь /var/www/honeypot/<домен> ---
        if [ "$WEBROOT" = "$DEFAULT_WEBROOT" ] && [ -d "$WEBROOT" ]; then
            rm -rf -- "$WEBROOT"
        fi
        # --- применить удаление в работающем nginx ---
        if [ "${#DEL_NGINX[@]}" -gt 0 ] && command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1 || true
        fi
        paint "$C_GREEN" "  ✓ Старая конфигурация удалена, создаю заново."
    fi
fi

# ------------------------------------------------------------
# Проверка и установка зависимостей
# ------------------------------------------------------------
if [ "$DRY_RUN" != "1" ]; then
    step "2/6  Проверка и установка зависимостей"

    export DEBIAN_FRONTEND=noninteractive
    APT_UPDATED=0

    install_if_missing() {
        local pkg="$1"
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            echo "  -> $pkg не найден, устанавливаю..."
            if [ "$APT_UPDATED" -eq 0 ]; then
                apt-get update -qq
                APT_UPDATED=1
            fi
            apt-get install -y "$pkg"
        else
            echo "  -> $pkg уже установлен"
        fi
    }

    install_if_missing nginx
    install_if_missing certbot
    install_if_missing python3-certbot-nginx
    mkdir -p /var/www/certbot
fi

mkdir -p "$WEBROOT"

# ============================================================
#  ГЕНЕРАТОР САЙТА
# ============================================================
step "3/6  Генерация сайта"

# ---------- сид (для воспроизводимости) ----------
SEED="${HONEYPOT_SEED:-$(( (RANDOM << 15) | RANDOM ))}"
RANDOM=$SEED

# ---------- помощники (без подоболочек, чтобы сид работал корректно) ----------
LETTERS=ABCDEFGHIJKLMNOPQRSTUVWXYZ
CA_LETTERS=ABCEGHJKLMNPRSTVWXYZ
R=""
rnd()    { R=$(( $1 + RANDOM % ($2 - $1 + 1) )); }
chance() { if (( RANDOM % 100 < $1 )); then R=1; else R=0; fi; }
pick()   { local -n _pa=$1; R="${_pa[RANDOM % ${#_pa[@]}]}"; }
shuffle() {
    local -n _sa=$1
    local i j t
    for (( i=${#_sa[@]}-1; i>0; i-- )); do
        j=$(( RANDOM % (i+1) ))
        t="${_sa[i]}"; _sa[i]="${_sa[j]}"; _sa[j]="$t"
    done
}
fmt_fill() {   # N цифра, L буква, P буква (CA), строчная буква = литерал, остальное как есть
    local f="$1" out="" c i
    for (( i=0; i<${#f}; i++ )); do
        c="${f:i:1}"
        case "$c" in
            N) out+=$(( RANDOM % 10 )) ;;
            L) out+="${LETTERS:RANDOM%26:1}" ;;
            P) out+="${CA_LETTERS:RANDOM%20:1}" ;;
            [[:lower:]]) out+="${c^^}" ;;
            *) out+="$c" ;;
        esac
    done
    R="$out"
}
html_esc() {
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
    R="$s"
}
hsl2hex() {
    awk -v h="$1" -v s="$2" -v l="$3" '
    function mn(a,b){return a<b?a:b}
    function mx(a,b){return a>b?a:b}
    function f(n,  k,a,t){k=(n+h/30)%12; a=(s/100)*mn(l/100,1-l/100);
        t=mx(-1,mn(mn(k-3,9-k),1)); return int((l/100-a*t)*255+0.5)}
    BEGIN{printf "#%02x%02x%02x",f(0),f(8),f(4)}'
}

CUR_YEAR=$(date +%Y)

# ============================================================
#  ПУЛЫ ДАННЫХ И ГЕНЕРАТОРЫ
#  Готовых предложений в коде нет: тексты собираются из шаблонов
#  по токенам @NAME@ (см. expand), слова берутся из словарей P_NAME.
#  Словари содержат только слова и короткие фразы по тематике.
# ============================================================

# ---------- общие словари (не зависят от тематики) ----------
P_SIZE=("a small" "an independent" "a friendly" "a close-knit" "an experienced" "a dedicated")
P_QUAL=("with care" "on schedule" "in a clear, structured way" "step by step" "without surprises" "to a clear brief" "with attention to detail" "on time and on budget")
P_DELIV=(delivered handled provided managed)
P_TRAIT=(calm direct thorough responsive friendly reliable patient honest professional practical "well prepared" "easy to work with")
P_TRUST=(trust recommend)
P_REF=(recommendation referrals "word of mouth")
P_EXP=("a pleasure" "refreshingly straightforward" "easy from the first call" "a real relief" "far easier than we expected")
P_QRES=("better than we expected" "exactly what we needed" "delivered on time" "clear and easy to follow" "a real improvement for our team" "handled with great care")
P_RECO=(recommend "happily recommend" "gladly recommend" "highly recommend")
P_LEADIN=("You can count on us to" "Our team will" "Expect us to" "We are here to")
P_LISTEN=("learning about" "looking closely at" "getting to know" "reviewing" "asking about")
P_ST1=(Discover Listen Brief Introduction Scope)
P_ST2=(Plan Assess Review Propose)
P_ST3=(Deliver Implement Execute Produce)
P_ST4=(Support Follow-up Handover Aftercare)
P_SMALL=(small simple urgent routine)
P_LARGE=(large complex long-term ambitious)
P_PADJ=(simple clear transparent straightforward)
P_INFORMED=(informed "up to date" "on the same page" "in the loop")
P_FIRSTW=(call conversation meeting enquiry)
P_LASTW=(delivery handover review sign-off)
P_KIND=("A few words" "Some kind words" "Feedback" "Comments")
P_LUCKY=(lucky grateful fortunate)
P_GIVE=("are generous with their feedback" "share their experience openly" "tell us honestly what they think")
P_CVERB=("Call, write or drop by" "Tell us about your project" "Get in touch whenever it suits you" "Send us a message or give us a call")
P_REPLY=("We usually reply" "We aim to reply" "You will normally hear back")
P_DAYS=("one working day" "a day" "24 hours" "two working days")

# ---------- шаблоны текста ----------
HERO_TPL=("@HADJ@ @HNOUN@ for @WHO@" "@HNOUN@ that @HTAIL@" "@HNOUN@ you can @TRUST@")
TAG_TPL=("@HADJ@ @HNOUN@, @DELIV@ @QUAL@." "@HNOUN@ for @WHO@, @DELIV@ @QUAL@." "@SIZE@ @TEAM@ of @PRO@, focused on @CARE@.")
LEAD_TPL=(
 "We @ACT@, @ACT2@ and @ACT3@ for @WHO@."
 "@SIZE@ @TEAM@ of @PRO@ who @ACT@ and @ACT2@, @QUAL@."
 "We help @WHO@ @GOAL@ and @GOAL2@, @QUAL@."
 "From the first @FIRSTW@ to the final @LASTW@, we @ACT@ and @ACT2@ for @WHO@."
)
AS_ID=(
 "We are @SIZE@ @TEAM@ of @PRO@ who care about @CARE@, @CARE2@ and @CARE3@."
 "Our @TEAM@ of @PRO@ is focused on @CARE@, and we @ACT@ for @WHO@."
 "We are @SIZE@ @TEAM@ of @PRO@, and we @ACT@ for @WHO@."
)
AS_CL=(
 "Most of our clients come to us through @REF@, and many have stayed with us for years."
 "Our clients include @CLIENT@, @CLIENT2@ and @CLIENT3@."
 "We work with @CLIENT@ and @CLIENT2@, and most of them find us through @REF@."
)
AS_WORK=(
 "Each project starts with a conversation about your @OBJ@ and ends with @OUT@."
 "We keep our team deliberately small, so the people you meet first are the people who @ACT@ and @ACT2@."
 "Whatever the size of the job, you deal directly with the @PRO@ responsible for it."
 "We @ACT@, @ACT2@ and @ACT3@, always @QUAL@."
 "You can expect us to @ACT@ @QUAL@, and to @ACT2@ without fuss."
)
ABOUT_LOC_TPL=(
 "Founded in @YEAR@ and based in @CITY@, we work with @CLIENT@, @CLIENT2@ and @CLIENT3@ across @COUNTRYTHE@."
 "Since @YEAR@ we have been working from @CITY@, helping @CLIENT@ and @CLIENT2@ across @COUNTRYTHE@ and beyond."
 "Our office in @CITY@ has been home to the team since @YEAR@, and we work with clients locally and across @COUNTRYTHE@."
)
P_SVCTPL=(
 "We @ACT@ and @ACT2@, @QUAL@."
 "@LEADIN@ @ACT@ and @ACT2@."
 "A practical service for @WHO@: we @ACT@, then @ACT2@."
 "We help @WHO@ @GOAL@, and we @ACT@ @QUAL@."
 "Our @PRO@ @ACT@, @QUAL@, from the first @FIRSTW@ to the final @LASTW@."
 "We help @WHO@ @GOAL@ and @GOAL2@, @QUAL@."
)
PT_S1=("We start by @LISTEN@ your @OBJ@, so we understand what a good result looks like." "We begin with a conversation about your @OBJ@ and @OBJ2@.")
PT_S2=("We @ACT@ and share what we find, @QUAL@." "A specialist team will @ACT@ and @ACT2@.")
PT_S3=("You receive @OUT@, prepared @QUAL@." "We deliver @OUT@, ready for you to use.")
PT_S4=("We stay involved after delivery to @ACT@ as your needs change." "You keep the same contact, who will @ACT@ whenever you need us.")
QT_TPL=(
 "They @DONE@ and the result was @QRES@."
 "They were @TRAIT@, @TRAIT2@ and @TRAIT3@ from the first @FIRSTW@ to the final @LASTW@. We would @RECO@ them to anyone who needs help with their @OBJ@."
 "Working with them was @EXP@. They @DONE@ and @DONE2@."
 "We have worked with them more than once. Each time they @DONE@, and the invoice matched the quote."
)
SUBSVC_TPL=("Here is how we can help @WHO@." "Whether the need is @SMALL@ or @LARGE@, we shape the work around you." "A focused set of services for @WHO@, @DELIV@ @QUAL@.")
SUBPROC_TPL=("A @PADJ@ process that keeps everyone @INFORMED@." "No surprises, just clear steps from the first @FIRSTW@ to the final @LASTW@.")
SUBQ_TPL=("@KIND@ from people we have worked with." "We are @LUCKY@ to work with clients who @GIVE@.")
SUBC_TPL=("@CVERB@. @REPLY@ within @DAYS@." "@REPLY@ within @DAYS@. @CVERB@.")

# ---------- значения (название|варианты фраз после «We») ----------
VALUES=(
 "Plain language|explain things clearly|avoid jargon|write in plain English|keep every message easy to follow"
 "Honest estimates|quote fairly|agree prices in advance|flag changes before they cost you|keep invoices in line with quotes"
 "Direct access|put you in touch with the people doing the work|keep one named contact for every project|answer your calls ourselves"
 "Long-term thinking|aim for results that last|think beyond the first project|look after clients for years"
 "Careful delivery|respect deadlines|check the details twice|keep everyone informed along the way"
 "Fair pricing|keep our fees clear|agree costs in advance|avoid hidden extras"
 "Discretion|keep your information confidential|treat every project as private|share details only when needed"
 "Responsiveness|reply within one working day|answer messages promptly|keep you updated as work progresses"
)

H_ABOUT=("About us" "Who we are" "Our story" "A little about us")
H_SVC=("Services" "What we do" "How we can help" "Our expertise" "What we offer")
H_PROC=("How we work" "Our approach" "Working together" "The process")
H_QUOTES=("What clients say" "Client feedback" "Kind words" "In their words")
H_CONTACT=("Get in touch" "Contact us" "Let's talk" "Visit or write to us")
CTA_NAV=("Contact us" "Get in touch" "Talk to us" "Request a call")
CTA_HERO1=("Get in touch" "Start a conversation" "Request a quote" "Book an introductory call")
CTA_HERO2=("See our services" "What we do" "Explore services" "Learn more")

# ---------- словари для имён, адресов, часов ----------
FIRST=(Anna James Maria Daniel Sofia Liam Elena Marcus Priya Thomas Hannah Omar Claire Lucas Nina Peter Grace Samuel Julia Victor Amara Ethan Clara Felix Isla Noah Maya Oliver Leila Henry Zoe Adam Rosa Jonas Tessa Owen Mira Callum Freya Ravi Ingrid Joel Dana Hugo Esme Kai Lena Theo)
ROLES=("Managing Director" "Operations Manager" "Founder" "Head of Finance" "Project Lead" "Office Manager" "Product Owner" "Marketing Director" "Owner" "Head of Operations" "Partner")
ORG_NOUN=(Foods Dental Housing Retail Farms Clinic Energy Hotels Electronics Bakery Engineering Textiles Media Publishing Dairy Pharmacy Motors Interiors)
SN_STEM=(Hart Ash Whit Brook Cal Fen Kings Mar Ridge Stan Thorn Wood Ellis Har Lind Pres Sut Bren Del Hol Alder Fair Green Hill Long Mer Nor Oak Pen Rob Sand Strat Tay Wal Win Ember Cross Rowan)
SN_END=(ley ford ton well wick field more man worth son ham by den ward ridge)
BR_ON=(b d f g h k l m n p r s t v z br dr fl gr kr pr tr)
BR_VO=(a e i o u)
BR_CO=("" "" n r l s m x)
BR_EN=(a o is on ia um ar en ix el)
WORDS=(Nord Vela Lumen Aster Vero Arcus Solace Pelago Meridian Orbit Cobalt Juniper Beacon Quarry Tern Alba Kestrel Linden Marlow Corvus Tallis Halden Oriel Verity)
PRE=(North West Iron Clear Silver Fox Birch Cedar Elm Oak Lark Tide Bright Green Grey Red Pine Wren Ash Summer Harbor Mill)
POST=(field wood stone light well bridge gate path ridge brook point haven line vale)
ST_STEM=(Maple Harbor Mill Park King Queen Church Station Elm Victoria Bridge Orchard Cedar Market Lake Grove Albert Willow Meadow Hill River High)
ST_TYPE=(Street Road Avenue Lane Way Square Court)
NL_STEM=(Kerk Molen Linden Haven Markt Bloem Oranje Konings Zuider Noorder Dijk Beuk Wilgen Prins)
NL_SUF=(straat laan weg gracht)
UNIT_KIND=(Suite Unit)
EMAIL_LOCALS=(info hello contact office mail team enquiries)
HR_DAYS=("Mon–Fri" "Monday to Friday" "Weekdays")
HR_MIN=(00 30)

# ---------- темы: словари по отрасли ----------
# P_HADJ/P_HNOUN — заголовки; P_ACT — «we ...» (инфинитив с объектом);
# P_GOAL — «help X ...»; P_OBJ — «your ...»; P_OUT — результат с артиклем;
# P_TOPIC × P_FORM и P_SOLO — названия услуг; P_DONE — прошедшее время для отзывов.
theme_consulting() {
  T_KEY=consulting; T_INDUSTRY="management consultancy"; T_SCHEMA=ProfessionalService
  T_SUFFIX=(Consulting Advisory Partners Group)
  P_HADJ=(Clear Practical Independent Honest Careful); P_HNOUN=(advice thinking planning support analysis)
  P_HTAIL=("turns into results" "keeps projects on track" "your team can follow" "survives contact with reality")
  P_WHO=("growing businesses" "owners and managers" "small and mid-sized companies" "leadership teams" "ambitious organizations")
  P_PRO=(advisers consultants "business analysts"); P_TEAM=(team group)
  P_CARE=("practical results" "clear communication" "honest advice" "long-term relationships" "getting the details right" "plain language")
  P_ACT=("untangle complex decisions" "review how the business runs" "map your priorities and risks" "plan the next stage of growth" "tighten processes and reporting" "agree realistic goals and timelines" "bring leadership teams to a shared view" "identify where costs can come down" "turn strategy into a delivery plan" "support teams through change" "benchmark performance against the market" "prepare boards and investors for key decisions")
  P_GOAL=("make confident decisions" "focus on what matters most" "plan growth with fewer surprises" "run more efficiently" "bring teams together behind one plan" "manage change without disruption")
  P_OBJ=(priorities processes goals plans challenges costs)
  P_OUT=("a short, prioritized plan" "a clear set of recommendations" "a practical roadmap" "a candid written assessment" "a realistic budget and timeline")
  P_CLIENT=("family businesses" start-ups manufacturers "local charities" retailers schools "professional firms" "housing associations")
  P_TOPIC=(Strategy Operations Change Market Project Performance Growth Risk); P_FORM=(review planning support advisory workshops)
  P_SOLO=("Management coaching" "Executive workshops" "Due diligence support")
  P_DONE=("reviewed how our business runs" "untangled a difficult decision for us" "built a plan we could actually follow" "brought our leadership team onto the same page" "found savings we had missed" "guided us through a major change")
  T_STATS=("Projects delivered|80|420" "Clients advised|40|180")
}
theme_design() {
  T_KEY=design; T_INDUSTRY="design studio"; T_SCHEMA=ProfessionalService
  T_SUFFIX=(Studio Design "Design Studio" Creative)
  P_HADJ=(Thoughtful Considered Distinctive Clear Honest); P_HNOUN=(design branding "visual identity" "web design")
  P_HTAIL=("earns its place" "people remember" "lasts for years" "works as hard as you do")
  P_WHO=("ambitious brands" "small and mid-sized organizations" "founders and cultural organizations" "growing businesses" "independent companies")
  P_PRO=(designers "designers and developers" "designers and art directors"); P_TEAM=(studio team)
  P_CARE=(clarity craft "making things useful first" "getting every detail right" "work that lasts" "honest feedback")
  P_ACT=("design identities that grow with you" "shape brand guidelines your team can use" "design websites that are easy to maintain" "lay out reports and printed materials" "direct photography and campaigns" "develop clear visual systems" "turn rough ideas into finished work" "refine logos, type and color" "prepare final files for print and web" "design packaging that works on the shelf" "present ideas with clear reasoning" "test layouts with real content")
  P_GOAL=("look as good as they work" "stand out for the right reasons" "explain what they do more clearly" "present themselves consistently" "launch with confidence")
  P_OBJ=(audience goals content ideas "brand history" preferences)
  P_OUT=("a small number of well-developed directions" "a complete set of brand guidelines" "polished, production-ready files" "a clear visual direction" "a site design ready for build")
  P_CLIENT=(founders "cultural organizations" "local businesses" publishers restaurants charities "technology companies" architects)
  P_TOPIC=(Brand Website Packaging Editorial Print Campaign Product Identity); P_FORM=(design direction workshops)
  P_SOLO=("Design systems" "Art direction" "Logo and type design" "Photography direction")
  P_DONE=("turned a vague brief into an identity we are proud of" "redesigned our website from the ground up" "made our printed material look far better" "gave our brand a clear and consistent look" "rebuilt our packaging from scratch" "listened carefully and got the tone exactly right")
  T_STATS=("Brands launched|45|260" "Websites shipped|60|310")
}
theme_architecture() {
  T_KEY=architecture; T_INDUSTRY="architecture and interiors practice"; T_SCHEMA=ProfessionalService
  T_SUFFIX=(Architects "Architecture Studio" "Design Office" Interiors)
  P_HADJ=(Considered Thoughtful Sustainable Practical Careful); P_HNOUN=(architecture "interior design" "residential design" "building design")
  P_HTAIL=("fits the way you live" "is shaped by light and place" "stands up to daily use")
  P_WHO=("families and homeowners" "growing businesses" "private clients" "developers and landlords" "people who care about their space")
  P_PRO=(architects "architects and interior designers" "architects and designers"); P_TEAM=(practice studio)
  P_CARE=("light and proportion" "listening before drawing" "buildings that last" "getting the details right" "practical, buildable design")
  P_ACT=("design homes, extensions and renovations" "plan interiors around how you live" "prepare and submit planning applications" "advise on what a site can offer" "detail drawings so builders can price with confidence" "supervise construction on site" "select materials and lighting" "guide projects through planning and building control" "test ideas with sketches and models" "coordinate engineers and consultants" "check the work against the drawings" "keep the project on budget")
  P_GOAL=("make the most of their space" "build with confidence" "turn a site into a home" "get planning approval with fewer surprises" "stay on budget during construction")
  P_OBJ=(site brief budget timeline ideas "planning constraints")
  P_OUT=("concept sketches and models" "a full set of detailed drawings" "a clear planning submission" "an honest feasibility report" "a specification builders can price")
  P_CLIENT=(homeowners developers "local businesses" schools landlords "restaurants and shops" "housing associations" "cultural venues")
  P_TOPIC=(Residential Commercial Interior Heritage Extension Retail Workplace Landscape); P_FORM=(design consultancy planning supervision)
  P_SOLO=("Feasibility studies" "Planning applications" "Site supervision" "Building surveys")
  P_DONE=("turned a dark, awkward house into a bright home" "guided us through planning without any drama" "kept the build on budget" "designed a space that works for how we live" "explained every drawing patiently")
  T_STATS=("Buildings completed|30|140" "Planning approvals|40|190")
}
theme_accounting() {
  T_KEY=accounting; T_INDUSTRY="accounting and tax advisory firm"; T_SCHEMA=AccountingService
  T_SUFFIX=(Accountants "Tax Advisory" "Financial Services" "& Co.")
  P_HADJ=(Dependable Straightforward Accurate Personal Careful); P_HNOUN=(accounting "tax advice" bookkeeping "financial support" "business advice")
  P_HTAIL=("keeps you on top of deadlines" "explains the numbers clearly" "saves time every month" "grows with your business")
  P_WHO=("small businesses" "self-employed professionals" "families and owners" "start-ups and freelancers" "growing companies")
  P_PRO=(accountants "accountants and tax advisers" "bookkeepers and accountants"); P_TEAM=(practice team)
  P_CARE=(accuracy "meeting deadlines" "plain language" "long-term relationships" "keeping things simple")
  P_ACT=("prepare annual accounts and tax returns" "keep your records accurate and up to date" "plan tax sensibly and within the rules" "run payroll and pensions" "handle sales tax and VAT returns" "build budgets and forecasts" "answer questions promptly and clearly" "spot savings and deadlines early" "reconcile accounts every month" "prepare management reports" "advise on the right business structure" "deal with the tax authorities on your behalf")
  P_GOAL=("keep on top of their finances" "pay no more tax than they need to" "meet every filing deadline" "understand their numbers" "plan for the year ahead")
  P_OBJ=(records "tax position" deadlines "cash flow" "business goals" paperwork)
  P_OUT=("accurate, filed accounts" "a clear summary of your tax position" "a simple calendar of deadlines" "a budget you can work to" "regular management reports")
  P_CLIENT=("sole traders" "family businesses" landlords start-ups freelancers charities contractors "professional practices")
  P_TOPIC=(Business Personal Corporate Property Startup Contractor); P_FORM=("tax planning" accounts bookkeeping advisory compliance)
  P_SOLO=(Payroll "Annual accounts" "Sales tax and VAT" "Financial forecasting")
  P_DONE=("sorted out our accounts after years of stress" "saved us a considerable amount in tax" "explained our options in plain English" "kept every deadline without reminders" "set up a bookkeeping routine that works")
  T_STATS=("Clients served|120|650" "Returns filed each year|300|1900")
}
theme_software() {
  T_KEY=software; T_INDUSTRY="software development company"; T_SCHEMA=Organization
  T_SUFFIX=(Labs Software Systems Digital Works)
  P_HADJ=(Reliable Practical Maintainable Secure Clean); P_HNOUN=("software engineering" "web development" "app development" "custom software")
  P_HTAIL=("your team can maintain" "is built to last" "ships every few weeks" "stays out of your way")
  P_WHO=("growing teams" "startups and established companies" "ambitious organizations" "product teams" "small and mid-sized businesses")
  P_PRO=(engineers "engineers and designers" developers); P_TEAM=(team group)
  P_CARE=("clean code" "honest estimates" "regular releases" "software that lasts" "keeping things simple")
  P_ACT=("build web and mobile applications" "connect your existing tools and data" "modernize legacy systems carefully" "set up reliable deployment pipelines" "review architecture and code quality" "test thoroughly before every release" "ship working software every few weeks" "monitor and maintain what we build" "document the system for your own team" "estimate the work honestly before we start" "secure applications against common attacks" "hand over clean, readable code")
  P_GOAL=("ship with confidence" "retire fragile legacy systems" "automate repetitive work" "make their data work together" "release more often with fewer surprises")
  P_OBJ=(requirements "existing systems" "technical constraints" goals deadlines "release plans")
  P_OUT=("a working first release" "a clear technical proposal" "a tested and documented system" "a realistic delivery plan" "clean, well-documented code")
  P_CLIENT=(startups "retail companies" "logistics firms" clinics schools "financial firms" agencies manufacturers)
  P_TOPIC=(Web Mobile Cloud Data Backend Frontend Cross-platform); P_FORM=(development engineering architecture testing support integration)
  P_SOLO=("API integration" "Legacy modernization" "DevOps and deployment" "Technical audits")
  P_DONE=("delivered on time with clean code" "migrated our legacy system without downtime" "built an app our customers love" "connected our tools so data flows automatically" "made our releases uneventful")
  T_STATS=("Products launched|25|130" "Integrations built|40|220")
}
theme_logistics() {
  T_KEY=logistics; T_INDUSTRY="freight and logistics company"; T_SCHEMA=Organization
  T_SUFFIX=(Logistics Freight Transport "Supply Chain" Cargo)
  P_HADJ=(Reliable Dependable Efficient Flexible Careful); P_HNOUN=(freight transport logistics "door-to-door delivery" warehousing)
  P_HTAIL=("arrives when promised" "keeps your goods moving" "is tracked from door to door" "handles the paperwork for you")
  P_WHO=("growing businesses" "importers and exporters" "manufacturers and retailers" "small and mid-sized companies" "online sellers")
  P_PRO=("logistics specialists" "freight coordinators" "transport planners"); P_TEAM=(team group)
  P_CARE=("keeping promises" "answering the phone" "reliable delivery" "clear communication" "getting goods there on time")
  P_ACT=("arrange road, sea and air freight" "handle customs clearance and paperwork" "store and pick goods in secure warehouses" "plan routes and schedules" "track every shipment" "coordinate collection and delivery" "keep you updated if anything changes" "advise on costs and carriers" "pack and label goods correctly" "book the best carrier for each load" "confirm delivery at the door" "check documents before they reach the border")
  P_GOAL=("move goods across borders" "keep delivery promises" "cut transport costs" "clear customs without delays" "ship with fewer surprises")
  P_OBJ=("delivery needs" volumes routes deadlines "shipping requirements" destinations)
  P_OUT=("a clear price for the whole journey" "tracking for every shipment" "proof of delivery sent straight to you" "a collection schedule" "complete customs documentation")
  P_CLIENT=(importers retailers manufacturers wholesalers "online sellers" "food producers" "construction firms" "furniture makers")
  P_TOPIC=(Road Sea Air Rail International Cross-border Domestic Express); P_FORM=(freight transport shipping)
  P_SOLO=("Customs clearance" Warehousing "Last-mile delivery" "Supply chain planning")
  P_DONE=("delivered everything on time" "took the customs paperwork off our hands" "told us about delays before we had to ask" "found us a cheaper route" "handled a difficult shipment calmly")
  T_STATS=("Shipments handled|900|9500" "Countries served|12|48")
}
theme_language() {
  T_KEY=language; T_INDUSTRY="translation and localization agency"; T_SCHEMA=ProfessionalService
  T_SUFFIX=(Translations Languages Linguistics "Language Services" Localization)
  P_HADJ=(Accurate Natural Careful Reliable Clear); P_HNOUN=(translation localization interpreting "language services" "technical translation")
  P_HTAIL=("sounds natural in every language" "keeps your meaning intact" "reads as if written locally" "your customers understand")
  P_WHO=("global teams" "international businesses" "law firms and manufacturers" "software companies" "importers and exporters")
  P_PRO=(linguists translators "translators and editors"); P_TEAM=(team agency)
  P_CARE=("tone as well as grammar" "getting terminology right" accuracy "meeting deadlines" "natural-sounding language")
  P_ACT=("translate documents accurately" "adapt websites for local audiences" "provide interpreters for meetings and events" "review every translation with a second linguist" "follow your preferred terminology" "deliver files in the original format" "produce certified translations" "add subtitles to videos and training material" "keep a glossary for every client" "check numbers, names and dates twice" "match the tone of the original" "work with specialists in your field")
  P_GOAL=("speak to customers in their own language" "enter new markets with confidence" "keep terminology consistent" "publish in several languages at once" "make sure nothing is lost in translation")
  P_OBJ=("source texts" terminology audience deadlines "target languages" "style preferences")
  P_OUT=("finished files in the original format" "a consistent glossary of terms" "a translation reviewed by a second linguist" "certified documents ready to submit" "a localized version ready to publish")
  P_CLIENT=("law firms" manufacturers "software companies" charities hospitals "travel companies" universities "online retailers")
  P_TOPIC=(Legal Medical Technical Website Marketing Financial Software); P_FORM=(translation localization proofreading review)
  P_SOLO=(Interpreting Subtitling "Certified translation" Transcription)
  P_DONE=("caught an error in our source text that nobody else noticed" "made our manuals consistent across every market" "delivered fast without cutting corners" "adapted our website so it feels local" "handled our legal translations without a single query")
  T_STATS=("Projects completed|300|2600" "Linguists in our network|40|220")
}
THEMES=(consulting design architecture accounting software logistics language)
pick THEMES; "theme_$R"

# ---------- страны: ISO → Название|Формы|lang|og:locale|орфография|дата|стиль улиц ----------
declare -A CINFO=(
 [US]="United States|LLC,Inc.,Corp.|en-US|en_US|us|mdy|en"
 [CA]="Canada|Inc.,Ltd.,Corp.|en-CA|en_CA|us|mdy|en"
 [GB]="United Kingdom|Ltd,LLP|en-GB|en_GB|uk|dmy|en"
 [IE]="Ireland|Ltd,DAC|en-IE|en_IE|uk|dmy|en"
 [NL]="Netherlands|B.V.,V.O.F.|en|en_GB|uk|dmy|nl"
 [SG]="Singapore|Pte. Ltd.|en-SG|en_SG|uk|dmy|en"
 [AU]="Australia|Pty Ltd|en-AU|en_AU|uk|dmy|en"
 [NZ]="New Zealand|Ltd|en-NZ|en_NZ|uk|dmy|en"
)
COUNTRY_ISOS=(US CA GB IE NL SG AU NZ)

# ---------- города: Город|Регион|ISO|Телефон|Индекс ----------
# N — цифра, L — буква, P — буква для канадских индексов, строчная буква — как есть.
# Диапазоны номеров — вымышленные (555-01xx, Ofcom drama и т. п.).
CITIES=(
 "Austin|TX|US|+1 512 555 01NN|787NN"
 "Denver|CO|US|+1 303 555 01NN|802NN"
 "Seattle|WA|US|+1 206 555 01NN|981NN"
 "Boston|MA|US|+1 617 555 01NN|021NN"
 "Chicago|IL|US|+1 312 555 01NN|606NN"
 "Atlanta|GA|US|+1 404 555 01NN|303NN"
 "Portland|OR|US|+1 503 555 01NN|972NN"
 "Miami|FL|US|+1 305 555 01NN|331NN"
 "Raleigh|NC|US|+1 919 555 01NN|276NN"
 "Minneapolis|MN|US|+1 612 555 01NN|554NN"
 "Nashville|TN|US|+1 615 555 01NN|372NN"
 "Phoenix|AZ|US|+1 602 555 01NN|850NN"
 "Toronto|ON|CA|+1 416 555 01NN|mNP NPN"
 "Vancouver|BC|CA|+1 604 555 01NN|vNP NPN"
 "Montreal|QC|CA|+1 514 555 01NN|hNP NPN"
 "Calgary|AB|CA|+1 403 555 01NN|tNP NPN"
 "Ottawa|ON|CA|+1 613 555 01NN|kNP NPN"
 "Edmonton|AB|CA|+1 780 555 01NN|tNP NPN"
 "Winnipeg|MB|CA|+1 204 555 01NN|rNP NPN"
 "Halifax|NS|CA|+1 902 555 01NN|bNP NPN"
 "London||GB|+44 20 7946 0NNN|swN NLL"
 "Manchester||GB|+44 161 496 0NNN|mN NLL"
 "Birmingham||GB|+44 121 496 0NNN|bN NLL"
 "Leeds||GB|+44 113 496 0NNN|lsN NLL"
 "Glasgow||GB|+44 141 496 0NNN|gN NLL"
 "Edinburgh||GB|+44 131 496 0NNN|ehN NLL"
 "Bristol||GB|+44 117 496 0NNN|bsN NLL"
 "Cardiff||GB|+44 29 2018 0NNN|cfNN NLL"
 "Sheffield||GB|+44 114 496 0NNN|sN NLL"
 "Liverpool||GB|+44 151 496 0NNN|lN NLL"
 "Dublin||IE|+353 1 5NN NNNN|d0N LNNN"
 "Cork||IE|+353 21 5NN NNNN|t12 LNNN"
 "Galway||IE|+353 91 5NN NNNN|h91 LNNN"
 "Limerick||IE|+353 61 5NN NNNN|v94 LNNN"
 "Waterford||IE|+353 51 5NN NNNN|x91 LNNN"
 "Amsterdam||NL|+31 20 5NN NNNN|10NN LL"
 "Rotterdam||NL|+31 10 5NN NNNN|30NN LL"
 "Utrecht||NL|+31 30 5NN NNNN|35NN LL"
 "The Hague||NL|+31 70 5NN NNNN|25NN LL"
 "Eindhoven||NL|+31 40 5NN NNNN|56NN LL"
 "Groningen||NL|+31 50 5NN NNNN|97NN LL"
 "Singapore||SG|+65 6NNN NNNN|0NNNNN"
 "Melbourne|VIC|AU|+61 3 5550 NNNN|30NN"
 "Sydney|NSW|AU|+61 2 5550 NNNN|20NN"
 "Brisbane|QLD|AU|+61 7 5550 NNNN|40NN"
 "Perth|WA|AU|+61 8 5550 NNNN|60NN"
 "Adelaide|SA|AU|+61 8 5550 NNNN|50NN"
 "Canberra|ACT|AU|+61 2 5550 NNNN|26NN"
 "Auckland||NZ|+64 9 5NN NNNN|1NNN"
 "Wellington||NZ|+64 4 5NN NNNN|6NNN"
 "Christchurch||NZ|+64 3 5NN NNNN|8NNN"
)

# ---------- страна → город → телефон/индекс/орфография ----------
pick COUNTRY_ISOS; ISO="$R"
CITY_ROWS=()
for _row in "${CITIES[@]}"; do
    case "$_row" in *"|$ISO|"*) CITY_ROWS+=("$_row") ;; esac
done
pick CITY_ROWS
IFS='|' read -r CITY REGION _iso PHONE_FMT POST_FMT <<< "$R"
IFS='|' read -r COUNTRY LEGALS LANG_CODE OG_LOCALE SPELL DATE_STYLE STREET_STYLE <<< "${CINFO[$ISO]}"
IFS=',' read -ra LEGAL_LIST <<< "$LEGALS"
pick LEGAL_LIST; LEGAL="$R"
if [ "${LEGAL: -1}" = "." ]; then LEGAL_DOT=""; else LEGAL_DOT="."; fi
case "$ISO" in GB|US|NL) COUNTRY_THE="the $COUNTRY" ;; *) COUNTRY_THE="$COUNTRY" ;; esac
fmt_fill "$PHONE_FMT"; PHONE="$R"
fmt_fill "$POST_FMT";  POST="$R"

# ---------- движок текста ----------
declare -A QI=()
# Берёт слово из словаря P_<имя> «колодой»: повторов нет, пока колода не кончится
pick_q() {
    local n="$1" i
    declare -ga "Q_$n"
    local -n _qs="P_$n" _qq="Q_$n"
    if [ "${#_qs[@]}" -eq 0 ]; then R=""; return 0; fi
    i="${QI[$n]:-}"
    if [ -z "$i" ] || [ "$i" -ge "${#_qq[@]}" ]; then
        _qq=("${_qs[@]}"); shuffle _qq; i=0
    fi
    R="${_qq[$i]}"
    QI[$n]=$(( i + 1 ))
}
# a/an по первой букве следующего слова
fix_art() {
    local -a w; local i nx
    read -ra w <<< "$1"
    for (( i=0; i<${#w[@]}-1; i++ )); do
        case "${w[i]}" in
            a|A)
                nx="${w[i+1],,}"
                case "$nx" in
                    one*|use*|uni*|eu*) ;;
                    hour*|honest*|honour*) w[i]="${w[i]}n" ;;
                    [aeiou]*) w[i]="${w[i]}n" ;;
                esac ;;
        esac
    done
    R="${w[*]}"
}
UK_MAP=("organization:organisation" "organized:organised" "organize:organise" "color:colour" "Localization:Localisation" "localization:localisation" "localized:localised" "modernization:modernisation" "modernize:modernise" "prioritized:prioritised" "specialized:specialised" "customized:customised" "analyze:analyse" "Harbor:Harbour")
spell_str() {
    local s="$1" p
    if [ "$SPELL" = uk ]; then
        for p in "${UK_MAP[@]}"; do s="${s//${p%%:*}/${p##*:}}"; done
    fi
    R="$s"
}
# Подставляет @TOKEN@ (и @TOKEN2@, @TOKEN3@) словами из P_TOKEN, затем чинит a/an и орфографию
expand() {
    local t="$1" tok base
    while [[ "$t" =~ @([A-Z]+)([0-9]*)@ ]]; do
        tok="${BASH_REMATCH[0]}"; base="${BASH_REMATCH[1]}"
        pick_q "$base"
        t="${t/"$tok"/"$R"}"
    done
    fix_art "$t"; spell_str "$R"
}
gen() { pick "$1"; expand "$R"; R="${R^}"; }   # случайный шаблон из массива → текст

# ---------- имена ----------
gen_surname() {
    local a
    pick SN_STEM; a="$R"; pick SN_END
    if [ "${a: -1}" = "${R:0:1}" ]; then R="${R:1}"; fi
    R="${a}${R}"
}
gen_brand() {
    local s v
    pick BR_ON; s="$R"; pick BR_VO; s+="$R"
    pick BR_ON; s+="$R"; pick BR_VO; s+="$R"
    chance 55
    if [ "$R" -eq 1 ]; then pick BR_EN; else pick BR_CO; fi
    s+="$R"
    R="${s^}"
}
gen_org() {
    local a
    rnd 0 2
    case "$R" in
        0) gen_brand; a="$R" ;;
        1) pick PRE; a="$R"; pick POST; a="${a}${R}" ;;
        *) gen_surname; a="$R" ;;
    esac
    pick ORG_NOUN; R="$a $R"
}

# ---------- адрес и часы ----------
gen_address() {
    local num stem typ unit="" k
    rnd 3 240; num="$R"
    if [ "$STREET_STYLE" = nl ]; then
        pick NL_STEM; stem="$R"; pick NL_SUF
        ADDR1="${stem}${R} ${num}"
        return 0
    fi
    chance 55
    if [ "$R" -eq 1 ]; then pick ST_STEM; else gen_surname; fi
    stem="$R"; pick ST_TYPE; typ="$R"
    chance 45
    if [ "$R" -eq 1 ]; then
        if [ "$ISO" = SG ]; then
            fmt_fill "#NN-NN"; unit="$R"
        else
            rnd 0 2
            if [ "$R" -eq 0 ]; then
                rnd 1 4; k="$R"
                case "$k" in 1) unit="1st Floor" ;; 2) unit="2nd Floor" ;; 3) unit="3rd Floor" ;; *) unit="4th Floor" ;; esac
            else
                pick UNIT_KIND; rnd 1 9; unit="$R"
                pick UNIT_KIND; unit="$R $unit"
            fi
        fi
    fi
    if [ -n "$unit" ]; then ADDR1="${unit}, ${num} ${stem} ${typ}"; else ADDR1="${num} ${stem} ${typ}"; fi
}
gen_hours() {
    local d oh om ch cm
    pick HR_DAYS; d="$R"
    rnd 8 9; oh="$R"; pick HR_MIN; om="$R"
    rnd 16 18; ch="$R"; pick HR_MIN; cm="$R"
    case "$ISO" in
        US|CA|AU|NZ) OPEN_HOURS="${d}, ${oh}:${om} AM – $((ch - 12)):${cm} PM" ;;
        *)           OPEN_HOURS="${d}, ${oh}:${om}–${ch}:${cm}" ;;
    esac
}

# ---------- орфография для тематических полей ----------
spell_str "$T_INDUSTRY"; T_INDUSTRY="$R"
for _i in "${!T_SUFFIX[@]}"; do spell_str "${T_SUFFIX[_i]}"; T_SUFFIX[_i]="$R"; done

# ---------- название компании ----------
pick T_SUFFIX; SUF="$R"
gen_surname; S1="$R"; gen_surname; S2="$R"
while [ "$S2" = "$S1" ]; do gen_surname; S2="$R"; done
chance 60
if [ "$R" -eq 1 ]; then pick WORDS; else gen_brand; fi
W1="$R"
pick PRE; P1="$R"; pick POST; P2="$R"
# Основа названия — левая «значимая» метка домена (rescorp.norest.art → Rescorp);
# варианты: «Rescorp Consulting» (суффикс темы), «Rescorp Group», «Rescorp & Co.», «Rescorp».
# HONEYPOT_RANDOM_NAME=1 — вернуть полностью случайные названия.
BRAND_GENERIC=(www mail smtp imap pop ftp vpn panel admin app api web cdn static portal login secure sub new old test dev stage)
BRAND_TAILS=(Group Partners Holdings Associates Collective Works)
domain_brand() {   # → R = «Rescorp» (или пусто, если подходящей метки нет)
    local -a labels; local i n l w out=""
    IFS='.' read -ra labels <<< "$DOMAIN"
    n=$(( ${#labels[@]} - 1 ))          # последняя метка — TLD
    for (( i=0; i<n; i++ )); do
        l="${labels[i]}"
        if [ "${#l}" -lt 3 ]; then continue; fi
        case " ${BRAND_GENERIC[*]} " in *" $l "*) continue ;; esac
        for w in ${l//-/ }; do out+="${out:+ }${w^}"; done
        break
    done
    R="$out"
}
BRAND=""
if [ "${HONEYPOT_RANDOM_NAME:-0}" != "1" ]; then domain_brand; BRAND="$R"; fi
pick BRAND_TAILS; TAIL="$R"
if [ -n "$BRAND" ]; then
    rnd 0 4
    case "$R" in
        0|1) COMPANY="$BRAND $SUF" ;;
        2|4) COMPANY="$BRAND $TAIL" ;;
        *)   COMPANY="$BRAND" ;;
    esac
else
rnd 0 4
case "$R" in
    0) COMPANY="$S1 & $S2"
       chance 50
       if [ "$R" -eq 1 ] && [ "${SUF:0:1}" != "&" ]; then COMPANY="$COMPANY $SUF"; fi ;;
    1) COMPANY="$W1 $SUF" ;;
    2) COMPANY="$S1 $SUF" ;;
    3) COMPANY="${P1}${P2}"
       chance 70
       if [ "$R" -eq 1 ]; then COMPANY="$COMPANY $SUF"; fi ;;
    4) COMPANY="$W1"
       chance 80
       if [ "$R" -eq 1 ]; then COMPANY="$COMPANY $SUF"; fi ;;
esac
fi
html_esc "$COMPANY"; COMPANY_H="$R"
INITIAL="${COMPANY:0:1}"

# ---------- прочие случайные значения ----------
rnd 2004 $((CUR_YEAR - 3)); YEAR="$R"
pick EMAIL_LOCALS; EMAIL="${R}@${DOMAIN}"
gen_hours
gen_address
if [ "$STREET_STYLE" = nl ]; then
    ADDR2="${POST} ${CITY}"
elif [ -n "$REGION" ]; then
    ADDR2="${CITY}, ${REGION} ${POST}"
else
    ADDR2="${CITY} ${POST}"
fi
REGION_JSON=""
if [ -n "$REGION" ]; then REGION_JSON="\"addressRegion\":\"${REGION}\","; fi

# ---------- тексты из шаблонов ----------
P_YEAR=("$YEAR"); P_CITY=("$CITY"); P_COUNTRYTHE=("$COUNTRY_THE")

gen HERO_TPL; HERO="$R"
HERO_HEAD="${HERO% *}"; HERO_LAST="${HERO##* }"
gen TAG_TPL;  TAGLINE="$R"
gen LEAD_TPL; LEAD="$R"

# услуги: «тема + форма» или самостоятельное название, описание по шаблону
gen_services() {
    local n="$1" i tries title t d used="|"
    SV=()
    for (( i=0; i<n; i++ )); do
        tries=0
        while :; do
            chance 28
            if [ "$R" -eq 1 ]; then
                pick P_SOLO; title="$R"; t="$R"
            else
                pick P_TOPIC; t="$R"; pick P_FORM; title="$t $R"
            fi
            tries=$(( tries + 1 ))
            case "$used" in
                *"|$title|"*|*"|t:$t|"*) if [ "$tries" -lt 15 ]; then continue; fi ;;
            esac
            break
        done
        used+="$title|t:$t|"
        spell_str "$title"; title="$R"
        pick_q SVCTPL; expand "$R"; d="${R^}"
        SV+=("$title|$d")
    done
}
rnd 0 2
case "$R" in 0) NSV=3 ;; 1) NSV=4 ;; 2) NSV=6 ;; esac
gen_services "$NSV"
SVC1="${SV[0]%%|*}"; SVC2="${SV[1]%%|*}"; SVC3="${SV[2]%%|*}"

# «о нас»
gen AS_ID; A1="$R"
pick AS_WORK; W_A="$R"; expand "$W_A"; A1+=" ${R^}"
gen AS_CL; A2="$R"
pick AS_WORK; while [ "$R" = "$W_A" ]; do pick AS_WORK; done
expand "$R"; A2+=" ${R^}"
T_ABOUT=("$A1" "$A2")
gen ABOUT_LOC_TPL; ABOUT3="$R"

# процесс из четырёх этапов
T_PROC=()
for _k in 1 2 3 4; do
    pick "P_ST$_k"; _nm="$R"
    gen "PT_S$_k"
    T_PROC+=("$_nm|$R")
done

# ценности
VU=("${VALUES[@]}"); shuffle VU
VS=()
for _u in "${VU[@]:0:3}"; do
    IFS='|' read -ra _vp <<< "$_u"
    _vt="${_vp[0]}"; _vp=("${_vp[@]:1}"); shuffle _vp
    VS+=("$_vt|We ${_vp[0]} and ${_vp[1]}.")
done

# отзывы (имена и организации добавляются при сборке секции)
T_QUOTES=()
for _qt in "${QT_TPL[@]}"; do expand "$_qt"; T_QUOTES+=("${R^}"); done

# заголовки и подписи
pick H_ABOUT; HT_ABOUT="$R"
pick H_SVC; HT_SVC="$R"
pick H_PROC; HT_PROC="$R"
pick H_QUOTES; HT_QUOTES="$R"
pick H_CONTACT; HT_CONTACT="$R"
gen SUBSVC_TPL;  ST_SVC="$R"
gen SUBPROC_TPL; ST_PROC="$R"
gen SUBQ_TPL;    ST_QUOTES="$R"
gen SUBC_TPL;    ST_CONTACT="$R"
pick CTA_NAV; BTN_NAV="$R"
pick CTA_HERO1; BTN_HERO1="$R"
pick CTA_HERO2; BTN_HERO2="$R"

case "${T_INDUSTRY:0:1}" in a|e|i|o|u) ARTICLE="an" ;; *) ARTICLE="a" ;; esac
EYEBROWS=("${CITY}, ${COUNTRY}" "${T_INDUSTRY^}" "Est. ${YEAR}" "Independent since ${YEAR}" "${T_INDUSTRY^} in ${CITY}")
pick EYEBROWS; EYEBROW="$R"

# ---------- метаданные ----------
rnd 0 4
case "$R" in
    0) TITLE="${COMPANY} | ${T_INDUSTRY^} in ${CITY}" ;;
    1) TITLE="${COMPANY} — ${SVC1}, ${SVC2}" ;;
    2) TITLE="${COMPANY} · ${T_INDUSTRY^}" ;;
    3) TITLE="${SVC1} in ${CITY} | ${COMPANY}" ;;
    4) TITLE="${COMPANY} — ${TAGLINE%.}" ;;
esac
rnd 0 2
case "$R" in
    0) META_DESC="${COMPANY} — ${T_INDUSTRY} in ${CITY}. ${TAGLINE}" ;;
    1) META_DESC="${COMPANY} is ${ARTICLE} ${T_INDUSTRY} based in ${CITY}. We offer ${SVC1,,}, ${SVC2,,} and ${SVC3,,}." ;;
    2) META_DESC="${TAGLINE} ${COMPANY} offers ${SVC1,,} and ${SVC2,,} for clients in ${CITY} and beyond." ;;
esac
html_esc "$TITLE"; TITLE_H="$R"
html_esc "$META_DESC"; META_DESC_H="$R"

KW_TAG=""
chance 40
if [ "$R" -eq 1 ]; then
    KW_TAG="<meta name=\"keywords\" content=\"${T_INDUSTRY}, ${SVC1,,}, ${SVC2,,}, ${SVC3,,}, ${CITY}\">"
fi
TW_TAG=""
chance 65
if [ "$R" -eq 1 ]; then TW_TAG="1"; fi

JSONLD="<script type=\"application/ld+json\">
{\"@context\":\"https://schema.org\",\"@type\":\"${T_SCHEMA}\",\"name\":\"${COMPANY}\",\"url\":\"https://${DOMAIN}/\",\"description\":\"${META_DESC}\",\"email\":\"${EMAIL}\",\"telephone\":\"${PHONE}\",\"foundingDate\":\"${YEAR}\",\"address\":{\"@type\":\"PostalAddress\",\"streetAddress\":\"${ADDR1}\",${REGION_JSON}\"addressLocality\":\"${CITY}\",\"postalCode\":\"${POST}\",\"addressCountry\":\"${ISO}\"}}
</script>"

# ============================================================
#  ДИЗАЙН
# ============================================================
LAYOUTS=(a b c d);           pick LAYOUTS;  LAYOUT="$R"
BGS=(grad mesh grid dots noise stripes solid anim); pick BGS; BG_KIND="$R"
CARDS=(flat outline shadow glass accent);           pick CARDS; CARD="$R"
SVCS=(grid list cols);       pick SVCS; SVC_STYLE="$R"

rnd 0 359; H="$R"
rnd 0 3
case "$R" in
    0) H2=$(( (H + 30) % 360 )) ;;
    1) H2=$(( (H + 150) % 360 )) ;;
    2) H2=$(( (H + 180) % 360 )) ;;
    3) H2=$(( (H + 210) % 360 )) ;;
esac
rnd 55 85; SAT="$R"
chance 55
if [ "$R" -eq 1 ]; then MODE=dark; else MODE=light; fi

if [ "$MODE" = dark ]; then
    rnd 8 14; BGL="$R"; rnd 18 40; BGS_="$R"; rnd 58 68; AL="$R"
    BG="hsl($H,${BGS_}%,${BGL}%)"; BG2="hsl($H,${BGS_}%,$((BGL + 6))%)"
    SURFACE="hsla(0,0%,100%,.05)"; GLASS="hsla(0,0%,100%,.07)"
    TEXT="hsl($H,15%,93%)"; MUTED="hsl($H,10%,70%)"
    ACCENT="hsl($H,${SAT}%,${AL}%)"; ACCENT2="hsl($H2,${SAT}%,${AL}%)"
    ON_ACC="hsl($H,40%,10%)"; ON_HEX="$(hsl2hex "$H" 40 10)"
    GLOW="hsla($H,${SAT}%,${AL}%,.22)"; GLOW2="hsla($H2,${SAT}%,${AL}%,.2)"
    BORDER="hsla(0,0%,100%,.1)"; BORDER_S="hsla(0,0%,100%,.22)"
    LINE="hsla(0,0%,100%,.045)"; LINE2="hsla(0,0%,100%,.12)"
    HDR="hsla($H,${BGS_}%,${BGL}%,.8)"
    SHADOW="0 10px 30px rgba(0,0,0,.35)"; SHADOW_C="rgba(0,0,0,.4)"
else
    rnd 95 98; BGL="$R"; rnd 20 45; BGS_="$R"; rnd 34 44; AL="$R"
    BG="hsl($H,${BGS_}%,${BGL}%)"; BG2="hsl($H,${BGS_}%,$((BGL - 5))%)"
    SURFACE="hsla(0,0%,100%,.85)"; GLASS="hsla(0,0%,100%,.6)"
    TEXT="hsl($H,30%,13%)"; MUTED="hsl($H,12%,38%)"
    ACCENT="hsl($H,${SAT}%,${AL}%)"; ACCENT2="hsl($H2,${SAT}%,${AL}%)"
    ON_ACC="#ffffff"; ON_HEX="#ffffff"
    GLOW="hsla($H,${SAT}%,${AL}%,.18)"; GLOW2="hsla($H2,${SAT}%,${AL}%,.16)"
    BORDER="hsla($H,30%,20%,.12)"; BORDER_S="hsla($H,30%,20%,.28)"
    LINE="hsla($H,30%,30%,.07)"; LINE2="hsla($H,30%,30%,.16)"
    HDR="hsla(0,0%,100%,.82)"
    SHADOW="0 10px 30px hsla($H,40%,20%,.12)"; SHADOW_C="hsla($H,40%,20%,.2)"
fi
THEME_HEX="$(hsl2hex "$H" "$BGS_" "$BGL")"
ACC_HEX="$(hsl2hex "$H" "$SAT" "$AL")"

RADII=(0px 4px 8px 12px 18px 24px);  pick RADII; RADIUS="$R"
BTN_RADII=(0px 6px 12px 999px);      pick BTN_RADII; BTN_RADIUS="$R"
MAXWS=(980 1040 1120 1200);          pick MAXWS; MAXW="$R"
SPACES=(72 88 104 120);              pick SPACES; SPACE="$R"
FSS=(16 17 18);                      pick FSS; FS="$R"
HWS=(400 500 600 700 800);           pick HWS; HW="$R"
HSPS=("-0.02em" "-0.01em" "0" "0.01em"); pick HSPS; HSP="$R"
chance 12
if [ "$R" -eq 1 ]; then HTR="uppercase"; HSP="0.06em"; else HTR="none"; fi

FONT_PAIRS=(
 "Georgia, 'Times New Roman', serif|-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"
 "'Palatino Linotype', Palatino, 'Book Antiqua', Georgia, serif|Georgia, 'Times New Roman', serif"
 "'Trebuchet MS', 'Lucida Grande', 'Segoe UI', sans-serif|'Segoe UI', Tahoma, Geneva, Verdana, sans-serif"
 "'Helvetica Neue', Helvetica, Arial, sans-serif|'Helvetica Neue', Helvetica, Arial, sans-serif"
 "Verdana, Geneva, sans-serif|Verdana, Geneva, sans-serif"
 "'Courier New', Courier, monospace|-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif"
 "'Gill Sans', 'Gill Sans MT', Calibri, 'Trebuchet MS', sans-serif|'Gill Sans', 'Gill Sans MT', Calibri, sans-serif"
 "ui-serif, Georgia, Cambria, serif|ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif"
)
while :; do
    pick FONT_PAIRS; FP="$R"
    case "$FP" in
        "'Courier New'"*) if [ "$T_KEY" != software ]; then continue; fi ;;
    esac
    break
done
FONT_H="${FP%%|*}"; FONT_B="${FP##*|}"

FX=""
chance 55; if [ "$R" -eq 1 ]; then FX+=" fx-lift"; fi
chance 50; if [ "$R" -eq 1 ]; then FX+=" fx-grad"; fi
chance 45; if [ "$R" -eq 1 ]; then FX+=" fx-glow"; fi
chance 60; if [ "$R" -eq 1 ]; then REV=" reveal"; else REV=""; fi
BODY_CLASS="l-${LAYOUT} bg-${BG_KIND} card-${CARD} svc-${SVC_STYLE}${FX}"

# ---------- логотип / favicon ----------
rnd 0 4; MARK_SHAPE="$R"
mark_svg() {    # $1 = заливка фигуры, $2 = цвет буквы  ->  MARK_INNER
    local shape
    case "$MARK_SHAPE" in
        0) shape="<circle cx=\"16\" cy=\"16\" r=\"16\" fill=\"$1\"/>" ;;
        1) shape="<rect width=\"32\" height=\"32\" rx=\"7\" fill=\"$1\"/>" ;;
        2) shape="<path d=\"M16 0 32 16 16 32 0 16Z\" fill=\"$1\"/>" ;;
        3) shape="<rect width=\"32\" height=\"32\" fill=\"$1\"/>" ;;
        4) shape="<path d=\"M8 2h16l8 14-8 14H8L0 16z\" fill=\"$1\"/>" ;;
    esac
    MARK_INNER="${shape}<text x=\"16\" y=\"21.5\" text-anchor=\"middle\" font-family=\"Georgia, serif\" font-size=\"16\" font-weight=\"700\" fill=\"$2\">${INITIAL}</text>"
}
mark_svg "var(--accent)" "var(--on-accent)"
MARK_HTML="<svg class=\"mark\" viewBox=\"0 0 32 32\" aria-hidden=\"true\">${MARK_INNER}</svg>"
mark_svg "$ACC_HEX" "$ON_HEX"
FAVICON_SVG="<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 32 32\">${MARK_INNER}</svg>"

# ---------- абстрактная иллюстрация для hero (layout b) ----------
make_art() {
    local n i t cx cy r op rot col x2 y2 o
    ART="<svg viewBox=\"0 0 400 400\" xmlns=\"http://www.w3.org/2000/svg\" role=\"presentation\">"
    rnd 6 9; n="$R"
    for (( i=0; i<n; i++ )); do
        rnd 0 3; t="$R"
        rnd 40 360; cx="$R"; rnd 40 360; cy="$R"; rnd 24 90; r="$R"; rnd 12 70; op="$R"
        if (( RANDOM % 2 )); then col="var(--accent)"; else col="var(--accent2)"; fi
        printf -v o '%02d' "$op"
        case "$t" in
            0) ART+="<circle cx=\"$cx\" cy=\"$cy\" r=\"$r\" fill=\"$col\" opacity=\"0.$o\"/>" ;;
            1) rnd 0 90; rot="$R"
               ART+="<rect x=\"$((cx - r))\" y=\"$((cy - r))\" width=\"$((r * 2))\" height=\"$((r * 2))\" rx=\"$((r / 4))\" fill=\"$col\" opacity=\"0.$o\" transform=\"rotate($rot $cx $cy)\"/>" ;;
            2) printf -v o '%02d' "$((op + 25))"
               ART+="<circle cx=\"$cx\" cy=\"$cy\" r=\"$r\" fill=\"none\" stroke=\"$col\" stroke-width=\"3\" opacity=\"0.$o\"/>" ;;
            3) x2=$(( cx - 120 + RANDOM % 241 )); y2=$(( cy - 120 + RANDOM % 241 ))
               printf -v o '%02d' "$((op + 25))"
               ART+="<line x1=\"$cx\" y1=\"$cy\" x2=\"$x2\" y2=\"$y2\" stroke=\"$col\" stroke-width=\"4\" stroke-linecap=\"round\" opacity=\"0.$o\"/>" ;;
        esac
    done
    ART+="</svg>"
}
HERO_ART_HTML=""
if [ "$LAYOUT" = "b" ]; then
    make_art
    HERO_ART_HTML="<div class=\"hero-art\" aria-hidden=\"true\">${ART}</div>"
fi

# ---------- порядок секций и навигация ----------
MID=(process quotes stats); shuffle MID
chance 50
if [ "$R" -eq 1 ]; then ORDER=(about services); else ORDER=(services about); fi
for s in "${MID[@]}"; do
    chance 65
    if [ "$R" -eq 1 ]; then ORDER+=("$s"); fi
done
if [ "${#ORDER[@]}" -eq 2 ]; then ORDER+=("${MID[0]}"); fi
ORDER+=(contact)

NAV_HTML=""
for s in "${ORDER[@]}"; do
    case "$s" in
        about)    NAV_HTML+="<a href=\"/#about\">About</a>"$'\n' ;;
        services) NAV_HTML+="<a href=\"/#services\">Services</a>"$'\n' ;;
        process)  NAV_HTML+="<a href=\"/#process\">Process</a>"$'\n' ;;
        quotes)   NAV_HTML+="<a href=\"/#clients\">Clients</a>"$'\n' ;;
        contact)  NAV_HTML+="<a href=\"/#contact\">Contact</a>"$'\n' ;;
    esac
done
NAV_HTML+="<a class=\"btn btn-sm\" href=\"/#contact\">${BTN_NAV}</a>"

# ---------- даты ----------
rnd 10 60; LASTMOD_AGO="$R"
LASTMOD="$(date -d "${LASTMOD_AGO} days ago" +%Y-%m-%d)"
case "$DATE_STYLE" in
    mdy) UPD_DATE="$(date -d "${LASTMOD_AGO} days ago" +"%B %-d, %Y")" ;;
    *)     UPD_DATE="$(date -d "${LASTMOD_AGO} days ago" +"%-d %B %Y")" ;;
esac
rnd 0 1
if [ "$R" -eq 0 ]; then FOOT_YEARS="${YEAR}–${CUR_YEAR}"; else FOOT_YEARS="${CUR_YEAR}"; fi
chance 40; if [ "$R" -eq 1 ]; then FOOT_EXTRA=" Registered in ${COUNTRY_THE}."; else FOOT_EXTRA=""; fi

# ---------- имена файлов ----------
ASSET_DIRS=(assets static res); pick ASSET_DIRS; ASSETS="$R"
CSS_NAMES=(style.css main.css site.css); pick CSS_NAMES; CSS_NAME="$R"
JS_NAMES=(main.js site.js app.js); pick JS_NAMES; JS_NAME="$R"

# ============================================================
#  ФУНКЦИИ РАЗМЕТКИ
# ============================================================
emit_head() {   # $1 title  $2 description  $3 path  $4 robots  $5 extra-head
    local og_tw=""
    if [ -n "$TW_TAG" ]; then
        og_tw="<meta name=\"twitter:card\" content=\"summary\">
<meta name=\"twitter:title\" content=\"$1\">
<meta name=\"twitter:description\" content=\"$2\">"
    fi
    local kw=""
    if [ "$3" = "/" ]; then kw="$KW_TAG"; fi
    cat <<HEAD
<!DOCTYPE html>
<html lang="${LANG_CODE}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$1</title>
<meta name="description" content="$2">
${kw}
<meta name="robots" content="$4">
<meta name="theme-color" content="${THEME_HEX}">
<link rel="canonical" href="https://${DOMAIN}$3">
<meta property="og:type" content="website">
<meta property="og:site_name" content="${COMPANY_H}">
<meta property="og:title" content="$1">
<meta property="og:description" content="$2">
<meta property="og:url" content="https://${DOMAIN}$3">
<meta property="og:locale" content="${OG_LOCALE}">
${og_tw}
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="stylesheet" href="/${ASSETS}/${CSS_NAME}">
<script src="/${ASSETS}/${JS_NAME}"></script>
$5
</head>
HEAD
}

emit_header() {
    cat <<HDR
<body class="${BODY_CLASS}">
<a class="skip" href="#main">Skip to content</a>
<header class="site-header">
<div class="wrap bar">
<a class="brand" href="/">${MARK_HTML}<span>${COMPANY_H}</span></a>
<button class="nav-toggle" type="button" aria-label="Menu" aria-expanded="false"><span></span></button>
<nav class="nav" aria-label="Main">
${NAV_HTML}
</nav>
</div>
</header>
<main id="main">
HDR
}

emit_footer() {
    cat <<FTR
</main>
<footer class="site-footer">
<div class="wrap foot">
<span>&copy; ${FOOT_YEARS} ${COMPANY_H} ${LEGAL}${LEGAL_DOT} All rights reserved.${FOOT_EXTRA}</span>
<span><a href="/privacy.html">Privacy policy</a></span>
</div>
</footer>
</body>
</html>
FTR
}

sec_hero() {
    cat <<SEC
<section class="hero">
<div class="wrap hero-grid">
<div class="hero-copy">
<span class="eyebrow">${EYEBROW}</span>
<h1>${HERO_HEAD} <span class="g">${HERO_LAST}</span></h1>
<p class="lead">${LEAD}</p>
<div class="actions">
<a class="btn" href="/#contact">${BTN_HERO1}</a>
<a class="btn btn-ghost" href="/#services">${BTN_HERO2}</a>
</div>
</div>
${HERO_ART_HTML}
</div>
</section>
SEC
}

sec_about() {
    local v li=""
    for v in "${VS[@]}"; do
        li+="<li><strong>${v%%|*}</strong><span>${v##*|}</span></li>"$'\n'
    done
    cat <<SEC
<section id="about" class="section${REV}">
<div class="wrap">
<div class="section-head"><h2>${HT_ABOUT}</h2></div>
<div class="about-grid">
<div class="about-text">
<p>${T_ABOUT[0]}</p>
<p>${T_ABOUT[1]}</p>
<p>${ABOUT3}</p>
</div>
<ul class="values">
${li}</ul>
</div>
</div>
</section>
SEC
}

sec_services() {
    local i=0 s cards=""
    for s in "${SV[@]}"; do
        i=$((i + 1))
        cards+="<article class=\"card\"><span class=\"num\">$(printf '%02d' "$i")</span><h3>${s%%|*}</h3><p>${s##*|}</p></article>"$'\n'
    done
    cat <<SEC
<section id="services" class="section${REV}">
<div class="wrap">
<div class="section-head"><h2>${HT_SVC}</h2><p class="sub">${ST_SVC}</p></div>
<div class="cards">
${cards}</div>
</div>
</section>
SEC
}

sec_stats() {
    local a b lab1 min1 max1 lab2 min2 max2 n1 n2 plus="" yl
    IFS='|' read -r lab1 min1 max1 <<< "${T_STATS[0]}"
    IFS='|' read -r lab2 min2 max2 <<< "${T_STATS[1]}"
    rnd "$min1" "$max1"; n1="$R"
    rnd "$min2" "$max2"; n2="$R"
    chance 60; if [ "$R" -eq 1 ]; then plus="+"; fi
    rnd 0 1; if [ "$R" -eq 0 ]; then yl="Years in business"; else yl="Years of experience"; fi
    cat <<SEC
<section class="section band${REV}">
<div class="wrap">
<div class="stats">
<div class="stat"><b>$((CUR_YEAR - YEAR))${plus}</b><span>${yl}</span></div>
<div class="stat"><b>${n1}${plus}</b><span>${lab1}</span></div>
<div class="stat"><b>${n2}${plus}</b><span>${lab2}</span></div>
</div>
</div>
</section>
SEC
}

sec_process() {
    local p items=""
    for p in "${T_PROC[@]}"; do
        items+="<li class=\"step\"><h3>${p%%|*}</h3><p>${p##*|}</p></li>"$'\n'
    done
    cat <<SEC
<section id="process" class="section${REV}">
<div class="wrap">
<div class="section-head"><h2>${HT_PROC}</h2><p class="sub">${ST_PROC}</p></div>
<ol class="steps">
${items}</ol>
</div>
</section>
SEC
}

sec_quotes() {
    local QS=("${T_QUOTES[@]}") q out="" f l o r n
    shuffle QS
    n=3; chance 40; if [ "$R" -eq 1 ]; then n=2; fi
    QS=("${QS[@]:0:n}")
    for q in "${QS[@]}"; do
        pick FIRST; f="$R"; gen_surname; l="$R"; gen_org; o="$R"; pick ROLES; r="$R"
        out+="<blockquote><p>${q}</p><cite><b>${f} ${l}</b>, ${r}, ${o}</cite></blockquote>"$'\n'
    done
    cat <<SEC
<section id="clients" class="section${REV}">
<div class="wrap">
<div class="section-head"><h2>${HT_QUOTES}</h2><p class="sub">${ST_QUOTES}</p></div>
<div class="quotes">
${out}</div>
</div>
</section>
SEC
}

sec_contact() {
    cat <<SEC
<section id="contact" class="section${REV}">
<div class="wrap">
<div class="section-head"><h2>${HT_CONTACT}</h2><p class="sub">${ST_CONTACT}</p></div>
<div class="contact-grid">
<div><h3>Visit</h3><p>${ADDR1}<br>${ADDR2}<br>${COUNTRY}</p></div>
<div><h3>Call</h3><p><a href="tel:${PHONE// /}">${PHONE}</a></p></div>
<div><h3>Write</h3><p><a href="mailto:${EMAIL}">${EMAIL}</a></p></div>
<div><h3>Hours</h3><p>${OPEN_HOURS}</p></div>
</div>
</div>
</section>
SEC
}

# ============================================================
#  ЗАПИСЬ ФАЙЛОВ
# ============================================================
# Не очищаем WEBROOT целиком: существующие пользовательские файлы сохраняются.
mkdir -p "${WEBROOT}/${ASSETS}"

# ---------- index.html ----------
{
    emit_head "$TITLE_H" "$META_DESC_H" "/" "index, follow, max-image-preview:large" "$JSONLD"
    emit_header
    sec_hero
    for s in "${ORDER[@]}"; do "sec_$s"; done
    emit_footer
} > "${WEBROOT}/index.html"

# ---------- privacy.html ----------
{
    emit_head "Privacy policy | ${COMPANY_H}" "How ${COMPANY_H} handles personal information collected through this website." "/privacy.html" "index, follow" ""
    emit_header
    cat <<PRIV
<article class="prose">
<h1>Privacy policy</h1>
<p>Last updated: ${UPD_DATE}</p>
<h2>Who we are</h2>
<p>${COMPANY_H} ${LEGAL} (&ldquo;we&rdquo;, &ldquo;us&rdquo;) is based in ${CITY}, ${COUNTRY}. This policy explains how we handle personal information when you visit this website or contact us.</p>
<h2>Information we collect</h2>
<p>If you contact us by email or telephone, we keep the details you provide, such as your name, contact information and the content of your message, so that we can respond. Our web server also records standard technical information, including IP address, browser type and the pages requested, for security and troubleshooting.</p>
<h2>How we use it</h2>
<p>We use this information to answer questions, provide our services, keep this site secure and meet legal obligations. We do not sell personal information and we do not use it for automated decision-making.</p>
<h2>Cookies</h2>
<p>This website does not use advertising or tracking cookies. Any cookies that are set are strictly necessary for the site to work.</p>
<h2>Retention</h2>
<p>Server logs are kept for up to ninety days. Correspondence is kept for as long as it is needed to deal with your request and any follow-up, and for the period required by law.</p>
<h2>Your rights</h2>
<p>Depending on where you live, you may have the right to access, correct or delete the personal information we hold about you, or to object to how we use it. To exercise these rights, please contact us using the details below.</p>
<h2>Contact</h2>
<p>Email <a href="mailto:${EMAIL}">${EMAIL}</a> or write to us at ${ADDR1}, ${ADDR2}, ${COUNTRY}.</p>
</article>
PRIV
    emit_footer
} > "${WEBROOT}/privacy.html"

# ---------- 404.html ----------
{
    emit_head "Page not found | ${COMPANY_H}" "The page you are looking for could not be found." "/404.html" "noindex" ""
    emit_header
    cat <<ERR
<section class="err">
<p class="code">404</p>
<h1>Page not found</h1>
<p class="sub">The page you are looking for may have been moved or no longer exists.</p>
<p><a class="btn" href="/">Back to the home page</a></p>
</section>
ERR
    emit_footer
} > "${WEBROOT}/404.html"

# ---------- favicon ----------
echo "$FAVICON_SVG" > "${WEBROOT}/favicon.svg"

# ---------- robots.txt / sitemap.xml ----------
chance 50
if [ "$R" -eq 1 ]; then ROBOTS_RULE="Allow: /"; else ROBOTS_RULE="Disallow:"; fi
cat > "${WEBROOT}/robots.txt" <<ROBOTS
User-agent: *
${ROBOTS_RULE}

Sitemap: https://${DOMAIN}/sitemap.xml
ROBOTS

CHANGEFREQS=(monthly yearly); pick CHANGEFREQS; CF="$R"
cat > "${WEBROOT}/sitemap.xml" <<SITEMAP
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>https://${DOMAIN}/</loc>
    <lastmod>${LASTMOD}</lastmod>
    <changefreq>${CF}</changefreq>
    <priority>1.0</priority>
  </url>
  <url>
    <loc>https://${DOMAIN}/privacy.html</loc>
    <lastmod>${LASTMOD}</lastmod>
    <changefreq>yearly</changefreq>
    <priority>0.3</priority>
  </url>
</urlset>
SITEMAP

# ---------- CSS ----------
{
cat <<ROOT
/* ${COMPANY_H} — main stylesheet */
:root{
color-scheme:${MODE};
--bg:${BG};--bg2:${BG2};--surface:${SURFACE};--glass:${GLASS};--text:${TEXT};--muted:${MUTED};
--accent:${ACCENT};--accent2:${ACCENT2};--on-accent:${ON_ACC};--glow:${GLOW};--glow2:${GLOW2};
--border:${BORDER};--border-strong:${BORDER_S};--line:${LINE};--line2:${LINE2};--hdr:${HDR};
--shadow:${SHADOW};--shadow-c:${SHADOW_C};
--radius:${RADIUS};--btn-radius:${BTN_RADIUS};--maxw:${MAXW}px;--space:${SPACE}px;--fs:${FS}px;
--font-h:${FONT_H};--font-b:${FONT_B};
--h-weight:${HW};--h-spacing:${HSP};--h-transform:${HTR};
}
ROOT
cat <<'CSS'
*,*::before,*::after{box-sizing:border-box}
html{scroll-behavior:smooth;scroll-padding-top:84px;-webkit-text-size-adjust:100%}
body{margin:0;font-family:var(--font-b);font-size:var(--fs);line-height:1.65;color:var(--text);background:var(--bg);min-height:100vh;position:relative;overflow-x:hidden}
img,svg{max-width:100%}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
h1,h2,h3{font-family:var(--font-h);font-weight:var(--h-weight);letter-spacing:var(--h-spacing);line-height:1.15;margin:0 0 .5em}
h2,h3{text-transform:var(--h-transform)}
h1{font-size:clamp(2.2rem,5vw,3.8rem)}
h2{font-size:clamp(1.6rem,3vw,2.2rem)}
h3{font-size:1.15rem}
p{margin:0 0 1em}
.wrap{width:100%;max-width:var(--maxw);margin:0 auto;padding:0 24px}
.skip{position:absolute;left:-999px;top:0}
.skip:focus{left:12px;top:12px;background:var(--accent);color:var(--on-accent);padding:8px 12px;z-index:100}

/* background layer */
body::before{content:"";position:fixed;inset:0;z-index:-1;pointer-events:none}
.bg-grad::before{background:linear-gradient(135deg,var(--bg),var(--bg2))}
.bg-mesh::before{background:radial-gradient(circle at 15% 10%,var(--glow),transparent 45%),radial-gradient(circle at 85% 30%,var(--glow2),transparent 40%),radial-gradient(circle at 40% 95%,var(--glow),transparent 45%),var(--bg)}
.bg-grid::before{background-color:var(--bg);background-image:linear-gradient(var(--line) 1px,transparent 1px),linear-gradient(90deg,var(--line) 1px,transparent 1px);background-size:44px 44px}
.bg-dots::before{background-color:var(--bg);background-image:radial-gradient(var(--line2) 1.2px,transparent 1.2px);background-size:22px 22px}
.bg-noise::before{background-color:var(--bg);background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.8' numOctaves='2' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='.07'/%3E%3C/svg%3E")}
.bg-stripes::before{background:repeating-linear-gradient(135deg,transparent 0 22px,var(--line) 22px 23px),linear-gradient(var(--bg),var(--bg2))}
.bg-solid::before{background:var(--bg)}
.bg-anim::before{background:linear-gradient(120deg,var(--bg),var(--bg2),var(--glow),var(--bg));background-size:300% 300%;animation:drift 24s ease infinite}
@keyframes drift{0%{background-position:0 50%}50%{background-position:100% 50%}100%{background-position:0 50%}}

/* header */
.site-header{position:sticky;top:0;z-index:20;background:var(--hdr);-webkit-backdrop-filter:blur(10px);backdrop-filter:blur(10px);border-bottom:1px solid var(--border)}
.bar{display:flex;align-items:center;justify-content:space-between;gap:20px;min-height:68px}
.brand{display:flex;align-items:center;gap:10px;color:var(--text);font-family:var(--font-h);font-weight:700;font-size:1.15rem}
.brand:hover{text-decoration:none}
.mark{width:32px;height:32px;flex:none}
.nav{display:flex;align-items:center;gap:26px}
.nav a{color:var(--text);font-size:.95rem;opacity:.85}
.nav a:hover{opacity:1;text-decoration:none;color:var(--accent)}
.nav .btn{opacity:1;color:var(--on-accent)}
.nav .btn:hover{color:var(--on-accent)}
.nav-toggle{display:none;background:none;border:1px solid var(--border);border-radius:8px;width:42px;height:38px;cursor:pointer;color:var(--text)}
.nav-toggle span,.nav-toggle span::before,.nav-toggle span::after{display:block;width:18px;height:2px;background:currentColor;margin:0 auto;position:relative;content:""}
.nav-toggle span::before{position:absolute;top:-6px;left:0}
.nav-toggle span::after{position:absolute;top:6px;left:0}

/* buttons */
.btn{display:inline-block;padding:.75em 1.5em;border-radius:var(--btn-radius);background:var(--accent);color:var(--on-accent);font-weight:600;font-size:.95rem;border:2px solid var(--accent);transition:transform .2s,box-shadow .2s,border-color .2s,color .2s}
.btn:hover{text-decoration:none;transform:translateY(-2px);box-shadow:0 8px 20px var(--glow)}
.btn-ghost{background:transparent;color:var(--text);border-color:var(--border-strong)}
.btn-ghost:hover{border-color:var(--accent);color:var(--accent);box-shadow:none}
.btn-sm{padding:.5em 1.1em;font-size:.88rem}

/* hero */
.hero{padding:calc(var(--space) * 1.1) 0 var(--space);position:relative}
.hero-grid{display:grid;gap:48px;align-items:center}
.eyebrow{display:inline-block;font-size:.8rem;letter-spacing:.14em;text-transform:uppercase;color:var(--accent);margin-bottom:18px;font-weight:600}
.lead{font-size:1.2rem;color:var(--muted);max-width:620px}
.actions{display:flex;flex-wrap:wrap;gap:14px;margin-top:28px}
.hero-art{display:none}
.hero-art svg{width:100%;height:auto;max-width:420px;margin:0 auto;display:block}
.fx-grad h1 .g{background:linear-gradient(90deg,var(--accent),var(--accent2));-webkit-background-clip:text;background-clip:text;color:transparent}
.fx-glow .hero::before{content:"";position:absolute;width:420px;height:420px;border-radius:50%;background:var(--glow);filter:blur(90px);top:-60px;right:8%;z-index:-1;animation:float 14s ease-in-out infinite}
@keyframes float{50%{transform:translate(-40px,50px)}}

/* layout variants */
.l-a .hero{text-align:center}
.l-a .lead{margin-left:auto;margin-right:auto}
.l-a .actions{justify-content:center}
.l-a .section-head{margin-left:auto;margin-right:auto;text-align:center}
.l-b .hero-grid{grid-template-columns:1.2fr .8fr}
.l-b .hero-art{display:block}
.l-c .bar{flex-direction:column;padding-top:18px;padding-bottom:12px;gap:12px}
.l-c .brand{font-size:1.5rem}
.l-c .hero h1{font-size:clamp(2.4rem,6vw,4.6rem);border-top:3px solid var(--accent);padding-top:24px}
.l-d h1{font-size:clamp(2rem,4vw,3.2rem)}
@media(min-width:900px){
.l-d{display:grid;grid-template-columns:270px minmax(0,1fr);grid-template-rows:1fr auto}
.l-d .site-header{grid-column:1;grid-row:1/3;position:sticky;top:0;height:100vh;align-self:start;border-bottom:0;border-right:1px solid var(--border)}
.l-d .bar{flex-direction:column;align-items:flex-start;justify-content:flex-start;padding-top:36px;gap:40px;min-height:0}
.l-d .nav{flex-direction:column;align-items:flex-start;gap:14px}
.l-d main{grid-column:2;grid-row:1}
.l-d .site-footer{grid-column:2;grid-row:2}
}

/* sections */
.section{padding:var(--space) 0}
.section-head{max-width:640px;margin-bottom:40px}
.sub{color:var(--muted)}
.about-grid{display:grid;gap:48px;grid-template-columns:1.4fr 1fr}
.about-text p{color:var(--muted)}
.values{list-style:none;margin:0;padding:0;display:grid;gap:18px;align-content:start}
.values li{padding-left:18px;border-left:2px solid var(--accent)}
.values strong{display:block;font-family:var(--font-h)}
.values span{color:var(--muted);font-size:.95rem}
.band{background:var(--surface);border-top:1px solid var(--border);border-bottom:1px solid var(--border);padding:calc(var(--space) * .6) 0}

/* cards */
.cards{display:grid;gap:22px;grid-template-columns:repeat(auto-fit,minmax(250px,1fr))}
.card{padding:28px;border-radius:var(--radius);background:var(--surface);border:1px solid var(--border);transition:transform .25s,box-shadow .25s,border-color .25s}
.card h3{margin-bottom:.4em}
.card p{margin:0;color:var(--muted);font-size:.97rem}
.num{display:block;font-family:var(--font-h);color:var(--accent);font-size:.85rem;letter-spacing:.1em;margin-bottom:14px}
.card-flat .card{border-color:transparent}
.card-outline .card{background:transparent;border-color:var(--border-strong)}
.card-shadow .card{border-color:transparent;box-shadow:var(--shadow)}
.card-glass .card{background:var(--glass);-webkit-backdrop-filter:blur(12px);backdrop-filter:blur(12px)}
.card-accent .card{border:0;border-left:4px solid var(--accent);border-radius:calc(var(--radius) / 2)}
.fx-lift .card:hover{transform:translateY(-6px);box-shadow:0 16px 36px var(--shadow-c)}
.svc-list .cards{grid-template-columns:1fr;gap:14px}
.svc-list .card{display:grid;grid-template-columns:60px 1fr 1.5fr;gap:20px;align-items:baseline}
.svc-list .card h3,.svc-list .card p,.svc-list .num{margin:0}
.svc-cols .cards{grid-template-columns:repeat(2,1fr)}

/* stats / steps / quotes / contact */
.stats{display:grid;gap:24px;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));text-align:center}
.stat b{display:block;font-family:var(--font-h);font-size:clamp(2rem,4vw,3rem);color:var(--accent);line-height:1.1}
.stat span{color:var(--muted);font-size:.92rem}
.steps{list-style:none;margin:0;padding:0;display:grid;gap:28px;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));counter-reset:s}
.step{position:relative;padding-top:52px;counter-increment:s}
.step::before{content:counter(s,decimal-leading-zero);position:absolute;top:0;left:0;font-family:var(--font-h);font-size:1.6rem;color:var(--accent);line-height:1}
.step::after{content:"";position:absolute;top:14px;left:52px;right:0;height:1px;background:var(--border-strong)}
.step p{color:var(--muted);font-size:.97rem}
.quotes{display:grid;gap:22px;grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}
blockquote{margin:0;padding:28px;border-radius:var(--radius);background:var(--surface);border:1px solid var(--border)}
blockquote p{font-size:1.02rem;font-style:italic}
blockquote p::before{content:"\201C"}
blockquote p::after{content:"\201D"}
cite{display:block;font-style:normal;font-size:.9rem;color:var(--muted)}
cite b{color:var(--text)}
.contact-grid{display:grid;gap:26px;grid-template-columns:repeat(auto-fit,minmax(200px,1fr))}
.contact-grid h3{font-size:.8rem;text-transform:uppercase;letter-spacing:.12em;color:var(--accent);margin-bottom:.5em}
.contact-grid p{margin:0}

/* footer, text pages */
.site-footer{border-top:1px solid var(--border);padding:34px 0;color:var(--muted);font-size:.9rem}
.foot{display:flex;flex-wrap:wrap;gap:12px 28px;justify-content:space-between}
.foot a{color:var(--muted)}
.foot a:hover{color:var(--accent)}
.prose{max-width:760px;margin:0 auto;padding:64px 24px}
.prose h1{font-size:2.2rem}
.prose h2{font-size:1.2rem;margin-top:1.8em}
.prose p{color:var(--muted)}
.err{text-align:center;padding:110px 24px}
.err .code{font-family:var(--font-h);font-size:clamp(5rem,16vw,9rem);color:var(--accent);line-height:1;margin:0}

/* reveal */
.js .reveal{opacity:0;transform:translateY(22px);transition:opacity .7s ease,transform .7s ease}
.js .reveal.in{opacity:1;transform:none}
@media(prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}.js .reveal{opacity:1;transform:none}}

/* mobile */
@media(max-width:899px){
.nav-toggle{display:block}
.nav{display:none;position:absolute;top:100%;left:0;right:0;flex-direction:column;align-items:flex-start;gap:14px;padding:20px 24px;background:var(--bg);border-bottom:1px solid var(--border)}
.nav.open{display:flex}
.l-b .hero-grid,.about-grid{grid-template-columns:1fr}
.l-c .bar{flex-direction:row;padding-top:0;padding-bottom:0}
.l-c .brand{font-size:1.15rem}
.svc-list .card{grid-template-columns:1fr;gap:6px}
.svc-cols .cards{grid-template-columns:1fr}
.hero{padding-top:var(--space)}
}
CSS
} > "${WEBROOT}/${ASSETS}/${CSS_NAME}"

# ---------- JS ----------
cat > "${WEBROOT}/${ASSETS}/${JS_NAME}" <<'JS'
(function () {
  var d = document;
  d.documentElement.classList.add('js');
  d.addEventListener('DOMContentLoaded', function () {
    var t = d.querySelector('.nav-toggle'), n = d.querySelector('.nav');
    if (t && n) {
      t.addEventListener('click', function () {
        var o = n.classList.toggle('open');
        t.setAttribute('aria-expanded', o ? 'true' : 'false');
      });
      n.addEventListener('click', function (e) {
        if (e.target.tagName === 'A') {
          n.classList.remove('open');
          t.setAttribute('aria-expanded', 'false');
        }
      });
    }
    var els = d.querySelectorAll('.reveal');
    if ('IntersectionObserver' in window) {
      var io = new IntersectionObserver(function (es) {
        es.forEach(function (e) {
          if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
        });
      }, { threshold: 0.12 });
      els.forEach(function (el) { io.observe(el); });
    } else {
      els.forEach(function (el) { el.classList.add('in'); });
    }
  });
})();
JS

# ---------- «возраст» файлов: правдоподобные даты изменения ----------
# Не меняем timestamps и права уже существовавших файлов в каталоге сайта.
# Новые файлы создаются с системной umask пользователя root.

echo "  -> Сид:        ${SEED}   (повтор: HONEYPOT_SEED=${SEED} ./honeypot-generator.sh ${DOMAIN})"
echo "  -> Компания:   ${COMPANY} (${T_INDUSTRY}, ${CITY})"
echo "  -> Дизайн:     layout=${LAYOUT}, фон=${BG_KIND}, карточки=${CARD}, услуги=${SVC_STYLE}, тема=${MODE}, hue=${H}${FX}"
echo "  -> Файлы:      ${WEBROOT} (index, privacy, 404, robots, sitemap, favicon, ${ASSETS}/)"

if [ "$DRY_RUN" = "1" ]; then
    paint "$C_GREEN" "✓ Генерация завершена. Режим dry-run: nginx и сертификат не затрагивались."
    exit 0
fi

# ------------------------------------------------------------
# nginx: сначала HTTP-конфиг для получения сертификата
# ------------------------------------------------------------
step "4/6  Настройка nginx (HTTP для ACME)"

cat > "${NGINX_AVAILABLE}/${DOMAIN}.conf" <<NGINXHTTP
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WEBROOT};
    index index.html;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINXHTTP

ln -sf "${NGINX_AVAILABLE}/${DOMAIN}.conf" "${NGINX_ENABLED}/${DOMAIN}.conf"

if ! nginx -t; then
    paint "$C_RED" "✖ Проверка nginx не прошла. Перезагрузка не выполнялась."
    exit 1
fi
if ! systemctl reload nginx; then
    paint "$C_RED" "✖ Не удалось перезагрузить nginx. Проверьте systemctl status nginx."
    exit 1
fi
echo "  ✓ HTTP-конфиг применён; конфиги других сайтов не переписывались."

# ------------------------------------------------------------
# Получение сертификата Let's Encrypt
# ------------------------------------------------------------
step "5/6  Получение сертификата Let's Encrypt"

CERT_EMAIL="admin@${DOMAIN}"
if ! certbot certonly --webroot -w /var/www/certbot \
    -d "${DOMAIN}" \
    --non-interactive --agree-tos -m "${CERT_EMAIL}"; then
    exit 1
fi

if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    exit 1
fi

echo "  -> Сертификат получен: /etc/letsencrypt/live/${DOMAIN}/"

# ------------------------------------------------------------
# Обновление nginx-конфига под HTTPS
# (синтаксис http2 зависит от версии nginx)
# ------------------------------------------------------------
step "6/6  Включение HTTPS и автообновления сертификата"

NGINX_VER="$(nginx -v 2>&1 | sed 's/.*nginx\///; s/[^0-9.].*//')"
if [ "$(printf '%s\n1.25.1\n' "$NGINX_VER" | sort -V | head -n1)" = "1.25.1" ]; then
    LISTEN_SSL="listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;"
else
    LISTEN_SSL="listen 443 ssl http2;
    listen [::]:443 ssl http2;"
fi

cat > "${NGINX_AVAILABLE}/${DOMAIN}.conf" <<NGINXHTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    ${LISTEN_SSL}
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    server_tokens off;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    charset utf-8;
    gzip on;
    gzip_types text/css application/javascript image/svg+xml application/xml text/plain;

    root ${WEBROOT};
    index index.html;

    error_page 404 /404.html;
    location = /404.html { internal; }

    location ~* \.(css|js|svg)\$ {
        expires 30d;
        try_files \$uri =404;
    }

    location ~ /\.(?!well-known) {
        return 404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINXHTTPS

nginx -t
systemctl reload nginx

echo "  -> HTTPS включён"

# ------------------------------------------------------------
# Скрипт автообновления сертификата
# ------------------------------------------------------------
RENEW_SCRIPT="/usr/local/bin/renew-${DOMAIN}.sh"
cat > "${RENEW_SCRIPT}" <<RENEW
#!/bin/bash
certbot renew --webroot -w /var/www/certbot --quiet --deploy-hook "systemctl reload nginx"
RENEW
chmod +x "${RENEW_SCRIPT}"

CRON_LINE="0 3 * * * ${RENEW_SCRIPT} >> /var/log/renew-${DOMAIN}.log 2>&1"
( crontab -l 2>/dev/null | grep -v "${RENEW_SCRIPT}" ; echo "${CRON_LINE}" ) | crontab -

echo "  -> Автообновление сертификата настроено (cron, 03:00 ежедневно)"
echo "  -> Скрипт обновления: ${RENEW_SCRIPT}"

# ------------------------------------------------------------
# Итог
# ------------------------------------------------------------
echo
line
paint "$C_GREEN$C_BOLD" "✓ ГОТОВО"
line
echo " Домен:        https://${DOMAIN}/"
echo " Компания:     ${COMPANY}"
echo " Сид:          ${SEED}"
echo " Файлы сайта:  ${WEBROOT}"
echo " nginx конфиг: ${NGINX_AVAILABLE}/${DOMAIN}.conf"
echo " Сертификат:   /etc/letsencrypt/live/${DOMAIN}/"
echo " Автообновление серта: ${RENEW_SCRIPT} (cron, ежедневно 03:00)"
echo "================================================"
__HONEYPOT_GENERATOR_SOURCE_20261027__
  {
    cat <<'HONEYPOT_WRAPPER'
#!/usr/bin/env bash
set -e
DOMAIN="${1:?domain required}"
export HONEYPOT_DRYRUN=1
export HONEYPOT_WEBROOT="/var/www/honeypot/${DOMAIN}"
HONEYPOT_WRAPPER
    cat "$D/honeypot-generator.source.sh"
  } > "$D/honeypot.sh"

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
    "# окно приёма HTTP/2 на поток (по умолчанию 64k): скорость одного потока ≈ окно / RTT: при 60 мс 64k даёт около 1 МБ/с, 4m около 65 МБ/с (замер на стенде)\n"
    "http2_body_preread_size 4m;\n"
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
        xh["xmux"] = {"maxConnections": 2, "hMaxRequestTimes": "600-900", "hMaxReusableSecs": "1800-3000", "hKeepAlivePeriod": 20}
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
  echo
  rule
  printf '  %sPanel Installation Complete!%s\n' "$GRN" "$R"
  rule
  printf '%sUsername:    %s%s\n' "$GRN" "$xu" "$R"
  printf '%sPassword:    %s%s\n' "$GRN" "$xp" "$R"
  printf '%sPort:        %s%s\n' "$GRN" "$PANEL_PORT" "$R"
  printf '%sWebBasePath: %s%s\n' "$GRN" "$xw" "$R"
  printf '%sDatabase:    SQLite (/etc/x-ui/x-ui.db)%s\n' "$GRN" "$R"
  printf '%sAccess URL:  http://127.0.0.1:%s/%s%s\n' "$GRN" "$PANEL_PORT" "$xw" "$R"
  printf '%sAPI Token:   %s%s\n' "$GRN" "${xt:-—}" "$R"
  rule
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
  kv "Channel" "клиент → https://$DOMAIN:443 (VLESS + XHTTP, HTTP/2) → RELAY ⇄ обратный туннель ⇄ BACKEND → интернет"
  kv "Honeypot" "https://$DOMAIN/ — сайт на RELAY + 2–5 служебных эндпоинтов (случайный набор при установке); чужие пути — 404"
  kv "Subscription" "название в клиентах: $SUB_TITLE; инбаунды панели: VPN (пользователи), TUNNEL (служебный)"
  if [ $HIDE_PANEL -eq 1 ]; then
    kv "3x-ui panel" "скрыта из сети: только через SSH-туннель → RELAY 127.0.0.1:$PANEL_PORT; подписка для Incy доступна на https://$DOMAIN"
  else
    kv "3x-ui panel" "https://$DOMAIN/<WebBasePath> → RELAY 127.0.0.1:$PANEL_PORT; подписка для Incy там же"
  fi
  kv "Tunnel" "BACKEND → RELAY:443, TLS 1.3, отпечаток Chrome, padding 100-1000 Б; секретный путь принимает только IP BACKEND; версия Xray моста — вручную (chain-update-bridge)"
  kv "E-mail" "$EMAIL"
  kv "BACKEND ports" "все входящие закрываются, остаётся только SSH"
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
  step_run "Генерация файлов Honeypot на RELAY" lscript "$TMPD/honeypot.sh" "$DOMAIN" || die "не удалось сгенерировать Honeypot"
  if test -s "/var/www/honeypot/$DOMAIN/index.html"; then ok "Главная страница создана: /var/www/honeypot/$DOMAIN/index.html"; else die "Honeypot не создал index.html"; fi

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
  /usr/local/bin/sync-sub-path >>"$LOG" 2>&1 || true
  step_run "3x-ui: журнал доступа и DNS-журнал Xray отключены" python3 "$TMPD/relay-harden.py" || warn "журналы Xray не отключены (см. лог)"
  step_run "Перезапуск 3x-ui (применение маршрутизации)" bash -c 'systemctl restart x-ui && sleep 4 && systemctl is-active --quiet x-ui' || warn "x-ui не перезапустился"
  step_run "chain-health, автотест после перезагрузки, проверка сертификата, счётчик соединений" lscript "$TMPD/health-relay.sh" "$VER_PATH" || warn "chain-health установлен не полностью (см. лог)"
  install -m 755 "$TMPD/failclosed.py" /usr/local/bin/chain-failclosed

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
  printf '  URL:       %shttps://%s/%s\n' "$B" "$DOMAIN" "$R"
  printf '  Каталог:   %s/var/www/honeypot/%s%s (RELAY)\n' "$DIM" "$DOMAIN" "$R"
  if [ "$site_code" = "200" ]; then ok "Проверка сайта: HTTP 200"; else warn "Проверка сайта вернула HTTP ${site_code:-000}; проверьте DNS, nginx и лог"; fi
  echo
  printf '  %sПАНЕЛЬ 3X-UI%s\n' "$B" "$R"
  if [ "$HIDE_PANEL" -eq 1 ]; then printf '  URL:       %s%s%s\n' "$B" "$tun_url" "$R"; else printf '  URL:       %s%s%s\n' "$B" "$panel_url" "$R"; fi
  printf '  Username:  %s%s%s\n' "$GRN" "$xu" "$R"
  printf '  Password:  %s%s%s\n' "$GRN" "$xp" "$R"
  echo
  printf '  %sКЛИЕНТ (Incy)%s\n' "$B" "$R"
  printf '  Подписка:  %shttps://%s%s%s%s\n' "$B" "$DOMAIN" "${SUB_PATHS:-/}" "$CHAIN_SUB_ID" "$R"
  [ -n "$link" ] && printf '  Ссылка:    %s%s%s\n' "$DIM" "$link" "$R"
  echo
  printf '  %sТУННЕЛЬ%s\n' "$B" "$R"
  if [ "$(tunnel_conns)" -ge 1 ]; then ok "BACKEND → RELAY: мост подключён"; else warn "мост не подключён"; fi
  rule
  echo "  ${DIM}Отчёт: $REPORT_FILE (права 600)${R}"
  echo "  ${DIM}Лог:   $LOG${R}"
  echo
  echo "  ${B}Служебные команды${R}"
  echo "   RELAY (этот сервер):"
  echo "     chain-status                 состояние цепочки: nginx, 3x-ui, подключён ли мост, сертификат, проба сайта"
  echo "     chain-test                   сквозная проверка: клиент → туннель → BACKEND → интернет (показывает выходной IP)"
  echo "     chain-set-backend IP|any     сменить IP BACKEND, которому разрешён туннельный путь (any — без ограничения)"
  echo "     chain-site-refresh           обновить страницы «живого» сайта (то же делает таймер раз в 5 минут)"
  echo "     sync-sub-path                прописать пути подписки из 3x-ui в nginx (таймер; вручную — после смены путей в панели)"
  echo "     chain-xray-version           записать версию Xray релея (срабатывает сама при обновлении ядра панели)"
  echo "     chain-health --show          состояние цепочки: мост, сквозная проверка, нагрузка, последние сбои (обновляется раз в 30 с)"
  echo "     chain-incident --show [N]    журнал сбоев /var/log/chain-incidents.log: что упало и почему"
  echo "     chain-failclosed             проверка: без моста RELAY не выпускает трафик пользователей в интернет"
  echo "     chain-certcheck              срок сертификата и пробное продление (то же делает таймер раз в неделю)"
  echo "   BACKEND:"
  echo "     chain-set-relay IP           указать новый IP RELAY (если мост не подключится за 40 с, прежний адрес вернётся)"
  echo "     chain-update-bridge [ВЕРСИЯ|--rollback|--status]   Xray моста: к версии RELAY или к указанной (прежняя сохраняется, при неудаче откат), --rollback — вернуть прежнюю"
  echo "     chain-watchdog --status      состояние сторожа и перезапуски моста (локальные проверки раз в минуту)"
  echo "     chain-incident --show [N]    журнал сбоев /var/log/chain-incidents.log"
  echo "     systemctl status chain-bridge, journalctl -u chain-bridge   состояние и журнал моста"
  echo
  echo "  ${B}Открыть панель (выполните на СВОЁМ компьютере):${R}"
  echo "   1) создать туннель — строка целиком, замените только ПУТЬ_К_КЛЮЧУ на путь к приватному ключу"
  echo "      (старая запись известных хостов удаляется автоматически, подтверждать «yes» не нужно; окно оставьте открытым):"
  printf '      %s%s%s\n' "$GRN" "$tun_cmd" "$R"
  echo "   2) открыть в браузере:"
  printf '      %s%s%s\n' "$GRN" "$tun_url" "$R"
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
  STEP=0; TOTAL=4
  if [ -z "${DOMAIN:-}" ] || [ -z "${VER_PATH:-}" ] || [ ! -f /etc/nginx/sites-available/xpn.conf ]; then
    fail "не найдены данные установки (домен, секретный путь, конфиг nginx): обновление возможно только на RELAY, настроенном этим скриптом"
    return 1
  fi
  echo
  echo "${B}Обновление компонентов до v$RB_VERSION${R}"
  thin
  info "RELAY: chain-health запоминает версию Xray в метке (в том числе после обновления через панель 3x-ui); с BACKEND версия сверяется только при запуске скрипта; изменения — в журнале сбоев"
  info "BACKEND: сторож запоминает версию Xray моста; при запуске скрипта RELAY спрашивает её по тому же ограниченному SSH-ключу (команда «версия»)"
  info "пользователи, пути клиентов, подписка и сертификат не меняются; мост и 3x-ui не перезапускаются"
  confirm "Обновить компоненты?" || { echo "  Отменено."; return 0; }
  section "Подключение к BACKEND"
  ask_backend
  [ "${LOCAL_BACKEND:-0}" = 1 ] || ssh_connect
  make_scripts
  section "Журнал сбоев и версии Xray на RELAY"
  step_run "Журнал сбоев на RELAY и BACKEND (записи «ИНФО»)" install_incident_log || die "журнал сбоев не обновлён (см. лог)"
  step_run "RELAY: chain-health (версия Xray, сверка с BACKEND)" lscript "$TMPD/health-relay.sh" "$VER_PATH" || die "RELAY не обновлён (см. лог)"
  section "BACKEND"
  step_run "Инструменты моста (chain-update-bridge записывает версию Xray)" rscript "$TMPD/bridge-tools.sh" || die "инструменты моста не обновлены (см. лог)"
  step_run "Сторож моста (запоминает версию Xray) и команда «версия» для RELAY" rscript "$TMPD/watchdog-install.sh" || die "BACKEND не обновлён (см. лог)"
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

main() {
  [ "$(id -u)" -eq 0 ] || { echo "Запустите от root: sudo bash $0"; exit 1; }
  mkdir -p "$(dirname "$LOG")"
  ( umask 077; : > "$LOG" ); chmod 600 "$LOG"
  TMPD=$(mktemp -d /tmp/chain-setup.XXXXXX)
  trap cleanup EXIT
  trap 'echo; warn "прервано"; exit 130' INT TERM

  banner

  preflight
  show_marks
  startup_checks
  menu
  case "$MODE" in
    prepare) run_prepare ;;
    install) run_install ;;
    uninstall) do_uninstall ;;
    update-xray) run_update_xray ;;
  esac
}

if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
