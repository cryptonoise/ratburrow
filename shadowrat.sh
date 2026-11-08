#!/usr/bin/env bash
#
VERSION="4.0"
NAME="ShadowRat"

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
CHAIN_TUNNEL_PORT=21444   # 127.0.0.1: инбаунд туннеля (dokodemo-door+XHTTP, за nginx) — просто форвардит байты в shadow-relay
CHAIN_SHADOW_RELAY_PORT=21445  # 127.0.0.1: shadow-relay слушает тут (без своего TLS — его делает Xray/nginx выше)
CHAIN_SHADOW_SOCKS_PORT=21446  # 127.0.0.1: SOCKS5 shadow-relay, сюда Xray заворачивает трафик пользователей
SELFTEST_PORT=21481       # 127.0.0.1: временный клиент для проверки цепочки
TOTAL=12
STEP=0
CHAIN_USER_ID=""; CHAIN_SUB_ID=""; SHADOW_PSK=""; SUB_PATHS=""; TUNNEL_OBFS=0

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
  printf '  %sверсия %s%s\n' "$DIM" "$VERSION" "$R"
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
      "net.ipv4.udp_rmem_min=16384" \
      "net.ipv4.udp_wmem_min=16384" \
      "net.ipv4.tcp_mtu_probing=1" \
      "net.ipv4.tcp_slow_start_after_idle=0" \
      "net.ipv4.tcp_fastopen=3" \
      "net.core.netdev_max_backlog=16384" \
      "net.core.somaxconn=4096" \
      "net.ipv4.tcp_max_syn_backlog=8192" \
      "net.ipv4.ip_local_port_range=10240 65535" \
      "net.ipv4.tcp_keepalive_time=300" \
      "net.ipv4.tcp_keepalive_intvl=30" \
      "net.ipv4.tcp_keepalive_probes=5" \
      "fs.file-max=1048576"
    if [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then echo "net.netfilter.nf_conntrack_max=262144"; fi
  } > "$f"
  sysctl -q -p "$f" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
  return 0
}

# ───────────────────────── метка установки ─────────────────────────
marker_text() {  # marker_text статус роль(relay|backend) — содержимое метки настройки канала
  cat <<EOF
STATUS=$1
ROLE=$2
INSTALLED_AT=$(date '+%F %T')
VERSION=$VERSION
KIND=${INSTALL_KIND:-chain}
RELAY_IP=${RELAY_IP:-}
BACKEND_IP=${BACKEND_IP:-}
BACKEND_PORT=${BACKEND_PORT:-}
DOMAIN=${DOMAIN:-}
XUI_BY_SCRIPT=${XUI_BY_SCRIPT:-}
EOF
}
# метка на BACKEND (по SSH); до подключения к BACKEND тихо пропускается
write_marker_backend() {  # write_marker_backend статус
  [ "${LOCAL_BACKEND:-0}" = 1 ] && return 0
  [ -n "${SSH_OPTS+x}" ] || return 0
  marker_text "$1" backend | ssh "${SSH_OPTS[@]}" "root@$BACKEND_IP" "umask 077; cat > '$MARKER_FILE'" >>"$LOG" 2>&1 ||
    warn "не удалось записать метку на BACKEND (см. лог)"
}
write_marker() {  # write_marker статус (in-progress | done) — метки на RELAY (здесь) и на BACKEND
  ( umask 077; marker_text "$1" relay > "$MARKER_FILE" )
  chmod 600 "$MARKER_FILE"
  write_marker_backend "$1"
}
marker_get() { sed -n "s/^$1=//p" "$MARKER_FILE" 2>/dev/null | head -n1; }

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
    for k in BACKEND_IP BACKEND_PORT DOMAIN KEY_PATH USER_PATH TUNNEL_PATH SHADOW_PSK TUNNEL_OBFS SUB_TITLE; do
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
SHADOW_PSK=${SHADOW_PSK:-}
HIDE_PANEL=${HIDE_PANEL:-}
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
    echo "version=$VERSION"
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
  local has=0 c
  [ -f "$MARKER_FILE" ] && has=1
  echo
  echo "${B}Что делаем?${R}"
  thin
  echo "  ${B}1${R}. Подготовить сервер"
  echo "  ${B}2${R}. Настроить защищенный канал RELAY ← BACKEND"
  [ $has -eq 1 ] && echo "  ${B}3${R}. Откат"
  while true; do
    rd -r -p "${B}?${R} Выберите вариант: " c
    case "$c" in
      1) MODE="prepare"; return 0 ;;
      2) MODE="install"; return 0 ;;
      3) if [ $has -eq 1 ]; then MODE="uninstall"; return 0; fi; fail "вариант 3 доступен только после установки" ;;
      *) if [ $has -eq 1 ]; then fail "введите от 1 до 3"; else fail "введите от 1 до 2"; fi ;;
    esac
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
timeout --foreground 1800 "${APT[@]}" install -y curl unzip nginx certbot ufw sqlite3 python3 openssl dnsutils ca-certificates gzip iproute2
EOF

  # 3x-ui: три отдельных шага, чтобы у каждого был свой счётчик времени
  cat > "$D/xui-fetch.sh" <<'EOF'
set -e
curl -fsSL --retry 3 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/3xui-install.sh
test -s /tmp/3xui-install.sh
EOF
  cat > "$D/xui-install.sh" <<'EOF'
set -e
export XUI_NONINTERACTIVE=1 XUI_DB_TYPE=sqlite XUI_SSL_MODE=none XUI_PANEL_PORT="$1"
bash /tmp/3xui-install.sh </dev/null
EOF
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
echo "туннель:      соединений от BACKEND: $n $([ "$n" -ge 1 ] && echo '(мост подключён)' || echo '(моста нет — проверьте shadow-bridge/chain-xray-local на BACKEND)')"
echo "BACKEND:      $(get BACKEND_IP) ($(head -n1 /etc/nginx/chain-backend.conf 2>/dev/null))"
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
    "health_json": json.dumps({"status": "ok", "service": svc, "version": ver, "uptime_seconds": up, "timestamp": ts}),
    "status_json": json.dumps({"status": "operational", "components": [{"name": c, "status": "operational", "latency_ms": ms} for c, u, ms in rows], "updated_at": ts}),
    "ping_json": json.dumps({"pong": True, "time": int(now.timestamp())}),
    "version_json": json.dumps({"name": svc, "version": ver, "build": build}),
    "ready_json": json.dumps({"ready": True}),
    "text_ok": "OK\n",
    "text_pong": "pong\n",
    "robots": "User-agent: *\nDisallow: /api/\nDisallow: /admin/\n",
    "security": "Contact: mailto:security@%s\nExpires: %s\nPreferred-Languages: en\n" % (domain, expires),
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
# версия Xray на RELAY больше не публикуется отдельно: архитектура «Единый
# отпечаток» не требует версийного лок-степа между RELAY и BACKEND — мост
# (shadow-bridge) говорит с RELAY через XHTTP-транспорт Xray, а не через
# VLESS-reverse внутренний протокол, и XHTTP wire-формат стабилен между
# версиями ядра гораздо надёжнее, чем было нужно для reverse-семантики.
systemctl daemon-reload
systemctl enable --now chain-site-refresh.timer >/dev/null 2>&1
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
    "# окно приёма HTTP/2 на поток (по умолчанию 64k): скорость одного потока = окно / RTT, при 60 мс это около 1 МБ/с\n"
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
CT = {"health_json": "application/json", "status_json": "application/json", "ping_json": "application/json",
      "version_json": "application/json", "ready_json": "application/json", "text_ok": "text/plain", "text_pong": "text/plain",
      "robots": "text/plain", "security": "text/plain", "status_html": "text/html"}
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
conf = (tpl.replace("@@ENDPOINTS@@", "".join(blocks)).replace("@@LISTEN80@@", listen_80).replace("@@LISTENSSL@@", listen_ssl)
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

base, token, domain, upath, tpath, uport, tport, shadow_relay_port, shadow_socks_port = sys.argv[1:10]
uport, tport, shadow_relay_port, shadow_socks_port = int(uport), int(tport), int(shadow_relay_port), int(shadow_socks_port)
tunnel_obfs = len(sys.argv) > 10 and sys.argv[10] == "1"   # padding-обфускация на туннеле BACKEND → RELAY


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


def first_client(inb):
    s = inb.get("settings")
    s = json.loads(s) if isinstance(s, str) else s
    return s["clients"][0]


# пользователи: VLESS + XHTTP, TLS снаружи (nginx); во внешней ссылке/подписке — домен:443 с TLS.
# Эта часть НЕ меняется схемой «Единый отпечаток»: Happ/Incy по-прежнему видят обычный VLESS+XHTTP.
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

# актуальный тег инбаунда пользователей (панель могла присвоить свой, если запрошенный занят)
inb_now = api("/panel/api/inbounds/list").get("obj") or []
users_tag = next((i.get("tag") for i in inb_now if i.get("port") == uport), None) or "VPN"

# ───────────────────────── туннель: dokodemo-door + XHTTP ─────────────────────────
# Архитектура «Единый отпечаток»: TUNNEL-инбаунд НЕ парсит никакой протокол (dokodemo-door
# просто форвардит уже расшифрованные Xray'ем байты на локальный shadow-relay). AUTH,
# мультиплексирование и anti-probing делает сама shadow-relay — поэтому здесь нет ни UUID,
# ни reverse-тега: секрет (SHADOW_PSK) живёт только в файле на диске у shadow-relay/shadow-bridge,
# Xray о нём вообще не знает. Простая форма /panel/api/inbounds/add протокол dokodemo-door
# не принимает (проверено: белый список protocol на этом эндпоинте его не содержит),
# поэтому и создание инбаунда, и маршрутизация идут одним проходом через raw xraySetting.
r = api("/panel/api/xray/", form={})
o = r["obj"]
o = json.loads(o) if isinstance(o, str) else o
xs = o["xraySetting"]
xs = json.loads(xs) if isinstance(xs, str) else xs
changed = False

inbounds = xs.setdefault("inbounds", [])
tunnel_inb = next((i for i in inbounds if i.get("tag") == "TUNNEL"), None)
if tunnel_inb:
    # инбаунд уже есть (переустановка) — подхватываем его реальный padding-режим
    try:
        ss = tunnel_inb.get("streamSettings")
        ss = json.loads(ss) if isinstance(ss, str) else ss
        tunnel_obfs = bool(ss["xhttpSettings"].get("xPaddingObfsMode"))
    except Exception:
        pass
else:
    inbounds.append({
        "listen": "127.0.0.1", "port": tport, "protocol": "dokodemo-door",
        "settings": {"address": "127.0.0.1", "port": shadow_relay_port, "network": "tcp"},
        "streamSettings": json.loads(stream(tpath, None, tunnel_obfs, mode="stream-up")),
        "sniffing": {"enabled": False}, "tag": "TUNNEL",
    })
    changed = True

outbounds = xs.setdefault("outbounds", [])
# ВАЖНО (проверено на живой панели): нельзя переиспользовать "direct" — у него свой
# finalRules блокирует geoip:private, а dokodemo форвардит именно на 127.0.0.1 (локальный
# shadow-relay). Без отдельного outbound Xray молча блэкхолит это соединение.
if not any(ob.get("tag") == "shadow-local" for ob in outbounds):
    outbounds.append({"protocol": "freedom", "tag": "shadow-local", "settings": {}})
    changed = True
if not any(ob.get("tag") == "socks-shadow" for ob in outbounds):
    outbounds.append({"protocol": "socks", "tag": "socks-shadow",
                       "settings": {"servers": [{"address": "127.0.0.1", "port": shadow_socks_port}]}})
    changed = True

rules = xs.setdefault("routing", {}).setdefault("rules", [])


def ensure_rule(rule, before_private=False):
    global changed
    if rule in rules:
        return
    idx = 0
    for i, x in enumerate(rules):
        # до блокировки geoip:private — нужно только для TUNNEL (его цель сама приватная);
        # иначе — после обычных служебных правил, как было в исходном скрипте
        if before_private:
            if x.get("outboundTag") == "api":
                idx = i + 1
        else:
            if x.get("outboundTag") in ("api", "blocked"):
                idx = i + 1
    rules.insert(idx, rule)
    changed = True


# трафик пользователей -> локальный SOCKS shadow-relay (вместо старого r-tunnel)
ensure_rule({"type": "field", "inboundTag": [users_tag], "outboundTag": "socks-shadow"})
# трафик TUNNEL-инбаунда -> отдельный outbound без блокировки приватных IP,
# обязательно ДО правила geoip:private (иначе Xray заблокирует сам форвард на shadow-relay)
ensure_rule({"type": "field", "inboundTag": ["TUNNEL"], "outboundTag": "shadow-local"}, before_private=True)

if changed:
    r = api("/panel/api/xray/update", form={"xraySetting": json.dumps(xs),
                                             "outboundTestUrl": o.get("outboundTestUrl", "https://www.google.com/generate_204")})
    if not r.get("success"):
        sys.exit("не удалось сохранить конфиг туннеля/маршрутизации: %s" % r.get("msg"))

print(json.dumps({"user_id": user_id, "sub_id": sub_id, "tunnel_obfs": 1 if tunnel_obfs else 0}))
PYEOF

  # RELAY: случайный набор «живых» эндпоинтов сайта (создаётся только при установке)
  cat > "$D/site-endpoints.py" <<'PYEOF'
import json, os, random, secrets
POOL = [
    ("/health", "health_json"), ("/healthz", "text_ok"), ("/api/health", "health_json"),
    ("/api/v1/health", "health_json"), ("/status", "status_html"), ("/api/status", "status_json"),
    ("/api/v1/status", "status_json"), ("/api/ping", "ping_json"), ("/ping", "text_pong"),
    ("/version", "version_json"), ("/api/version", "version_json"), ("/ready", "ready_json"),
    ("/readyz", "text_ok"), ("/livez", "text_ok"), ("/robots.txt", "robots"),
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
RELAY="$1"; DOMAIN="$2"; TPATH="$3"; TPSK="$4"; TOBFS="${5:-0}"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
case "$(uname -m)" in
  x86_64 | amd64) ARCH=64; GOARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64-v8a; GOARCH=arm64 ;;
  *) echo "неподдерживаемая архитектура: $(uname -m)" >&2; exit 1 ;;
esac
need=()
for c in curl unzip python3 sha256sum tar; do command -v "$c" >/dev/null 2>&1 || need+=("$c"); done
if [ ${#need[@]} -gt 0 ]; then
  apt-get -o DPkg::Lock::Timeout=300 update -qq
  apt-get -o DPkg::Lock::Timeout=300 install -y curl unzip python3 coreutils tar ca-certificates
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ── Xray (локальный, только loopback: принимает от shadow-bridge и выпускает
#    наружу настоящим XHTTP+TLS клиентом — тем же кодом, что у пользователей) ──
URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$ARCH.zip"
curl -fsSL --retry 3 -o "$tmp/x.zip" "$URL"
curl -fsSL --retry 3 -o "$tmp/x.dgst" "$URL.dgst"
want=$(sed -n 's/^SHA2-256= *//p' "$tmp/x.dgst" | head -n1 | tr -d '[:space:]')
have=$(sha256sum "$tmp/x.zip" | awk '{ print $1 }')
[ -n "$want" ] && [ "$want" = "$have" ] || { echo "контрольная сумма Xray не совпала" >&2; exit 1; }
unzip -oq "$tmp/x.zip" xray -d "$tmp"
install -m 755 "$tmp/xray" /usr/local/bin/chain-xray
id chainbridge >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin chainbridge
mkdir -p /etc/chain-bridge
python3 - "$RELAY" "$DOMAIN" "$TPATH" "$TOBFS" <<'PY'
import json, sys
relay, domain, tpath, tobfs = sys.argv[1:5]
cfg = {
    "log": {"loglevel": "warning", "access": "none"},
    "inbounds": [
        # shadow-bridge дозванивается сюда ОБЫЧНЫМ TCP на loopback; dokodemo-door
        # ничего не парсит — чистый проброс байт. Эти байты shadow-bridge уже
        # собрал как Shadow-кадры, Xray только оборачивает их в честный XHTTP+TLS.
        {"listen": "127.0.0.1", "port": 21900, "protocol": "dokodemo-door",
         "settings": {"address": "127.0.0.1", "port": 1, "network": "tcp"},
         "tag": "shadow-local"}
    ],
    "outbounds": [
        {"tag": "tunnel", "protocol": "freedom",
         "settings": {"redirect": relay + ":443"},
         "streamSettings": {"network": "xhttp", "security": "tls",
                             "tlsSettings": {"serverName": domain, "fingerprint": "chrome", "alpn": ["h2"]},
                             "xhttpSettings": {"host": domain, "path": "/" + tpath + "/", "mode": "stream-up",
                                                "xPaddingBytes": "100-1000"}}},
    ],
    "routing": {"rules": [{"type": "field", "inboundTag": ["shadow-local"], "outboundTag": "tunnel"}]},
}
if tobfs == "1":   # те же параметры padding, что на инбаунде туннеля у RELAY
    cfg["outbounds"][0]["streamSettings"]["xhttpSettings"].update(
        {"xPaddingObfsMode": True, "xPaddingKey": "_dc", "xPaddingHeader": "X-Cache", "xPaddingMethod": "tokenish"})
json.dump(cfg, open("/etc/chain-bridge/config.json", "w"), indent=2)
PY
chown -R root:chainbridge /etc/chain-bridge
chmod 750 /etc/chain-bridge; chmod 640 /etc/chain-bridge/config.json
/usr/local/bin/chain-xray run -test -c /etc/chain-bridge/config.json

cat > /usr/local/bin/chain-set-relay <<'EOT'
#!/bin/bash
set -e
NEW="${1:-}"; [ -n "$NEW" ] || { echo "usage: chain-set-relay НОВЫЙ_IP_RELAY"; exit 1; }
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "неверный IP"; exit 1; }
python3 - "$NEW" <<'PY'
import json, sys
f = "/etc/chain-bridge/config.json"
c = json.load(open(f))
old = c["outbounds"][0]["settings"]["redirect"]
c["outbounds"][0]["settings"]["redirect"] = sys.argv[1] + ":443"
json.dump(c, open(f, "w"), indent=2)
print("RELAY: %s -> %s:443" % (old, sys.argv[1]))
PY
systemctl restart chain-xray-local
sleep 2
systemctl is-active chain-xray-local
EOT
chmod +x /usr/local/bin/chain-set-relay

cat > /etc/systemd/system/chain-xray-local.service <<'EOT'
[Unit]
Description=chain-xray (локальный relay: dokodemo-door -> XHTTP/TLS наружу к RELAY)
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

# ── Go-toolchain + shadow-bridge (сам Shadow-протокол: AUTH, мультиплексирование;
#    TLS/uTLS больше не его забота — этим занимается chain-xray выше) ──
command -v go >/dev/null 2>&1 && go version 2>/dev/null | grep -qE 'go1\.(2[4-9]|[3-9][0-9])' || {
  curl -fsSL --retry 3 -o "$tmp/dl.json" 'https://go.dev/dl/?mode=json'
  read -r GOFILE GOSHA < <(python3 - "$GOARCH" "$tmp/dl.json" <<'PY'
import json, sys
arch, path = sys.argv[1], sys.argv[2]
for r in json.load(open(path)):
    if not r.get("stable"):
        continue
    for f in r.get("files", []):
        if f.get("os") == "linux" and f.get("arch") == arch and f.get("kind") == "archive":
            print(f["filename"], f["sha256"]); sys.exit(0)
sys.exit("подходящий релиз Go не найден")
PY
)
  curl -fsSL --retry 3 -o "$tmp/go.tgz" "https://go.dev/dl/$GOFILE"
  have=$(sha256sum "$tmp/go.tgz" | awk '{print $1}')
  [ "$have" = "$GOSHA" ] || { echo "контрольная сумма Go toolchain не совпала" >&2; exit 1; }
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tmp/go.tgz"
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
}
src=/opt/shadow-src
mkdir -p "$src"
mkdir -p "$(dirname "$src"/go.mod)"
cat > "$src"/go.mod <<'TBGO_MOD'
module shadow

go 1.24
TBGO_MOD

mkdir -p "$(dirname "$src"/mux/mux.go)"
cat > "$src"/mux/mux.go <<'TBGO_MUXMUX'
// Package mux — мультиплексирование потоков Shadow/1: один writer-goroutine на
// батчинг кадров, один reader-goroutine на диспетчеризацию по stream.
package mux

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"io"
	"sync"
	"sync/atomic"
	"time"

	"shadow/proto"
)

const (
	winStream = 8 << 20
	winConn   = 32 << 20
	batchSize = 64 << 10
	batchWait = time.Millisecond
	pingEvery = 25 * time.Second
	pingMiss  = 3
	acceptCap = 256
	outCap    = 512
	hsTimeout = 10 * time.Second

	reasonProtocol = 0x01
	reasonClosed   = 0x02
)

var (
	ErrClosed      = errors.New("mux: сессия закрыта")
	ErrStream      = errors.New("mux: поток закрыт")
	ErrProtocol    = errors.New("mux: нарушение протокола")
	ErrHandshake   = errors.New("mux: handshake не удался")
	ErrPingTimeout = errors.New("mux: нет ответа на PING")
	ErrTarget      = errors.New("mux: битый адрес цели")
	ErrAcceptFull  = errors.New("mux: очередь accept переполнена")
	// ErrExhausted — id кончились: сессию надо переоткрыть, потоков больше не будет.
	ErrExhausted = errors.New("mux: исчерпано пространство stream id")
)

// Буферы фиксированных классов; в пул кладём указатели, чтобы Put не аллоцировал.
type frameBuf [8 + proto.MaxPayload]byte
type chunkBuf [4096]byte
type batchBuf [batchSize]byte

var (
	pFrame = sync.Pool{New: func() any { return new(frameBuf) }}
	pChunk = sync.Pool{New: func() any { return new(chunkBuf) }}
	pBatch = sync.Pool{New: func() any { return new(batchBuf) }}
)

// frame — готовый кадр (заголовок + payload) в буфере из пула.
type frame struct {
	buf *frameBuf
	n   int
}

type Config struct {
	IsClient   bool
	PSK        []byte // 32 байта
	Exporter   []byte // 32 байта из TLS
	WindowConn uint32 // 0 => 16 MiB
	// PingEvery/PingMiss задают детект мёртвой сессии: молчание дольше
	// PingEvery*PingMiss закрывает сессию. 0 => 25s/3 (75 s). Мобильному
	// клиенту нужен туже: Doze усыпляет радио, NAT забывает поток, и
	// «живая» сессия иначе висит чёрной ещё минуту после пробуждения.
	PingEvery time.Duration
	PingMiss  int
	// AuthV2 — клиент просит AUTH v2 (X25519 + MAC сервера в AUTH_OK).
	// Сервер принимает обе версии всегда и различает их по длине кадра,
	// поэтому флаг нужен только клиенту: v1-клиенты продолжают работать.
	AuthV2 bool
	// Replay — общий на процесс кэш (ts, nonce). Без него сервер заводит
	// свой на сессию, что бесполезно: AUTH в сессии бывает один раз.
	Replay *proto.ReplayCache
}

type Session struct {
	conn io.ReadWriter
	cfg  Config
	max  int // максимальный payload пира

	mu       sync.Mutex
	streams  map[uint16]*Stream
	connWin  int32
	connWait chan struct{}
	connUsed int32
	nextID   uint16

	recvWin   int32 // наше окно приёма: сколько пир вправе держать у нас в полёте
	recvTotal int32 // доставлено и ещё не прочитано приложением по всем потокам

	out     chan frame
	accept  chan *Stream
	done    chan struct{}
	writerD chan struct{}

	closeOnce sync.Once
	err       error

	replay   *proto.ReplayCache
	lastRecv atomic.Int64

	// key/hasKey — сессионный ключ AUTH v2; у v1-сессий hasKey=false.
	key    [32]byte
	hasKey bool

	pingMu    sync.Mutex
	pingNonce [8]byte

	pingEvery time.Duration // детект мёртвой сессии (cfg.PingEvery)
	pingMiss  int           // сколько PING подряд без ответа терпим
}

// keepalive resolves the session-death detector: explicit values win, zero
// means the package defaults (25 s x 3).
func (c Config) keepalive() (time.Duration, int) {
	every, miss := pingEvery, pingMiss
	if c.PingEvery > 0 {
		every = c.PingEvery
	}
	if c.PingMiss > 0 {
		miss = c.PingMiss
	}
	return every, miss
}

func New(conn io.ReadWriter, cfg Config) (*Session, error) {
	// exporter нужен только AUTH v1: v2 привязывается к X25519, а uTLS вообще
	// не отдаёт ExportKeyingMaterial, поэтому браузерный отпечаток ходит с nil.
	if len(cfg.PSK) != 32 || (!cfg.AuthV2 && len(cfg.Exporter) != 32) {
		return nil, ErrHandshake
	}
	wc := int32(winConn)
	if cfg.WindowConn != 0 {
		wc = int32(cfg.WindowConn)
	}
	s := &Session{
		conn:     conn,
		cfg:      cfg,
		max:      proto.MaxPayload,
		streams:  make(map[uint16]*Stream),
		connWin:  wc,
		recvWin:  wc,
		connWait: make(chan struct{}),
		out:      make(chan frame, outCap),
		accept:   make(chan *Stream, acceptCap),
		done:     make(chan struct{}),
		writerD:  make(chan struct{}),
	}
	s.pingEvery, s.pingMiss = cfg.keepalive()
	if cfg.IsClient {
		s.nextID = 1
	} else {
		s.nextID = 2
	}
	if err := s.handshake(); err != nil {
		return nil, err
	}
	go s.writeLoop()
	go s.readLoop()
	go s.keepalive()
	return s, nil
}

func (s *Session) handshake() error {
	type deadliner interface{ SetDeadline(time.Time) error }
	if d, ok := s.conn.(deadliner); ok {
		d.SetDeadline(time.Now().Add(hsTimeout))
		defer d.SetDeadline(time.Time{})
	}
	if s.cfg.IsClient {
		return s.authClient()
	}
	return s.authServer()
}

func (s *Session) authClient() error {
	if s.cfg.AuthV2 {
		return s.authClientV2()
	}
	p, err := proto.MakeAuth(s.cfg.PSK, s.cfg.Exporter, time.Now())
	if err != nil {
		return err
	}
	if err := proto.WriteFrame(s.conn, proto.Header{Type: proto.TypeAuth}, p); err != nil {
		return err
	}
	var buf [8 + proto.MaxPayload]byte
	h, rp, err := proto.ReadFrame(s.conn, buf[:])
	if err != nil {
		return err
	}
	if h.Type != proto.TypeAuthOK {
		return ErrHandshake
	}
	mp, wc, _, err := proto.ParseAuthOK(rp)
	if err != nil {
		return ErrHandshake
	}
	if mp > 0 && int(mp) < s.max {
		s.max = int(mp)
	}
	if wc > 0 {
		s.connWin = int32(wc)
	}
	return nil
}

// authClientV2 — AUTH v2: X25519-пара, MAC сервера в AUTH_OK. Клиент обязан
// проверить тег до первого целевого байта: иначе MITM с доверенным сертификатом
// выдаёт себя за сервер и видит цели.
func (s *Session) authClientV2() error {
	priv, err := proto.NewEphemeralKeyV2()
	if err != nil {
		return ErrHandshake
	}
	pub := proto.PublicKeyV2(priv)
	p, err := proto.MakeAuthV2(s.cfg.PSK, pub, time.Now())
	if err != nil {
		return ErrHandshake
	}
	if err := proto.WriteFrame(s.conn, proto.Header{Type: proto.TypeAuth}, p); err != nil {
		return err
	}
	var buf [8 + proto.MaxPayload]byte
	h, rp, err := proto.ReadFrame(s.conn, buf[:])
	if err != nil {
		return err
	}
	if h.Type != proto.TypeAuthOK {
		return ErrHandshake
	}
	// ts и nonce берём из своей же AUTH: сервер обязан их отразить.
	ts, nonce, _, err := proto.VerifyAuthV2(s.cfg.PSK, p, time.Now())
	if err != nil {
		return ErrHandshake
	}
	if err := proto.VerifyAuthOKV2(s.cfg.PSK, rp, pub, nonce, ts); err != nil {
		return ErrHandshake // сервер не доказал знание PSK
	}
	key, err := proto.SessionKeyV2(s.cfg.PSK, priv, rp[10:42])
	if err != nil {
		return ErrHandshake
	}
	s.key, s.hasKey = key, true
	// Лимиты пира — из AUTH_OK v2 (12-байтового разбора у v2 нет).
	if len(rp) >= proto.AuthOKV2Len {
		return nil
	}
	return ErrHandshake
}

func (s *Session) authServer() error {
	var buf [8 + proto.MaxPayload]byte
	h, p, err := proto.ReadFrame(s.conn, buf[:])
	if err != nil {
		return err
	}
	// Не-AUTH кадр — это HTTP-зонд: сайт-прикрытие живёт выше mux (§4).
	if h.Type != proto.TypeAuth {
		return ErrHandshake
	}
	// Версию различаем по длине кадра: у v2 она фиксированная и не совпадает
	// с v1, поэтому отдельное согласование не нужно и старый клиент работает.
	if len(p) == proto.AuthV2Len {
		return s.authServerV2(p)
	}
	now := time.Now()
	if err := proto.VerifyAuth(s.cfg.PSK, s.cfg.Exporter, p, now); err != nil {
		return err
	}
	ts, nonce, ok := proto.AuthPayloadTS(p)
	if !ok {
		return ErrHandshake
	}
	if s.replay == nil {
		s.replay = proto.NewReplayCache()
	}
	if s.replay.Seen(now, ts, nonce) {
		return proto.ErrAuth
	}
	okp := proto.MakeAuthOK(proto.MaxPayload, uint32(s.connWin), proto.CapUrgent)
	return proto.WriteFrame(s.conn, proto.Header{Type: proto.TypeAuthOK}, okp)
}

// authServerV2 — серверная половина AUTH v2. Проверяет MAC клиента, реплей по
// общему на процесс кэшу и отвечает AUTH_OK с собственным MAC: с этого момента
// клиент точно знает, что говорит с владельцем PSK.
func (s *Session) authServerV2(p []byte) error {
	now := time.Now()
	ts, nonce, cliPub, err := proto.VerifyAuthV2(s.cfg.PSK, p, now)
	if err != nil {
		return err
	}
	rc := s.cfg.Replay
	if rc == nil {
		rc = proto.NewReplayCache()
	}
	if rc.Seen(now, ts, nonce) {
		return proto.ErrAuth // тот же (ts, nonce) уже был: реплей
	}
	priv, err := proto.NewEphemeralKeyV2()
	if err != nil {
		return ErrHandshake
	}
	srvPub := proto.PublicKeyV2(priv)
	okp, err := proto.MakeAuthOKV2(s.cfg.PSK, cliPub, srvPub, nonce, ts)
	if err != nil {
		return ErrHandshake
	}
	if err := proto.WriteFrame(s.conn, proto.Header{Type: proto.TypeAuthOK}, okp); err != nil {
		return err
	}
	key, err := proto.SessionKeyV2(s.cfg.PSK, priv, cliPub)
	if err != nil {
		return ErrHandshake
	}
	s.key, s.hasKey = key, true
	return nil
}

// Key — сессионный ключ AUTH v2 (32 байта). ok=false для v1-сессий: там ключа нет.
func (s *Session) Key() (key [32]byte, ok bool) { return s.key, s.hasKey }

func (s *Session) Done() <-chan struct{} { return s.done }

// Close мягко：шлёт CLOSE, даёт writer'у сбросить батч и закрывает соединение.
func (s *Session) Close() error {
	s.fail(ErrClosed, reasonClosed)
	t := time.NewTimer(2 * time.Second)
	defer t.Stop()
	select {
	case <-s.writerD:
	case <-t.C:
		if c, ok := s.conn.(io.Closer); ok {
			c.Close()
		}
		// Без io.Closer writer может висеть в conn.Write вечно: не ждём его
		// дольше, но и не даём Close() висеть самому.
		select {
		case <-s.writerD:
		case <-time.After(500 * time.Millisecond):
		}
	}
	return nil
}

func (s *Session) OpenStream(ctx context.Context, target []byte) (*Stream, error) {
	return s.OpenStreamKind(ctx, target, false)
}

// OpenStreamKind открывает поток; udp помечает его как датаграммный (SOCKS5 UDP
// ASSOCIATE), сервер по этой пометке релеит UDP вместо TCP.
func (s *Session) OpenStreamKind(ctx context.Context, target []byte, udp bool) (*Stream, error) {
	flags := uint8(proto.FlagOpen)
	if udp {
		flags |= proto.FlagUDP
	}
	return s.open(ctx, target, flags)
}

// OpenTun открывает поток IP-пакетов (режим TUN): адресного блока у него нет,
// поэтому цель в OPEN не передаётся вовсе.
func (s *Session) OpenTun(ctx context.Context) (*Stream, error) {
	return s.open(ctx, nil, proto.FlagOpen|proto.FlagIP)
}

func (s *Session) open(ctx context.Context, target []byte, flags uint8) (*Stream, error) {
	if flags&proto.FlagIP == 0 {
		if n := proto.TargetLen(target); n < 0 || n != len(target) {
			return nil, ErrTarget
		}
	}
	s.mu.Lock()
	if s.isClosed() {
		s.mu.Unlock()
		return nil, s.closedErr()
	}
	id := s.nextID
	if id == 0 || id > 0x7FFF {
		s.mu.Unlock()
		return nil, ErrExhausted
	}
	s.nextID += 2
	s.mu.Unlock()

	st := s.newStream(id, append([]byte(nil), target...))
	st.udp = flags&proto.FlagUDP != 0
	st.ip = flags&proto.FlagIP != 0
	if !s.register(st) {
		return nil, ErrStream
	}
	h := proto.Header{Type: proto.TypeData, Flags: flags, Stream: id}
	if _, err := st.write(ctx, h, target); err != nil {
		s.drop(st)
		return nil, err
	}
	return st, nil
}

func (s *Session) AcceptStream(ctx context.Context) (*Stream, error) {
	select {
	case st := <-s.accept:
		return st, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-s.done:
		return nil, s.closedErr()
	}
}

func (s *Session) newStream(id uint16, target []byte) *Stream {
	return &Stream{
		s:       s,
		id:      id,
		tgt:     target,
		sendWin: winStream,
		rwake:   make(chan struct{}, 1),
		wait:    make(chan struct{}),
	}
}

func (s *Session) register(st *Stream) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.streams[st.id] != nil {
		return false
	}
	s.streams[st.id] = st
	return true
}

func (s *Session) drop(st *Stream) {
	s.mu.Lock()
	if s.streams[st.id] == st {
		delete(s.streams, st.id)
	}
	s.mu.Unlock()
}

// onStreamClose — пир сбросил поток (CLOSE с id != 0): освобождаем его и
// возвращаем окно соединения за недочитанные байты, иначе окно утекает и
// новые потоки встают навсегда.
func (s *Session) onStreamClose(id uint16, p []byte) error {
	st := s.stream(id)
	if st == nil {
		return nil // поток уже закрыт — CLOSE мог прийти на гонке
	}
	st.resetLocal(ErrStream)
	s.returnRecvWindow(st)
	return nil
}

// returnRecvWindow возвращает пиру кредит за доставленные, но не прочитанные
// байты потока: при закрытии они уже не будут прочитаны, а окно соединения
// останется занятым навсегда.
func (s *Session) returnRecvWindow(st *Stream) {
	s.mu.Lock()
	pend := st.recvPending
	st.recvPending = 0
	if s.recvTotal -= pend; s.recvTotal < 0 {
		s.recvTotal = 0
	}
	s.mu.Unlock()
	if pend > 0 {
		// Асинхронно: читающий goroutine НЕ должен блокироваться на отправке,
		// иначе забитая очередь исходящих вешает приём целиком (дедлок:
		// writer ждёт conn.Write, reader ждёт очередь).
		go func() {
			wu := proto.WUPayload(0, uint32(pend))
			s.send(proto.Header{Type: proto.TypeWU}, wu[:])
		}()
	}
}

// killStream рвёт один поток, не роняя сессию: окно за недочитанное пиру
// возвращаем, CLOSE шлём неблокирующе.
func (s *Session) killStream(st *Stream, reason byte) {
	s.returnRecvWindow(st)
	st.resetLocal(ErrProtocol)
	s.trySend(proto.Header{Type: proto.TypeClose, Stream: st.id}, []byte{reason})
}

func (s *Session) stream(id uint16) *Stream {
	s.mu.Lock()
	st := s.streams[id]
	s.mu.Unlock()
	return st
}

func (s *Session) isClosed() bool {
	select {
	case <-s.done:
		return true
	default:
		return false
	}
}

// closedErr — ошибка закрытия; s.err читается только после получения из done.
func (s *Session) closedErr() error {
	select {
	case <-s.done:
		if s.err != nil {
			return s.err
		}
		return ErrClosed
	default:
		return ErrClosed
	}
}

func (s *Session) fail(err error, reason byte) {
	s.closeOnce.Do(func() {
		s.err = err
		if f, e := s.build(proto.Header{Type: proto.TypeClose}, []byte{reason}); e == nil {
			select {
			case s.out <- f:
			default:
				pFrame.Put(f.buf)
			}
		}
		close(s.done)
	})
}

func (s *Session) build(h proto.Header, p []byte) (frame, error) {
	if len(p) > proto.MaxPayload {
		return frame{}, proto.ErrLength
	}
	fb := pFrame.Get().(*frameBuf)
	h.Length = uint16(len(p))
	h.MarshalTo(fb[:])
	copy(fb[8:], p)
	return frame{buf: fb, n: 8 + len(p)}, nil
}

// trySend — неблокирующая отправка: false, если очередь исходящих полна.
func (s *Session) trySend(h proto.Header, p []byte) bool {
	f, err := s.build(h, p)
	if err != nil {
		return true // некорректный кадр отбрасываем, очередь не занимаем
	}
	select {
	case s.out <- f:
		return true
	default:
		pFrame.Put(f.buf)
		return false
	}
}

func (s *Session) send(h proto.Header, p []byte) error {
	f, err := s.build(h, p)
	if err != nil {
		return err
	}
	select {
	case s.out <- f:
		return nil
	case <-s.done:
		pFrame.Put(f.buf)
		return s.closedErr()
	}
}

// onWU начисляет кредит, но не больше номинала окна: delta близка к 2^32
// иначе уводит окно в минус (Write виснет навсегда) или раздувает его выше
// буфера пира.
func (s *Session) onWU(id uint16, delta uint32) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if id == 0 {
		if delta == 0 || delta > winConn {
			return
		}
		s.connWin = int32(min(int64(s.connWin)+int64(delta), int64(winConn)))
		close(s.connWait)
		s.connWait = make(chan struct{})
		return
	}
	st := s.streams[id]
	if st == nil || delta == 0 || delta > winStream {
		return
	}
	st.sendWin = int32(min(int64(st.sendWin)+int64(delta), int64(winStream)))
	close(st.wait)
	st.wait = make(chan struct{})
}

func (s *Session) readLoop() {
	buf := make([]byte, 8+proto.MaxPayload)
	for {
		h, p, err := proto.ReadFrame(s.conn, buf)
		if err != nil {
			if err == io.EOF {
				err = ErrClosed
			}
			s.fail(err, reasonClosed)
			return
		}
		s.lastRecv.Store(time.Now().UnixNano())
		if err := s.handle(h, p); err != nil {
			s.fail(err, reasonProtocol)
			return
		}
	}
}

func (s *Session) handle(h proto.Header, p []byte) error {
	switch h.Type {
	case proto.TypeData:
		return s.onData(h, p)
	case proto.TypeFin:
		if st := s.stream(h.Stream); st != nil {
			st.remoteFin()
		}
		return nil
	case proto.TypeWU:
		id, delta, ok := proto.ParseWU(p)
		if !ok {
			return ErrProtocol
		}
		s.onWU(id, delta)
		return nil
	case proto.TypePing:
		if len(p) != 8 {
			return ErrProtocol
		}
		s.onPing(p)
		return nil
	case proto.TypeClose:
		if h.Stream != 0 {
			return s.onStreamClose(h.Stream, p)
		}
		s.fail(ErrClosed, reasonClosed)
		return nil
	default:
		// PAD, MIG, ACK, AUTH/AUTH_OK после handshake — игнор
		return nil
	}
}

func (s *Session) onPing(p []byte) {
	s.pingMu.Lock()
	ours := bytes.Equal(p, s.pingNonce[:])
	s.pingMu.Unlock()
	if ours {
		return
	}
	s.send(proto.Header{Type: proto.TypePing}, p)
}

func (s *Session) onData(h proto.Header, p []byte) error {
	if h.Stream == 0 {
		return ErrProtocol
	}
	fin := h.Flags&proto.FlagFin != 0
	if h.Flags&proto.FlagOpen != 0 {
		if (h.Stream%2 == 0) != s.cfg.IsClient {
			return ErrProtocol // чужая чётность (§3)
		}
		n := 0
		if h.Flags&proto.FlagIP == 0 { // у потока IP-пакетов адресного блока нет
			if n = proto.TargetLen(p); n < 0 || n != len(p) {
				return ErrProtocol
			}
		}
		st := s.newStream(h.Stream, append([]byte(nil), p[:n]...))
		st.udp = h.Flags&proto.FlagUDP != 0
		st.ip = h.Flags&proto.FlagIP != 0
		if !s.register(st) {
			// Дубль OPEN: рвём только этот id, сессию не трогаем.
			if old := s.stream(h.Stream); old != nil {
				s.killStream(old, reasonProtocol)
			}
			return nil
		}
		select {
		case s.accept <- st:
		default:
			// Очередь accept полна: отказываем одному потоку, а не всей
			// сессии — иначе 400 OPEN рвут все живые туннели.
			s.killStream(st, reasonProtocol)
			return nil
		}
		if err := st.deliver(p[n:], fin); err != nil {
			if err == ErrProtocol { // превышено окно приёма: валим сессию
				return err
			}
			if err == errAfterFin {
				s.killStream(st, reasonProtocol)
			}
		}
		return nil
	}
	st := s.stream(h.Stream)
	if st == nil {
		// Поток уже сброшен (CLOSE в пути): кадры, отправленные до CLOSE,
		// просто отбрасываем — но окно соединения за них возвращаем, иначе
		// кредит пира тает на каждом Reset. Это не нарушение протокола,
		// иначе сессия падала бы после каждого Reset.
		if n := len(p); n > 0 {
			wu := proto.WUPayload(0, uint32(n))
			s.trySend(proto.Header{Type: proto.TypeWU}, wu[:])
		}
		return nil
	}
	if err := st.deliver(p, fin); err != nil {
		switch err {
		case ErrProtocol: // превышено окно приёма: пир нарушил протокол
			return err
		case errAfterFin: // данные после чистого FIN: виноват один поток
			s.killStream(st, reasonProtocol)
		}
	}
	return nil
}

func (s *Session) writeLoop() {
	defer close(s.writerD)
	bp := pBatch.Get().(*batchBuf)
	batch := bp[:0]
	t := time.NewTimer(time.Hour)
	t.Stop()
	var tc <-chan time.Time

	flush := func() error {
		if len(batch) == 0 {
			return nil
		}
		if _, err := s.conn.Write(batch); err != nil {
			s.fail(err, reasonClosed)
			return err
		}
		batch = batch[:0]
		return nil
	}
	push := func(f frame) error {
		if len(batch)+f.n > cap(batch) {
			if err := flush(); err != nil {
				pFrame.Put(f.buf)
				return err
			}
		}
		batch = append(batch, f.buf[:f.n]...)
		pFrame.Put(f.buf)
		return nil
	}
	stopTimer := func() {
		if tc != nil {
			if !t.Stop() {
				select {
				case <-t.C:
				default:
				}
			}
			tc = nil
		}
	}

loop:
	for {
		select {
		case f := <-s.out:
			urgent := f.buf[1]&proto.FlagUrgent != 0
			if push(f) != nil {
				break loop
			}
			if urgent || len(batch) >= batchSize {
				stopTimer()
				if flush() != nil {
					break loop
				}
				continue
			}
			if tc == nil {
				t.Reset(batchWait)
				tc = t.C
			}
		case <-tc:
			tc = nil
			if flush() != nil {
				break loop
			}
		case <-s.done:
			for {
				select {
				case f := <-s.out:
					if push(f) != nil {
						break loop
					}
				default:
					flush()
					break loop
				}
			}
		}
	}
	stopTimer()
	pBatch.Put(bp)
	// соединение закрывает только writer: reader разблокируется на ошибке чтения
	if c, ok := s.conn.(io.Closer); ok {
		c.Close()
	}
}

func (s *Session) keepalive() {
	t := time.NewTimer(s.pingEvery)
	defer t.Stop()
	prev := s.lastRecv.Load()
	misses := 0
	for {
		select {
		case <-s.done:
			return
		case <-t.C:
		}
		cur := s.lastRecv.Load()
		if cur == prev {
			misses++
			if misses >= s.pingMiss {
				s.fail(ErrPingTimeout, reasonProtocol)
				return
			}
			s.ping()
		} else {
			misses = 0
		}
		prev = cur
		t.Reset(s.pingEvery)
	}
}

func (s *Session) ping() {
	var n [8]byte
	rand.Read(n[:])
	s.pingMu.Lock()
	s.pingNonce = n
	s.pingMu.Unlock()
	s.send(proto.Header{Type: proto.TypePing}, n[:])
}
TBGO_MUXMUX

mkdir -p "$(dirname "$src"/mux/stream.go)"
cat > "$src"/mux/stream.go <<'TBGO_MUXSTREAM'
package mux

import (
	"context"
	"errors"
	"io"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"shadow/proto"
)

type recvChunk struct {
	buf *chunkBuf
	n   int // записано
	off int // прочитано
}

type Stream struct {
	s   *Session
	id  uint16
	tgt []byte
	udp bool // датаграммный поток (SOCKS5 UDP ASSOCIATE)
	ip  bool // поток IP-пакетов (режим TUN)

	rmu   sync.Mutex
	rq    []recvChunk
	rhead int
	rerr  error
	rfin  bool
	rwake chan struct{} // семафор: 1 токен = «проверь очередь»

	// под rmu: дедлайн чтения. Срабатывая, он кидает токен в rwake — тот же
	// семафор, что и у данных, поэтому select в Read не подорожал.
	rdl    time.Time
	rdlGen uint64 // поколение: таймер прошлого поколения не стреляет
	rdlTmr *time.Timer

	// под s.mu
	sendWin     int32
	recvUsed    int32
	recvPending int32 // доставлено приложению, но ещё не прочитано
	wait        chan struct{}

	sfin   atomic.Bool
	urgent atomic.Bool
}

// Target — адресный блок §3, с которым поток открыт.
func (st *Stream) Target() []byte { return st.tgt }

// IsUDP — поток датаграммный (открыт с proto.FlagUDP).
func (st *Stream) IsUDP() bool { return st.udp }

// IsIP — поток несёт IP-пакеты (открыт с proto.FlagIP, режим TUN).
func (st *Stream) IsIP() bool { return st.ip }

func (st *Stream) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	st.rmu.Lock()
	for {
		if st.rhead < len(st.rq) {
			c := &st.rq[st.rhead]
			n := copy(p, c.buf[c.off:c.n])
			if n > 0 {
				c.off += n
				var done *chunkBuf
				if c.off == c.n {
					done = c.buf
					st.rq[st.rhead] = recvChunk{}
					st.rhead++
					st.compact()
				}
				drained := st.rhead == len(st.rq)
				st.rmu.Unlock()
				if done != nil {
					pChunk.Put(done)
				}
				st.consumed(n, drained)
				return n, nil
			}
		}
		if st.rerr != nil {
			err := st.rerr
			st.rmu.Unlock()
			return 0, err
		}
		// Истёкший дедлайн проверяем до блокировки: данные из очереди важнее.
		expired := st.readExpired()
		st.rmu.Unlock()
		if expired {
			return 0, os.ErrDeadlineExceeded
		}
		select {
		case <-st.rwake:
		case <-st.s.done:
			return 0, st.s.closedErr()
		}
		st.rmu.Lock()
	}
}

// readExpired (под rmu) сообщает, что дедлайн чтения истёк, и снимает его:
// следующий Read снова блокируется, а не спотыкается о мёртвый дедлайн.
func (st *Stream) readExpired() bool {
	if st.rdl.IsZero() || st.rdl.After(time.Now()) {
		return false
	}
	st.rdl = time.Time{}
	if st.rdlTmr != nil {
		st.rdlTmr.Stop()
		st.rdlTmr = nil
	}
	return true
}

// kick (под rmu) будит блокирующий Read: данные пришли или дедлайн истёк.
func (st *Stream) kick() {
	select {
	case st.rwake <- struct{}{}:
	default:
	}
}

// SetReadDeadline взводит дедлайн чтения: по его истечении блокирующий Read
// вернёт os.ErrDeadlineExceeded. Нулевое время снимает дедлайн, повторный
// вызов заменяет прежний таймер.
func (st *Stream) SetReadDeadline(t time.Time) error {
	st.rmu.Lock()
	defer st.rmu.Unlock()
	if st.rdlTmr != nil {
		st.rdlTmr.Stop()
		st.rdlTmr = nil
	}
	st.rdl = t
	st.rdlGen++
	switch d := time.Until(t); {
	case t.IsZero():
	case d <= 0:
		st.kick()
	default:
		gen := st.rdlGen
		st.rdlTmr = time.AfterFunc(d, func() {
			st.rmu.Lock()
			if st.rdlGen == gen { // таймер своего поколения: чужой не стреляет
				st.rdlTmr = nil
				st.kick()
			}
			st.rmu.Unlock()
		})
	}
	return nil
}

// WriteContext — Write, у которого ожидание окна отменяется ctx.
func (st *Stream) WriteContext(ctx context.Context, p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if st.sfin.Load() {
		return 0, ErrStream
	}
	h := proto.Header{Type: proto.TypeData, Stream: st.id}
	if st.urgent.Load() {
		h.Flags = proto.FlagUrgent
	}
	return st.write(ctx, h, p)
}

func (st *Stream) Write(p []byte) (int, error) {
	return st.WriteContext(context.Background(), p)
}

// Close — полузакрытие: FIN в свою сторону; поток освобождается после FIN пира.
func (st *Stream) Close() error {
	if st.sfin.Swap(true) {
		return nil
	}
	s := st.s
	s.mu.Lock()
	close(st.wait)
	st.wait = make(chan struct{})
	s.mu.Unlock()
	err := s.send(proto.Header{Type: proto.TypeFin, Stream: st.id}, nil)
	st.maybeFree()
	return err
}

// Reset рвёт поток: CLOSE пиру + локальная очистка. В отличие от Close (FIN),
// говорит пиру «перестань слать», поэтому освобождает окно соединения.
func (st *Stream) Reset() error {
	s := st.s
	// Байты, доставленные нам, но не прочитанные приложением, надо вернуть
	// пиру как окно — иначе его connWin утекает и он замолкает навсегда.
	err := s.send(proto.Header{Type: proto.TypeClose, Stream: st.id}, []byte{reasonClosed})
	st.resetLocal(ErrStream)
	s.returnRecvWindow(st)
	return err
}

// resetLocal помечает поток закрытым с обеих сторон и будит читателей/писателей.
func (st *Stream) resetLocal(err error) {
	s := st.s
	st.rmu.Lock()
	if st.rerr == nil {
		st.rerr = err
	}
	st.rfin = true
	st.rmu.Unlock()
	st.sfin.Store(true) // писатели выходят из reserve с ErrStream
	s.mu.Lock()
	close(st.wait)
	st.wait = make(chan struct{})
	s.mu.Unlock()
	st.kick()
	s.drop(st)
}

// SetUrgent ставит URGENT на исходящие кадры потока.
func (st *Stream) SetUrgent(on bool) { st.urgent.Store(on) }

func (st *Stream) write(ctx context.Context, h proto.Header, p []byte) (int, error) {
	written := 0
	for {
		n, err := st.reserve(ctx, len(p))
		if err != nil {
			return written, err
		}
		h.Length = uint16(n)
		if err := st.s.send(h, p[:n]); err != nil {
			st.release(n)
			return written, err
		}
		written += n
		p = p[n:]
		if len(p) == 0 {
			return written, nil
		}
	}
}

// reserve списывает окно и ждёт, если оно кончилось.
func (st *Stream) reserve(ctx context.Context, max int) (int, error) {
	s := st.s
	for {
		s.mu.Lock()
		if st.sfin.Load() {
			s.mu.Unlock()
			return 0, ErrStream
		}
		// Сессия могла умереть: кредит выдавать нельзя, иначе Write вернёт nil,
		// а кадр уйдёт в очередь мёртвого writer'а (данные потеряны молча).
		if s.isClosed() {
			s.mu.Unlock()
			return 0, s.closedErr()
		}
		// Кадр без полезной нагрузки окно не тратит — иначе write() с пустым
		// payload ждал бы кредит вечно (OPEN потока IP-пакетов, FIN).
		if max == 0 {
			s.mu.Unlock()
			return 0, nil
		}
		if st.sendWin < 0 {
			st.sendWin = 0
		}
		if s.connWin < 0 {
			s.connWin = 0
		}
		n := min(max, s.max)
		if int32(n) > st.sendWin {
			n = int(st.sendWin)
		}
		if int32(n) > s.connWin {
			n = int(s.connWin)
		}
		if n > 0 {
			st.sendWin -= int32(n)
			s.connWin -= int32(n)
			s.mu.Unlock()
			return n, nil
		}
		ch, cch := st.wait, s.connWait
		s.mu.Unlock()
		select {
		case <-ch:
		case <-cch:
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-s.done:
			return 0, s.closedErr()
		}
	}
}

func (st *Stream) release(n int) {
	s := st.s
	s.mu.Lock()
	st.sendWin += int32(n)
	s.connWin += int32(n)
	s.mu.Unlock()
}

// consumed возвращает окно пиру через WU при 1/8 расхода (§5).
func (st *Stream) consumed(n int, drained bool) {
	s := st.s
	s.mu.Lock()
	st.recvUsed += int32(n)
	st.recvPending -= int32(n)
	if st.recvPending < 0 {
		st.recvPending = 0
	}
	if s.recvTotal -= int32(n); s.recvTotal < 0 {
		s.recvTotal = 0
	}
	s.connUsed += int32(n)
	var sDelta, cDelta uint32
	// Порог 1/8 окна; при опустевшей очереди хвост отдаём раньше, но не мельче
	// 1/64 окна — иначе на каждый Read уходит кадр WU и трафик растёт впустую.
	tailMin := int32(winStream / 64)
	if st.recvUsed >= winStream/8 || (drained && st.recvUsed >= tailMin) {
		sDelta, st.recvUsed = uint32(st.recvUsed), 0
	}
	if s.connUsed >= winConn/8 || (drained && s.connUsed >= tailMin) {
		cDelta, s.connUsed = uint32(s.connUsed), 0
	}
	s.mu.Unlock()

	// consumed вызывается из Read: блокирующий send здесь останавливает приём
	// целиком. Если очередь полна — возвращаем кредит в счётчики и отдадим
	// при следующем чтении.
	if sDelta > 0 {
		p := proto.WUPayload(st.id, sDelta)
		if !s.trySend(proto.Header{Type: proto.TypeWU}, p[:]) {
			s.mu.Lock()
			st.recvUsed += int32(sDelta)
			s.mu.Unlock()
		}
	}
	if cDelta > 0 {
		p := proto.WUPayload(0, cDelta)
		if !s.trySend(proto.Header{Type: proto.TypeWU}, p[:]) {
			s.mu.Lock()
			s.connUsed += int32(cDelta)
			s.mu.Unlock()
		}
	}
}

// errAfterFin — данные после чистого FIN: рвём поток, но не сессию.
var errAfterFin = errors.New("mux: данные после FIN")

// deliver кладёт данные в очередь приёма; вызывается только reader'ом.
func (st *Stream) deliver(p []byte, fin bool) error {
	st.rmu.Lock()
	if st.rerr != nil {
		err := st.rerr
		st.rmu.Unlock()
		if err == ErrStream {
			return ErrStream // поток сброшен нами: кадр в пути — не нарушение
		}
		return errAfterFin // данные после чистого FIN — виноват только поток
	}
	if n := len(p); n > 0 {
		// под s.mu и ДО push: пир, игнорирующий окна, не должен набить
		// очередь приёма целиком (иначе одна сессия кладёт сервер по памяти).
		s := st.s
		s.mu.Lock()
		if st.recvPending+int32(n) > winStream || s.recvTotal+int32(n) > s.recvWin {
			s.mu.Unlock()
			st.rmu.Unlock()
			return ErrProtocol
		}
		st.recvPending += int32(n)
		s.recvTotal += int32(n)
		s.mu.Unlock()
		st.push(p)
	}
	if fin {
		st.rfin = true
		st.rerr = io.EOF
	}
	st.kick()
	st.rmu.Unlock()
	if fin {
		st.maybeFree()
	}
	return nil
}

func (st *Stream) push(p []byte) {
	if n := len(st.rq); n > st.rhead {
		c := &st.rq[n-1]
		if len(c.buf)-c.n >= len(p) {
			copy(c.buf[c.n:], p)
			c.n += len(p)
			return
		}
	}
	cb := pChunk.Get().(*chunkBuf)
	copy(cb[:], p)
	st.rq = append(st.rq, recvChunk{buf: cb, n: len(p)})
}

func (st *Stream) compact() {
	if st.rhead > 16 && st.rhead*2 >= len(st.rq) {
		n := copy(st.rq, st.rq[st.rhead:])
		st.rq = st.rq[:n]
		st.rhead = 0
	}
}

func (st *Stream) remoteFin() {
	st.rmu.Lock()
	if st.rfin {
		st.rmu.Unlock()
		return
	}
	st.rfin = true
	if st.rerr == nil {
		st.rerr = io.EOF
	}
	st.kick()
	st.rmu.Unlock()
	st.maybeFree()
}

func (st *Stream) maybeFree() {
	st.rmu.Lock()
	both := st.rfin && st.sfin.Load()
	st.rmu.Unlock()
	if both {
		// Поток уходит из таблицы: недочитанный кредит обязан вернуться пиру,
		// иначе connWin тает и новые потоки встают навсегда.
		st.s.returnRecvWindow(st)
		st.s.drop(st)
	}
}
TBGO_MUXSTREAM

mkdir -p "$(dirname "$src"/proto/auth.go)"
cat > "$src"/proto/auth.go <<'TBGO_AUTH'
package proto

import (
	"container/list"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"sync"
	"time"
)

const (
	AuthVersion = 1
	authLen     = 50
	AuthSkew    = 120 // секунд, §4

	// KeyLen — длина PSK и любого ключевого материала протокола.
	KeyLen = 32

	// caps в AUTH_OK
	CapUrgent   = 1 << 0
	CapDatagram = 1 << 1
	CapWeb      = 1 << 2
)

var (
	ErrAuth   = errors.New("proto: AUTH отклонён")
	ErrAuthOK = errors.New("proto: AUTH_OK битый")
	authLabel = []byte("SHADOW1-AUTH")
)

// AuthTag = HMAC-SHA256(psk, "SHADOW1-AUTH" || exporter || ver || ts || nonce)[32].
// ver и ts — big-endian, как в заголовке кадра.
// Контракт: len(psk) == len(exporter) == KeyLen. Длины проверяют MakeAuth и
// VerifyAuth; сам AuthTag копирует в 32-байтовый слот сообщения и ошибку не
// возвращает — вызывать его напрямую с другими длинами нельзя.
func AuthTag(psk, exporter []byte, ver uint16, ts uint64, nonce []byte) [32]byte {
	var msg [9 + KeyLen + 2 + 8 + 8]byte
	var nb [8]byte
	copy(nb[:], nonce)
	n := copy(msg[:], authLabel)
	n += copy(msg[n:], exporter[:min(len(exporter), KeyLen)])
	binary.BigEndian.PutUint16(msg[n:], ver)
	binary.BigEndian.PutUint64(msg[n+2:], ts)
	copy(msg[n+10:], nb[:])

	m := hmac.New(sha256.New, psk)
	m.Write(msg[:n+18])
	var tag [32]byte
	copy(tag[:], m.Sum(nil))
	return tag
}

// skewOK — |now - ts| <= AuthSkew без знаковой арифметики: разность двух uint64
// определена по модулю 2^64, поэтому ts = now+2^63 даёт разницу 2^63 > AuthSkew,
// а не MinInt64 с последующим -d (старый вариант такую метку пропускал).
func skewOK(now time.Time, ts uint64) bool {
	n := uint64(now.Unix())
	d := n - ts
	if ts > n {
		d = ts - n
	}
	return d <= AuthSkew
}

// MakeAuth собирает 50-байтовый payload AUTH с текущим ts и случайным nonce.
func MakeAuth(psk, exporter []byte, now time.Time) ([]byte, error) {
	if len(psk) != KeyLen || len(exporter) != KeyLen {
		return nil, ErrAuth
	}
	b := make([]byte, authLen)
	binary.BigEndian.PutUint16(b[0:], AuthVersion)
	ts := uint64(now.Unix())
	binary.BigEndian.PutUint64(b[2:], ts)
	if _, err := rand.Read(b[10:18]); err != nil {
		return nil, err
	}
	tag := AuthTag(psk, exporter, AuthVersion, ts, b[10:18])
	copy(b[18:], tag[:])
	return b, nil
}

// VerifyAuth проверяет ver, |now-ts| <= 120 c и тег (constant-time). Replay — ReplayCache.
func VerifyAuth(psk, exporter, payload []byte, now time.Time) error {
	if len(psk) != KeyLen || len(exporter) != KeyLen {
		return ErrAuth
	}
	if len(payload) != authLen {
		return ErrAuth
	}
	if binary.BigEndian.Uint16(payload[0:]) != AuthVersion {
		return ErrAuth
	}
	ts := binary.BigEndian.Uint64(payload[2:])
	if !skewOK(now, ts) {
		return ErrAuth
	}
	want := AuthTag(psk, exporter, AuthVersion, ts, payload[10:18])
	if !hmac.Equal(want[:], payload[18:50]) {
		return ErrAuth
	}
	return nil
}

// AuthPayloadTS разбирает ts и nonce из payload AUTH (уже проверенного VerifyAuth).
func AuthPayloadTS(payload []byte) (ts uint64, nonce []byte, ok bool) {
	if len(payload) != authLen {
		return 0, nil, false
	}
	return binary.BigEndian.Uint64(payload[2:]), payload[10:18], true
}

// AUTH_OK: ver u16, maxPayload u16, windowConn u32, caps u32.
func MakeAuthOK(maxPayload uint16, windowConn, caps uint32) []byte {
	b := make([]byte, 12)
	binary.BigEndian.PutUint16(b[0:], AuthVersion)
	binary.BigEndian.PutUint16(b[2:], maxPayload)
	binary.BigEndian.PutUint32(b[4:], windowConn)
	binary.BigEndian.PutUint32(b[8:], caps)
	return b
}

func ParseAuthOK(p []byte) (maxPayload uint16, windowConn, caps uint32, err error) {
	if len(p) != 12 || binary.BigEndian.Uint16(p[0:]) != AuthVersion {
		return 0, 0, 0, ErrAuthOK
	}
	return binary.BigEndian.Uint16(p[2:]), binary.BigEndian.Uint32(p[4:]), binary.BigEndian.Uint32(p[8:]), nil
}

const (
	replayTTL = 5 * time.Minute
	replayCap = 10000
)

type replayKey struct {
	ts    uint64
	nonce [8]byte
}

type replayEntry struct {
	k  replayKey
	at time.Time
}

// ReplayCache — LRU на (ts, nonce) с TTL 5 мин и ёмкостью 10000 (§4).
// Безопасен для конкурентного использования: живёт столько же, сколько сервер,
// и передаётся всем сессиям. Кэш на одну сессию бесполезен — AUTH в сессии
// бывает ровно один раз, повторить его негде.
type ReplayCache struct {
	mu  sync.Mutex
	ll  *list.List
	m   map[replayKey]*list.Element
	ttl time.Duration
	cap int
}

// NewReplayCache — кэш с параметрами по умолчанию (5 мин, 10000).
func NewReplayCache() *ReplayCache {
	return NewReplayCacheWith(replayTTL, replayCap)
}

// NewReplayCacheWith — кэш с явными TTL и ёмкостью; <= 0 означает дефолт.
func NewReplayCacheWith(ttl time.Duration, capacity int) *ReplayCache {
	if ttl <= 0 {
		ttl = replayTTL
	}
	if capacity <= 0 {
		capacity = replayCap
	}
	return &ReplayCache{ll: list.New(), m: make(map[replayKey]*list.Element, 64), ttl: ttl, cap: capacity}
}

// Seen сообщает, что (ts, nonce) уже видели, и запоминает пару.
func (c *ReplayCache) Seen(now time.Time, ts uint64, nonce []byte) bool {
	if len(nonce) < 8 {
		return true
	}
	var k replayKey
	k.ts = ts
	copy(k.nonce[:], nonce)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ll == nil { // нулевое значение: всё считаем реплеем, паниковать незачем
		return true
	}
	// вытесняем с головы: просроченные и лишние (порядок вставки)
	for f := c.ll.Front(); f != nil; f = c.ll.Front() {
		e := f.Value.(replayEntry)
		if len(c.m) < c.cap && now.Sub(e.at) < c.ttl {
			break
		}
		c.ll.Remove(f)
		delete(c.m, e.k)
	}
	if e, ok := c.m[k]; ok {
		c.ll.MoveToBack(e)
		return true
	}
	c.m[k] = c.ll.PushBack(replayEntry{k: k, at: now})
	return false
}

// --- AUTH v2: X25519 + MAC в обе стороны (docs/13-plan-v2.md §3) ---
//
// Зачем: в v1 сервер доказывает знание PSK только самим фактом AUTH_OK, поэтому
// MITM с доверенным клиенту сертификатом выдаёт себя за сервер. В v2 сервер
// обязан прислать MAC, клиент его проверяет, а привязка к соединению идёт через
// ECDH, а не через TLS-exporter: exporter недоступен под uTLS (браузерные
// ClientHello включают renegotiation_info, см. 12-security-audit.md §5).

const (
	// AuthVersionV2 — версия AUTH с X25519 и MAC в AUTH_OK.
	AuthVersionV2 = 2
	// PubKeyLen — длина публичного ключа X25519.
	PubKeyLen = KeyLen
	// NonceLen — длина nonce в AUTH/AUTH_OK.
	NonceLen = 8

	authV2Len   = 2 + 8 + NonceLen + PubKeyLen + 32 // 82
	authOKV2Len = 2 + NonceLen + PubKeyLen + 32     // 74

	// AuthV2Len и AuthOKV2Len — длины кадров на проводе: по ним сервер
	// отличает AUTH v2 от v1 без отдельного согласования версии.
	AuthV2Len   = authV2Len
	AuthOKV2Len = authOKV2Len
)

var (
	ErrAuthV2     = errors.New("proto: AUTH v2 отклонён")
	authV2Label   = []byte("SHADOW1-AUTH-V2")
	authOKV2Label = []byte("SHADOW1-AUTH-OK-V2")
	sessionV2Info = "SHADOW1-SESSION-V2"
)

// NewEphemeralKeyV2 — эфемерная пара X25519 на одну сессию.
func NewEphemeralKeyV2() (*ecdh.PrivateKey, error) {
	return ecdh.X25519().GenerateKey(rand.Reader)
}

// PublicKeyV2 — 32 байта публичного ключа для провода.
func PublicKeyV2(k *ecdh.PrivateKey) []byte { return k.PublicKey().Bytes() }

// MakeAuthV2 собирает 82-байтовый AUTH v2:
// ver u16 | ts u64 | nonce 8 | clientPub 32 | tag 32,
// tag = HMAC-SHA256(psk, "SHADOW1-AUTH-V2" ‖ ver ‖ ts ‖ nonce ‖ clientPub).
func MakeAuthV2(psk, clientPub []byte, now time.Time) ([]byte, error) {
	return makeAuthV2At(psk, clientPub, now, rand.Read)
}

// makeAuthV2At — шов для детерминированного nonce в тестах.
func makeAuthV2At(psk, clientPub []byte, now time.Time, rnd func([]byte) (int, error)) ([]byte, error) {
	if len(psk) != KeyLen || len(clientPub) != PubKeyLen {
		return nil, ErrAuthV2
	}
	b := make([]byte, authV2Len)
	binary.BigEndian.PutUint16(b[0:], AuthVersionV2)
	binary.BigEndian.PutUint64(b[2:], uint64(now.Unix()))
	if _, err := rnd(b[10:18]); err != nil {
		return nil, err
	}
	copy(b[18:50], clientPub)
	tag := authV2Tag(psk, b[0:2], b[2:10], b[10:18], b[18:50])
	copy(b[50:], tag[:])
	return b, nil
}

// VerifyAuthV2 проверяет ver=2, окно ts и тег (constant-time) и возвращает
// разобранные ts, nonce и clientPub (копии — payload можно освобождать).
func VerifyAuthV2(psk, payload []byte, now time.Time) (ts uint64, nonce, clientPub []byte, err error) {
	if len(psk) != KeyLen || len(payload) != authV2Len {
		return 0, nil, nil, ErrAuthV2
	}
	if binary.BigEndian.Uint16(payload[0:]) != AuthVersionV2 {
		return 0, nil, nil, ErrAuthV2
	}
	ts = binary.BigEndian.Uint64(payload[2:])
	if !skewOK(now, ts) {
		return 0, nil, nil, ErrAuthV2
	}
	want := authV2Tag(psk, payload[0:2], payload[2:10], payload[10:18], payload[18:50])
	if !hmac.Equal(want[:], payload[50:82]) {
		return 0, nil, nil, ErrAuthV2
	}
	nonce = append([]byte(nil), payload[10:18]...)
	clientPub = append([]byte(nil), payload[18:50]...)
	return ts, nonce, clientPub, nil
}

// authV2Tag — HMAC по фиксированной раскладке: варьируемых длин нет, поэтому
// усечение/склейка полей невозможны.
func authV2Tag(psk, ver, ts, nonce, pub []byte) [32]byte {
	m := hmac.New(sha256.New, psk)
	m.Write(authV2Label)
	m.Write(ver)
	m.Write(ts)
	m.Write(nonce)
	m.Write(pub)
	var tag [32]byte
	copy(tag[:], m.Sum(nil))
	return tag
}

// MakeAuthOKV2 собирает 74-байтовый AUTH_OK v2:
// ver u16 | nonce 8 (эхо из AUTH) | serverPub 32 | tag 32,
// tag = HMAC-SHA256(psk, "SHADOW1-AUTH-OK-V2" ‖ clientPub ‖ serverPub ‖ ts ‖ nonce).
// Именно этот MAC не даёт MITM выдать себя за сервер.
func MakeAuthOKV2(psk, clientPub, serverPub, nonce []byte, ts uint64) ([]byte, error) {
	if len(psk) != KeyLen || len(clientPub) != PubKeyLen || len(serverPub) != PubKeyLen || len(nonce) != NonceLen {
		return nil, ErrAuthV2
	}
	b := make([]byte, authOKV2Len)
	binary.BigEndian.PutUint16(b[0:], AuthVersionV2)
	copy(b[2:10], nonce)
	copy(b[10:42], serverPub)
	var tsb [8]byte
	binary.BigEndian.PutUint64(tsb[:], ts)
	m := hmac.New(sha256.New, psk)
	m.Write(authOKV2Label)
	m.Write(clientPub)
	m.Write(serverPub)
	m.Write(tsb[:])
	m.Write(nonce)
	copy(b[42:], m.Sum(nil))
	return b, nil
}

// VerifyAuthOKV2 проверяет AUTH_OK v2 против того, что клиент сам отправил в AUTH
// (clientPub, ts, nonce). Несовпадение nonce-эха или тега — ErrAuthV2.
func VerifyAuthOKV2(psk, payload, clientPub, nonce []byte, ts uint64) error {
	if len(psk) != KeyLen || len(payload) != authOKV2Len || len(clientPub) != PubKeyLen || len(nonce) != NonceLen {
		return ErrAuthV2
	}
	if binary.BigEndian.Uint16(payload[0:]) != AuthVersionV2 {
		return ErrAuthV2
	}
	if !hmac.Equal(payload[2:10], nonce) {
		return ErrAuthV2
	}
	var tsb [8]byte
	binary.BigEndian.PutUint64(tsb[:], ts)
	m := hmac.New(sha256.New, psk)
	m.Write(authOKV2Label)
	m.Write(clientPub)
	m.Write(payload[10:42])
	m.Write(tsb[:])
	m.Write(nonce)
	if !hmac.Equal(m.Sum(nil), payload[42:74]) {
		return ErrAuthV2
	}
	return nil
}

// SessionKeyV2 — сессионный ключ: X25519(свой приватный, публичный пира) →
// HKDF-SHA256(salt=psk, info="SHADOW1-SESSION-V2") → 32 байта.
// Знают только двое участников — это и есть привязка AUTH к соединению.
func SessionKeyV2(psk []byte, priv *ecdh.PrivateKey, peerPub []byte) ([32]byte, error) {
	var out [32]byte
	if len(psk) != KeyLen || priv == nil || len(peerPub) != PubKeyLen {
		return out, ErrAuthV2
	}
	pub, err := ecdh.X25519().NewPublicKey(peerPub)
	if err != nil {
		return out, ErrAuthV2
	}
	shared, err := priv.ECDH(pub)
	if err != nil {
		return out, ErrAuthV2 // low-order point: X25519 отказывает
	}
	k, err := hkdf.Key(sha256.New, shared, psk, sessionV2Info, KeyLen)
	if err != nil {
		return out, ErrAuthV2
	}
	copy(out[:], k)
	return out, nil
}
TBGO_AUTH

mkdir -p "$(dirname "$src"/proto/frame.go)"
cat > "$src"/proto/frame.go <<'TBGO_FRAME'
// Package proto — кадрирование и AUTH Shadow/1 (docs/07-proto-v1-spec.md, §2 и §4).
package proto

import (
	"encoding/binary"
	"errors"
	"io"
)

// Типы кадров (§2).
const (
	TypeData   = 0x01
	TypeAck    = 0x02
	TypePad    = 0x03
	TypePing   = 0x04
	TypeWU     = 0x05
	TypeFin    = 0x06
	TypeMig    = 0x07
	TypeAuth   = 0x08
	TypeAuthOK = 0x09
	TypeClose  = 0x0A
)

// Флаги кадра (§2).
const (
	FlagOpen   = 0x01
	FlagFin    = 0x02
	FlagMore   = 0x04
	FlagUrgent = 0x08
	// FlagUDP на OPEN: поток несёт датаграммы, а не поток байт. Старый сервер
	// неизвестный бит игнорирует и попробует TCP — UDP на нём не работает,
	// поэтому клиент и сервер обновляются вместе.
	FlagUDP = 0x10
	// FlagIP на OPEN: поток несёт IP-пакеты (режим TUN). Адресного блока у
	// такого потока нет, цель выбирает стек вызывающей стороны.
	FlagIP = 0x20
)

const (
	MaxPayload = 1400
	headerLen  = 8
	maxStream  = 0x7FFF
)

var (
	ErrShortFrame = errors.New("proto: кадр короче заголовка")
	ErrLength     = errors.New("proto: length > 1400")
	ErrType       = errors.New("proto: неизвестный тип")
	ErrStream     = errors.New("proto: stream вне [0, 0x7FFF]")
	ErrBufSmall   = errors.New("proto: буфер меньше 8+1400")
)

type Header struct {
	Type, Flags uint8
	Stream      uint16
	Length      uint16
}

// MarshalTo пишет 8 байт заголовка; b должен быть >= 8.
func (h Header) MarshalTo(b []byte) {
	b = b[:headerLen]
	b[0] = h.Type
	b[1] = h.Flags
	binary.BigEndian.PutUint16(b[2:], h.Stream)
	binary.BigEndian.PutUint16(b[4:], h.Length)
	binary.BigEndian.PutUint16(b[6:], 0) // reserved
}

// ParseHeader валидирует заголовок по §2; неизвестные биты flags не ошибка.
func ParseHeader(b []byte) (Header, error) {
	if len(b) < headerLen {
		return Header{}, ErrShortFrame
	}
	h := Header{
		Type:   b[0],
		Flags:  b[1],
		Stream: binary.BigEndian.Uint16(b[2:]),
		Length: binary.BigEndian.Uint16(b[4:]),
	}
	if h.Length > MaxPayload {
		return Header{}, ErrLength
	}
	if int(h.Stream) > maxStream {
		return Header{}, ErrStream
	}
	if !knownType(h.Type) {
		return Header{}, ErrType
	}
	return h, nil
}

func knownType(t uint8) bool { return t >= TypeData && t <= TypeClose }

// ReadFrame читает кадр в buf (>= 8+MaxPayload); payload — срез buf, без аллокаций.
func ReadFrame(r io.Reader, buf []byte) (Header, []byte, error) {
	if len(buf) < headerLen+MaxPayload {
		return Header{}, nil, ErrBufSmall
	}
	if _, err := io.ReadFull(r, buf[:headerLen]); err != nil {
		return Header{}, nil, err
	}
	h, err := ParseHeader(buf[:headerLen])
	if err != nil {
		return Header{}, nil, err
	}
	p := buf[headerLen : headerLen+int(h.Length)]
	if _, err := io.ReadFull(r, p); err != nil {
		return Header{}, nil, err
	}
	return h, p, nil
}

// WriteFrame пишет кадр; Length всегда равен len(payload).
func WriteFrame(w io.Writer, h Header, payload []byte) error {
	if len(payload) > MaxPayload {
		return ErrLength
	}
	h.Length = uint16(len(payload))
	var hb [headerLen]byte
	h.MarshalTo(hb[:])
	if _, err := w.Write(hb[:]); err != nil {
		return err
	}
	if len(payload) == 0 {
		return nil
	}
	_, err := w.Write(payload)
	return err
}

// WUPayload кодирует WU: stream u16 + delta u32.
func WUPayload(stream uint16, delta uint32) [6]byte {
	var b [6]byte
	binary.BigEndian.PutUint16(b[0:], stream)
	binary.BigEndian.PutUint32(b[2:], delta)
	return b
}

func ParseWU(p []byte) (stream uint16, delta uint32, ok bool) {
	if len(p) != 6 {
		return 0, 0, false
	}
	return binary.BigEndian.Uint16(p[0:]), binary.BigEndian.Uint32(p[2:]), true
}
TBGO_FRAME

mkdir -p "$(dirname "$src"/proto/target.go)"
cat > "$src"/proto/target.go <<'TBGO_TARGET'
package proto

// Адресный блок §3: atyp + адрес + port. Общий кодек для клиента и сервера.

import (
	"errors"
	"net"
	"strconv"
)

const (
	AtypIPv4   = 1
	AtypDomain = 2
	AtypIPv6   = 3
)

var ErrTarget = errors.New("proto: битый адрес цели")

// EncodeTarget кодирует host:port в адресный блок §3.
// host — IPv4, IPv6 (без скобок) или домен; port — число или строка с числом.
func EncodeTarget(host, port string) ([]byte, error) {
	p, err := strconv.Atoi(port)
	if err != nil || p < 1 || p > 65535 {
		return nil, ErrTarget
	}
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			b := make([]byte, 0, 1+4+2)
			b = append(b, AtypIPv4)
			b = append(b, v4...)
			return append(b, byte(p>>8), byte(p)), nil
		}
		b := make([]byte, 0, 1+16+2)
		b = append(b, AtypIPv6)
		b = append(b, ip.To16()...)
		return append(b, byte(p>>8), byte(p)), nil
	}
	if len(host) == 0 || len(host) > 255 {
		return nil, ErrTarget
	}
	b := make([]byte, 0, 2+len(host)+2)
	b = append(b, AtypDomain, byte(len(host)))
	b = append(b, host...)
	return append(b, byte(p>>8), byte(p)), nil
}

// DecodeTarget разбирает адресный блок §3 в host и port.
func DecodeTarget(b []byte) (host, port string, err error) {
	if len(b) < 1 {
		return "", "", ErrTarget
	}
	var rest []byte
	switch b[0] {
	case AtypIPv4:
		if len(b) < 1+4+2 {
			return "", "", ErrTarget
		}
		host = net.IP(b[1 : 1+4]).String()
		rest = b[1+4:]
	case AtypIPv6:
		if len(b) < 1+16+2 {
			return "", "", ErrTarget
		}
		host = net.IP(b[1 : 1+16]).String()
		rest = b[1+16:]
	case AtypDomain:
		if len(b) < 2 {
			return "", "", ErrTarget
		}
		n := int(b[1])
		if n == 0 || len(b) < 2+n+2 {
			return "", "", ErrTarget
		}
		host = string(b[2 : 2+n])
		rest = b[2+n:]
	default:
		return "", "", ErrTarget
	}
	p := int(rest[0])<<8 | int(rest[1])
	if p == 0 {
		return "", "", ErrTarget
	}
	return host, strconv.Itoa(p), nil
}

// TargetLen возвращает длину адресного блока или -1, если он битый.
func TargetLen(b []byte) int {
	if _, _, err := DecodeTarget(b); err != nil {
		return -1
	}
	_, _, _ = DecodeTarget(b)
	// длина = весь блок; считаем по atyp
	switch b[0] {
	case AtypIPv4:
		return 1 + 4 + 2
	case AtypIPv6:
		return 1 + 16 + 2
	case AtypDomain:
		return 2 + int(b[1]) + 2
	}
	return -1
}
TBGO_TARGET

mkdir -p "$(dirname "$src"/cmd/shadow-bridge/main.go)"
cat > "$src"/cmd/shadow-bridge/main.go <<'TBGO_MAIN'
// shadow-bridge — продакшен-версия, BACKEND (зарубеж).
//
// Архитектура «Единый отпечаток»: эта программа НЕ делает TLS/uTLS сама —
// за неё это делает локальный Xray (тот же chain-xray, что и раньше),
// у которого outbound — protocol:"freedom" с streamSettings network:"xhttp"
// и security:"tls", fingerprint:"chrome", redirect на RELAY_DOMAIN:443/путь.
// Эта программа просто дозванивается на ЛОКАЛЬНЫЙ dokodemo-door-инбаунд
// того Xray (127.0.0.1:port) обычным TCP — байты, которые она пишет,
// Xray сам заворачивает в честный XHTTP+TLS(uTLS chrome) наружу. Снаружи
// это неотличимо от настоящего клиента Happ/Incy, потому что это буквально
// тот же код.
//
// После AUTH (PSK, AuthV2) принимает потоки от RELAY (RELAY открывает,
// здесь только принимают — см. комментарий в cmd/shadow-relay) и сама
// делает egress в интернет с той же политикой блокировки приватных
// диапазонов, что была у исходного chain-bridge.
package main

import (
	"bufio"
	"context"
	"io"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"shadow/mux"
	"shadow/proto"
)

type conf struct {
	Dial    string // локальный dokodemo-порт собственного Xray, напр. 127.0.0.1:11090
	PSKFile string
}

func loadConf(path string) (conf, error) {
	f, err := os.Open(path)
	if err != nil {
		return conf{}, err
	}
	defer f.Close()
	m := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		i := idx(line, '=')
		if i < 0 {
			continue
		}
		k, v := trim(line[:i]), trim(line[i+1:])
		if len(v) >= 2 && v[0] == '"' && v[len(v)-1] == '"' {
			v = v[1 : len(v)-1]
		}
		m[k] = v
	}
	return conf{Dial: m["dial"], PSKFile: m["psk_file"]}, nil
}
func idx(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}
func trim(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t') {
		s = s[:len(s)-1]
	}
	return s
}

type pskStore struct {
	mu   sync.RWMutex
	path string
	val  []byte
}

func (s *pskStore) load() error {
	b, err := os.ReadFile(s.path)
	if err != nil {
		return err
	}
	p, err := parsePSK(b)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.val = p
	s.mu.Unlock()
	return nil
}
func (s *pskStore) get() []byte {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.val
}
func parsePSK(b []byte) ([]byte, error) {
	s := string(trimBytes(b))
	if len(s) == 64 {
		dst := make([]byte, 32)
		n := 0
		for i := 0; i+1 < len(s); i += 2 {
			hi, e1 := hexVal(s[i])
			lo, e2 := hexVal(s[i+1])
			if e1 != nil || e2 != nil {
				return nil, &parseErr{"psk: кривой hex"}
			}
			dst[n] = hi<<4 | lo
			n++
		}
		if n != 32 {
			return nil, &parseErr{"psk: кривая длина"}
		}
		return dst, nil
	}
	if len(b) == 32 {
		return b, nil
	}
	return nil, &parseErr{"psk: нужно 32 байта или 64 hex-символа"}
}
func hexVal(c byte) (byte, error) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', nil
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, nil
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, nil
	}
	return 0, &parseErr{"bad hex"}
}

type parseErr struct{ s string }

func (e *parseErr) Error() string { return e.s }

func trimBytes(b []byte) []byte {
	for len(b) > 0 && (b[len(b)-1] == '\n' || b[len(b)-1] == '\r' || b[len(b)-1] == ' ') {
		b = b[:len(b)-1]
	}
	return b
}

// egress-политика: как у исходного chain-bridge (freedom.finalRules) —
// RFC1918/loopback/link-local/metadata блокируются.
var blockedNets []*net.IPNet

func init() {
	for _, c := range []string{
		"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
		"172.16.0.0/12", "192.0.0.0/24", "192.168.0.0/16", "198.18.0.0/15",
		"224.0.0.0/4", "240.0.0.0/4", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8",
	} {
		_, n, err := net.ParseCIDR(c)
		if err == nil {
			blockedNets = append(blockedNets, n)
		}
	}
}
func blocked(host string) bool {
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	for _, n := range blockedNets {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}

func main() {
	path := "/etc/shadow-bridge/shadow-bridge.toml"
	if len(os.Args) > 2 && os.Args[1] == "-config" {
		path = os.Args[2]
	}
	c, err := loadConf(path)
	if err != nil {
		slog.Error("config", "err", err)
		os.Exit(1)
	}
	psk := &pskStore{path: c.PSKFile}
	if err := psk.load(); err != nil {
		slog.Error("psk", "err", err)
		os.Exit(1)
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGHUP)
	go func() {
		for range sig {
			if err := psk.load(); err != nil {
				slog.Error("ротация PSK не удалась, оставлен прежний", "err", err)
			} else {
				slog.Info("PSK перечитан по SIGHUP")
			}
		}
	}()

	backoff := time.Second
	for {
		if err := runOnce(c.Dial, psk); err != nil {
			slog.Warn("сессия оборвалась", "err", err, "retry_in", backoff)
		}
		time.Sleep(backoff)
		if backoff < 30*time.Second {
			backoff *= 2
		} else {
			backoff = 30 * time.Second
		}
		if err == nil {
			backoff = time.Second
		}
	}
}

func runOnce(dial string, psk *pskStore) (err error) {
	raw, err := net.DialTimeout("tcp", dial, 10*time.Second)
	if err != nil {
		return err
	}
	if tc, ok := raw.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
	}
	s, err := mux.New(raw, mux.Config{IsClient: true, PSK: psk.get(), AuthV2: true})
	if err != nil {
		raw.Close()
		return err
	}
	defer s.Close()
	slog.Info("сессия к RELAY установлена (через локальный Xray/XHTTP)")
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 24*time.Hour)
		st, err := s.AcceptStream(ctx)
		cancel()
		if err != nil {
			return err
		}
		go handleStream(st)
	}
}

func handleStream(st *mux.Stream) {
	defer st.Close()
	host, port, err := proto.DecodeTarget(st.Target())
	if err != nil {
		return
	}
	if blocked(host) {
		return
	}
	d := net.Dialer{Timeout: 10 * time.Second}
	up, err := d.Dial("tcp", net.JoinHostPort(host, port))
	if err != nil {
		return
	}
	defer up.Close()
	if tc, ok := up.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
	}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); io.Copy(up, st) }()
	go func() { defer wg.Done(); io.Copy(st, up); up.Close() }()
	wg.Wait()
}
TBGO_MAIN
( cd "$src" && /usr/local/bin/go build -o /usr/local/bin/shadow-bridge ./cmd/shadow-bridge )

mkdir -p /etc/shadow-bridge
printf '%s' "$TPSK" > /etc/shadow-bridge/psk
chmod 600 /etc/shadow-bridge/psk
cat > /etc/shadow-bridge/shadow-bridge.toml <<EOT
dial = "127.0.0.1:21900"
psk_file = "/etc/shadow-bridge/psk"
EOT
chmod 600 /etc/shadow-bridge/shadow-bridge.toml

cat > /etc/systemd/system/shadow-bridge.service <<'EOT'
[Unit]
Description=shadow-bridge (Shadow/1 reverse dialer, через локальный chain-xray)
After=network-online.target chain-xray-local.service
Wants=network-online.target
Requires=chain-xray-local.service

[Service]
User=chainbridge
Group=chainbridge
ExecStart=/usr/local/bin/shadow-bridge -config /etc/shadow-bridge/shadow-bridge.toml
Restart=always
RestartSec=2
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/etc/shadow-bridge
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOT

systemctl daemon-reload
systemctl enable chain-xray-local shadow-bridge >/dev/null 2>&1
systemctl restart chain-xray-local
sleep 2
systemctl restart shadow-bridge
sleep 3
systemctl is-active --quiet chain-xray-local && systemctl is-active --quiet shadow-bridge
EOF

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
systemctl disable --now shadow-bridge chain-xray-local >/dev/null 2>&1 || true
rm -f /etc/systemd/system/shadow-bridge.service /etc/systemd/system/chain-xray-local.service \
  /usr/local/bin/shadow-bridge /usr/local/bin/chain-xray /usr/local/bin/chain-set-relay
rm -rf /etc/chain-bridge /etc/shadow-bridge /opt/shadow-src
userdel chainbridge >/dev/null 2>&1 || true
rm -f /etc/sysctl.d/99-relay-network-tuning.conf /etc/modules-load.d/relay-bbr.conf
systemctl daemon-reload
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

# 3x-ui на RELAY: GitHub из РФ бывает недоступен — тогда качаем через BACKEND (SOCKS поверх SSH)
xui_stage() {
  local proxy="" res rc=0
  if ! curl -fsS --max-time 12 -o /dev/null -I https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh >>"$LOG" 2>&1; then
    warn "GitHub с RELAY недоступен напрямую: 3x-ui загрузится через BACKEND (SOCKS поверх SSH)"
    if ssh "${SSH_OPTS[@]}" -O forward -D 127.0.0.1:1080 "root@$BACKEND_IP" >>"$LOG" 2>&1; then proxy="socks5h://127.0.0.1:1080"; fi
  fi
  step_run "3x-ui: загрузка установщика" env ALL_PROXY="$proxy" bash "$TMPD/xui-fetch.sh" || rc=1
  [ $rc -eq 0 ] && { step_run "3x-ui: установка (SQLite, порт $PANEL_PORT)" env ALL_PROXY="$proxy" bash "$TMPD/xui-install.sh" "$PANEL_PORT" || rc=1; }
  [ $rc -eq 0 ] && { step_run "3x-ui: запуск, панель на 127.0.0.1:$PANEL_PORT" bash "$TMPD/xui-check.sh" "$PANEL_PORT" || rc=1; }
  [ -n "$proxy" ] && { ssh "${SSH_OPTS[@]}" -O cancel -D 127.0.0.1:1080 "root@$BACKEND_IP" >>"$LOG" 2>&1 || true; }
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

# ───────────────────────── RELAY: сборка и установка shadow-relay ─────────────────────────
# shadow-relay слушает локально (SHADOW_RELAY_PORT), Xray-инбаунд TUNNEL
# (dokodemo-door+XHTTP, см. chain-inbounds.py) форвардит туда уже
# расшифрованные байты. Отдельного TLS и отдельного открытого порта наружу
# у shadow-relay нет — снаружи это тот же самый 443, тот же сертификат, что и
# у обычных пользователей.
# ── Go-toolchain (нужен только для сборки shadow-relay/shadow-bridge из исходников) ──
install_go_toolchain() {
  command -v go >/dev/null 2>&1 && go version 2>/dev/null | grep -qE 'go1\.(2[4-9]|[3-9][0-9])' && return 0
  case "$(uname -m)" in
    x86_64 | amd64) GOARCH=amd64 ;;
    aarch64 | arm64) GOARCH=arm64 ;;
    *) echo "неподдерживаемая архитектура для сборки Go: $(uname -m)" >&2; return 1 ;;
  esac
  local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  curl -fsSL --retry 3 -o "$tmp/dl.json" 'https://go.dev/dl/?mode=json' || return 1
  python3 - "$GOARCH" "$tmp/dl.json" > "$tmp/pick" <<'PY'
import json, sys
arch, path = sys.argv[1], sys.argv[2]
rels = json.load(open(path))
for r in rels:
    if not r.get("stable"):
        continue
    for f in r.get("files", []):
        if f.get("os") == "linux" and f.get("arch") == arch and f.get("kind") == "archive":
            print(f["filename"], f["sha256"])
            sys.exit(0)
sys.exit("подходящий релиз Go не найден")
PY
  read -r GOFILE GOSHA < "$tmp/pick"
  [ -n "${GOFILE:-}" ] || { echo "не удалось определить файл Go-toolchain" >&2; return 1; }
  curl -fsSL --retry 3 -o "$tmp/go.tgz" "https://go.dev/dl/$GOFILE" || return 1
  have=$(sha256sum "$tmp/go.tgz" | awk '{print $1}')
  [ "$have" = "$GOSHA" ] || { echo "контрольная сумма Go toolchain не совпала" >&2; return 1; }
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tmp/go.tgz"
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
}

relay_shadow_install() {
  install_go_toolchain || return 1
  local src=/opt/shadow-src
  mkdir -p "$src"
mkdir -p "$(dirname "$src"/go.mod)"
cat > "$src"/go.mod <<'TRGO_MOD'
module shadow

go 1.24
TRGO_MOD

mkdir -p "$(dirname "$src"/mux/mux.go)"
cat > "$src"/mux/mux.go <<'TRGO_MUXMUX'
// Package mux — мультиплексирование потоков Shadow/1: один writer-goroutine на
// батчинг кадров, один reader-goroutine на диспетчеризацию по stream.
package mux

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"io"
	"sync"
	"sync/atomic"
	"time"

	"shadow/proto"
)

const (
	winStream = 8 << 20
	winConn   = 32 << 20
	batchSize = 64 << 10
	batchWait = time.Millisecond
	pingEvery = 25 * time.Second
	pingMiss  = 3
	acceptCap = 256
	outCap    = 512
	hsTimeout = 10 * time.Second

	reasonProtocol = 0x01
	reasonClosed   = 0x02
)

var (
	ErrClosed      = errors.New("mux: сессия закрыта")
	ErrStream      = errors.New("mux: поток закрыт")
	ErrProtocol    = errors.New("mux: нарушение протокола")
	ErrHandshake   = errors.New("mux: handshake не удался")
	ErrPingTimeout = errors.New("mux: нет ответа на PING")
	ErrTarget      = errors.New("mux: битый адрес цели")
	ErrAcceptFull  = errors.New("mux: очередь accept переполнена")
	// ErrExhausted — id кончились: сессию надо переоткрыть, потоков больше не будет.
	ErrExhausted = errors.New("mux: исчерпано пространство stream id")
)

// Буферы фиксированных классов; в пул кладём указатели, чтобы Put не аллоцировал.
type frameBuf [8 + proto.MaxPayload]byte
type chunkBuf [4096]byte
type batchBuf [batchSize]byte

var (
	pFrame = sync.Pool{New: func() any { return new(frameBuf) }}
	pChunk = sync.Pool{New: func() any { return new(chunkBuf) }}
	pBatch = sync.Pool{New: func() any { return new(batchBuf) }}
)

// frame — готовый кадр (заголовок + payload) в буфере из пула.
type frame struct {
	buf *frameBuf
	n   int
}

type Config struct {
	IsClient   bool
	PSK        []byte // 32 байта
	Exporter   []byte // 32 байта из TLS
	WindowConn uint32 // 0 => 16 MiB
	// PingEvery/PingMiss задают детект мёртвой сессии: молчание дольше
	// PingEvery*PingMiss закрывает сессию. 0 => 25s/3 (75 s). Мобильному
	// клиенту нужен туже: Doze усыпляет радио, NAT забывает поток, и
	// «живая» сессия иначе висит чёрной ещё минуту после пробуждения.
	PingEvery time.Duration
	PingMiss  int
	// AuthV2 — клиент просит AUTH v2 (X25519 + MAC сервера в AUTH_OK).
	// Сервер принимает обе версии всегда и различает их по длине кадра,
	// поэтому флаг нужен только клиенту: v1-клиенты продолжают работать.
	AuthV2 bool
	// Replay — общий на процесс кэш (ts, nonce). Без него сервер заводит
	// свой на сессию, что бесполезно: AUTH в сессии бывает один раз.
	Replay *proto.ReplayCache
}

type Session struct {
	conn io.ReadWriter
	cfg  Config
	max  int // максимальный payload пира

	mu       sync.Mutex
	streams  map[uint16]*Stream
	connWin  int32
	connWait chan struct{}
	connUsed int32
	nextID   uint16

	recvWin   int32 // наше окно приёма: сколько пир вправе держать у нас в полёте
	recvTotal int32 // доставлено и ещё не прочитано приложением по всем потокам

	out     chan frame
	accept  chan *Stream
	done    chan struct{}
	writerD chan struct{}

	closeOnce sync.Once
	err       error

	replay   *proto.ReplayCache
	lastRecv atomic.Int64

	// key/hasKey — сессионный ключ AUTH v2; у v1-сессий hasKey=false.
	key    [32]byte
	hasKey bool

	pingMu    sync.Mutex
	pingNonce [8]byte

	pingEvery time.Duration // детект мёртвой сессии (cfg.PingEvery)
	pingMiss  int           // сколько PING подряд без ответа терпим
}

// keepalive resolves the session-death detector: explicit values win, zero
// means the package defaults (25 s x 3).
func (c Config) keepalive() (time.Duration, int) {
	every, miss := pingEvery, pingMiss
	if c.PingEvery > 0 {
		every = c.PingEvery
	}
	if c.PingMiss > 0 {
		miss = c.PingMiss
	}
	return every, miss
}

func New(conn io.ReadWriter, cfg Config) (*Session, error) {
	// exporter нужен только AUTH v1: v2 привязывается к X25519, а uTLS вообще
	// не отдаёт ExportKeyingMaterial, поэтому браузерный отпечаток ходит с nil.
	if len(cfg.PSK) != 32 || (!cfg.AuthV2 && len(cfg.Exporter) != 32) {
		return nil, ErrHandshake
	}
	wc := int32(winConn)
	if cfg.WindowConn != 0 {
		wc = int32(cfg.WindowConn)
	}
	s := &Session{
		conn:     conn,
		cfg:      cfg,
		max:      proto.MaxPayload,
		streams:  make(map[uint16]*Stream),
		connWin:  wc,
		recvWin:  wc,
		connWait: make(chan struct{}),
		out:      make(chan frame, outCap),
		accept:   make(chan *Stream, acceptCap),
		done:     make(chan struct{}),
		writerD:  make(chan struct{}),
	}
	s.pingEvery, s.pingMiss = cfg.keepalive()
	if cfg.IsClient {
		s.nextID = 1
	} else {
		s.nextID = 2
	}
	if err := s.handshake(); err != nil {
		return nil, err
	}
	go s.writeLoop()
	go s.readLoop()
	go s.keepalive()
	return s, nil
}

func (s *Session) handshake() error {
	type deadliner interface{ SetDeadline(time.Time) error }
	if d, ok := s.conn.(deadliner); ok {
		d.SetDeadline(time.Now().Add(hsTimeout))
		defer d.SetDeadline(time.Time{})
	}
	if s.cfg.IsClient {
		return s.authClient()
	}
	return s.authServer()
}

func (s *Session) authClient() error {
	if s.cfg.AuthV2 {
		return s.authClientV2()
	}
	p, err := proto.MakeAuth(s.cfg.PSK, s.cfg.Exporter, time.Now())
	if err != nil {
		return err
	}
	if err := proto.WriteFrame(s.conn, proto.Header{Type: proto.TypeAuth}, p); err != nil {
		return err
	}
	var buf [8 + proto.MaxPayload]byte
	h, rp, err := proto.ReadFrame(s.conn, buf[:])
	if err != nil {
		return err
	}
	if h.Type != proto.TypeAuthOK {
		return ErrHandshake
	}
	mp, wc, _, err := proto.ParseAuthOK(rp)
	if err != nil {
		return ErrHandshake
	}
	if mp > 0 && int(mp) < s.max {
		s.max = int(mp)
	}
	if wc > 0 {
		s.connWin = int32(wc)
	}
	return nil
}

// authClientV2 — AUTH v2: X25519-пара, MAC сервера в AUTH_OK. Клиент обязан
// проверить тег до первого целевого байта: иначе MITM с доверенным сертификатом
// выдаёт себя за сервер и видит цели.
func (s *Session) authClientV2() error {
	priv, err := proto.NewEphemeralKeyV2()
	if err != nil {
		return ErrHandshake
	}
	pub := proto.PublicKeyV2(priv)
	p, err := proto.MakeAuthV2(s.cfg.PSK, pub, time.Now())
	if err != nil {
		return ErrHandshake
	}
	if err := proto.WriteFrame(s.conn, proto.Header{Type: proto.TypeAuth}, p); err != nil {
		return err
	}
	var buf [8 + proto.MaxPayload]byte
	h, rp, err := proto.ReadFrame(s.conn, buf[:])
	if err != nil {
		return err
	}
	if h.Type != proto.TypeAuthOK {
		return ErrHandshake
	}
	// ts и nonce берём из своей же AUTH: сервер обязан их отразить.
	ts, nonce, _, err := proto.VerifyAuthV2(s.cfg.PSK, p, time.Now())
	if err != nil {
		return ErrHandshake
	}
	if err := proto.VerifyAuthOKV2(s.cfg.PSK, rp, pub, nonce, ts); err != nil {
		return ErrHandshake // сервер не доказал знание PSK
	}
	key, err := proto.SessionKeyV2(s.cfg.PSK, priv, rp[10:42])
	if err != nil {
		return ErrHandshake
	}
	s.key, s.hasKey = key, true
	// Лимиты пира — из AUTH_OK v2 (12-байтового разбора у v2 нет).
	if len(rp) >= proto.AuthOKV2Len {
		return nil
	}
	return ErrHandshake
}

func (s *Session) authServer() error {
	var buf [8 + proto.MaxPayload]byte
	h, p, err := proto.ReadFrame(s.conn, buf[:])
	if err != nil {
		return err
	}
	// Не-AUTH кадр — это HTTP-зонд: сайт-прикрытие живёт выше mux (§4).
	if h.Type != proto.TypeAuth {
		return ErrHandshake
	}
	// Версию различаем по длине кадра: у v2 она фиксированная и не совпадает
	// с v1, поэтому отдельное согласование не нужно и старый клиент работает.
	if len(p) == proto.AuthV2Len {
		return s.authServerV2(p)
	}
	now := time.Now()
	if err := proto.VerifyAuth(s.cfg.PSK, s.cfg.Exporter, p, now); err != nil {
		return err
	}
	ts, nonce, ok := proto.AuthPayloadTS(p)
	if !ok {
		return ErrHandshake
	}
	if s.replay == nil {
		s.replay = proto.NewReplayCache()
	}
	if s.replay.Seen(now, ts, nonce) {
		return proto.ErrAuth
	}
	okp := proto.MakeAuthOK(proto.MaxPayload, uint32(s.connWin), proto.CapUrgent)
	return proto.WriteFrame(s.conn, proto.Header{Type: proto.TypeAuthOK}, okp)
}

// authServerV2 — серверная половина AUTH v2. Проверяет MAC клиента, реплей по
// общему на процесс кэшу и отвечает AUTH_OK с собственным MAC: с этого момента
// клиент точно знает, что говорит с владельцем PSK.
func (s *Session) authServerV2(p []byte) error {
	now := time.Now()
	ts, nonce, cliPub, err := proto.VerifyAuthV2(s.cfg.PSK, p, now)
	if err != nil {
		return err
	}
	rc := s.cfg.Replay
	if rc == nil {
		rc = proto.NewReplayCache()
	}
	if rc.Seen(now, ts, nonce) {
		return proto.ErrAuth // тот же (ts, nonce) уже был: реплей
	}
	priv, err := proto.NewEphemeralKeyV2()
	if err != nil {
		return ErrHandshake
	}
	srvPub := proto.PublicKeyV2(priv)
	okp, err := proto.MakeAuthOKV2(s.cfg.PSK, cliPub, srvPub, nonce, ts)
	if err != nil {
		return ErrHandshake
	}
	if err := proto.WriteFrame(s.conn, proto.Header{Type: proto.TypeAuthOK}, okp); err != nil {
		return err
	}
	key, err := proto.SessionKeyV2(s.cfg.PSK, priv, cliPub)
	if err != nil {
		return ErrHandshake
	}
	s.key, s.hasKey = key, true
	return nil
}

// Key — сессионный ключ AUTH v2 (32 байта). ok=false для v1-сессий: там ключа нет.
func (s *Session) Key() (key [32]byte, ok bool) { return s.key, s.hasKey }

func (s *Session) Done() <-chan struct{} { return s.done }

// Close мягко：шлёт CLOSE, даёт writer'у сбросить батч и закрывает соединение.
func (s *Session) Close() error {
	s.fail(ErrClosed, reasonClosed)
	t := time.NewTimer(2 * time.Second)
	defer t.Stop()
	select {
	case <-s.writerD:
	case <-t.C:
		if c, ok := s.conn.(io.Closer); ok {
			c.Close()
		}
		// Без io.Closer writer может висеть в conn.Write вечно: не ждём его
		// дольше, но и не даём Close() висеть самому.
		select {
		case <-s.writerD:
		case <-time.After(500 * time.Millisecond):
		}
	}
	return nil
}

func (s *Session) OpenStream(ctx context.Context, target []byte) (*Stream, error) {
	return s.OpenStreamKind(ctx, target, false)
}

// OpenStreamKind открывает поток; udp помечает его как датаграммный (SOCKS5 UDP
// ASSOCIATE), сервер по этой пометке релеит UDP вместо TCP.
func (s *Session) OpenStreamKind(ctx context.Context, target []byte, udp bool) (*Stream, error) {
	flags := uint8(proto.FlagOpen)
	if udp {
		flags |= proto.FlagUDP
	}
	return s.open(ctx, target, flags)
}

// OpenTun открывает поток IP-пакетов (режим TUN): адресного блока у него нет,
// поэтому цель в OPEN не передаётся вовсе.
func (s *Session) OpenTun(ctx context.Context) (*Stream, error) {
	return s.open(ctx, nil, proto.FlagOpen|proto.FlagIP)
}

func (s *Session) open(ctx context.Context, target []byte, flags uint8) (*Stream, error) {
	if flags&proto.FlagIP == 0 {
		if n := proto.TargetLen(target); n < 0 || n != len(target) {
			return nil, ErrTarget
		}
	}
	s.mu.Lock()
	if s.isClosed() {
		s.mu.Unlock()
		return nil, s.closedErr()
	}
	id := s.nextID
	if id == 0 || id > 0x7FFF {
		s.mu.Unlock()
		return nil, ErrExhausted
	}
	s.nextID += 2
	s.mu.Unlock()

	st := s.newStream(id, append([]byte(nil), target...))
	st.udp = flags&proto.FlagUDP != 0
	st.ip = flags&proto.FlagIP != 0
	if !s.register(st) {
		return nil, ErrStream
	}
	h := proto.Header{Type: proto.TypeData, Flags: flags, Stream: id}
	if _, err := st.write(ctx, h, target); err != nil {
		s.drop(st)
		return nil, err
	}
	return st, nil
}

func (s *Session) AcceptStream(ctx context.Context) (*Stream, error) {
	select {
	case st := <-s.accept:
		return st, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-s.done:
		return nil, s.closedErr()
	}
}

func (s *Session) newStream(id uint16, target []byte) *Stream {
	return &Stream{
		s:       s,
		id:      id,
		tgt:     target,
		sendWin: winStream,
		rwake:   make(chan struct{}, 1),
		wait:    make(chan struct{}),
	}
}

func (s *Session) register(st *Stream) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.streams[st.id] != nil {
		return false
	}
	s.streams[st.id] = st
	return true
}

func (s *Session) drop(st *Stream) {
	s.mu.Lock()
	if s.streams[st.id] == st {
		delete(s.streams, st.id)
	}
	s.mu.Unlock()
}

// onStreamClose — пир сбросил поток (CLOSE с id != 0): освобождаем его и
// возвращаем окно соединения за недочитанные байты, иначе окно утекает и
// новые потоки встают навсегда.
func (s *Session) onStreamClose(id uint16, p []byte) error {
	st := s.stream(id)
	if st == nil {
		return nil // поток уже закрыт — CLOSE мог прийти на гонке
	}
	st.resetLocal(ErrStream)
	s.returnRecvWindow(st)
	return nil
}

// returnRecvWindow возвращает пиру кредит за доставленные, но не прочитанные
// байты потока: при закрытии они уже не будут прочитаны, а окно соединения
// останется занятым навсегда.
func (s *Session) returnRecvWindow(st *Stream) {
	s.mu.Lock()
	pend := st.recvPending
	st.recvPending = 0
	if s.recvTotal -= pend; s.recvTotal < 0 {
		s.recvTotal = 0
	}
	s.mu.Unlock()
	if pend > 0 {
		// Асинхронно: читающий goroutine НЕ должен блокироваться на отправке,
		// иначе забитая очередь исходящих вешает приём целиком (дедлок:
		// writer ждёт conn.Write, reader ждёт очередь).
		go func() {
			wu := proto.WUPayload(0, uint32(pend))
			s.send(proto.Header{Type: proto.TypeWU}, wu[:])
		}()
	}
}

// killStream рвёт один поток, не роняя сессию: окно за недочитанное пиру
// возвращаем, CLOSE шлём неблокирующе.
func (s *Session) killStream(st *Stream, reason byte) {
	s.returnRecvWindow(st)
	st.resetLocal(ErrProtocol)
	s.trySend(proto.Header{Type: proto.TypeClose, Stream: st.id}, []byte{reason})
}

func (s *Session) stream(id uint16) *Stream {
	s.mu.Lock()
	st := s.streams[id]
	s.mu.Unlock()
	return st
}

func (s *Session) isClosed() bool {
	select {
	case <-s.done:
		return true
	default:
		return false
	}
}

// closedErr — ошибка закрытия; s.err читается только после получения из done.
func (s *Session) closedErr() error {
	select {
	case <-s.done:
		if s.err != nil {
			return s.err
		}
		return ErrClosed
	default:
		return ErrClosed
	}
}

func (s *Session) fail(err error, reason byte) {
	s.closeOnce.Do(func() {
		s.err = err
		if f, e := s.build(proto.Header{Type: proto.TypeClose}, []byte{reason}); e == nil {
			select {
			case s.out <- f:
			default:
				pFrame.Put(f.buf)
			}
		}
		close(s.done)
	})
}

func (s *Session) build(h proto.Header, p []byte) (frame, error) {
	if len(p) > proto.MaxPayload {
		return frame{}, proto.ErrLength
	}
	fb := pFrame.Get().(*frameBuf)
	h.Length = uint16(len(p))
	h.MarshalTo(fb[:])
	copy(fb[8:], p)
	return frame{buf: fb, n: 8 + len(p)}, nil
}

// trySend — неблокирующая отправка: false, если очередь исходящих полна.
func (s *Session) trySend(h proto.Header, p []byte) bool {
	f, err := s.build(h, p)
	if err != nil {
		return true // некорректный кадр отбрасываем, очередь не занимаем
	}
	select {
	case s.out <- f:
		return true
	default:
		pFrame.Put(f.buf)
		return false
	}
}

func (s *Session) send(h proto.Header, p []byte) error {
	f, err := s.build(h, p)
	if err != nil {
		return err
	}
	select {
	case s.out <- f:
		return nil
	case <-s.done:
		pFrame.Put(f.buf)
		return s.closedErr()
	}
}

// onWU начисляет кредит, но не больше номинала окна: delta близка к 2^32
// иначе уводит окно в минус (Write виснет навсегда) или раздувает его выше
// буфера пира.
func (s *Session) onWU(id uint16, delta uint32) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if id == 0 {
		if delta == 0 || delta > winConn {
			return
		}
		s.connWin = int32(min(int64(s.connWin)+int64(delta), int64(winConn)))
		close(s.connWait)
		s.connWait = make(chan struct{})
		return
	}
	st := s.streams[id]
	if st == nil || delta == 0 || delta > winStream {
		return
	}
	st.sendWin = int32(min(int64(st.sendWin)+int64(delta), int64(winStream)))
	close(st.wait)
	st.wait = make(chan struct{})
}

func (s *Session) readLoop() {
	buf := make([]byte, 8+proto.MaxPayload)
	for {
		h, p, err := proto.ReadFrame(s.conn, buf)
		if err != nil {
			if err == io.EOF {
				err = ErrClosed
			}
			s.fail(err, reasonClosed)
			return
		}
		s.lastRecv.Store(time.Now().UnixNano())
		if err := s.handle(h, p); err != nil {
			s.fail(err, reasonProtocol)
			return
		}
	}
}

func (s *Session) handle(h proto.Header, p []byte) error {
	switch h.Type {
	case proto.TypeData:
		return s.onData(h, p)
	case proto.TypeFin:
		if st := s.stream(h.Stream); st != nil {
			st.remoteFin()
		}
		return nil
	case proto.TypeWU:
		id, delta, ok := proto.ParseWU(p)
		if !ok {
			return ErrProtocol
		}
		s.onWU(id, delta)
		return nil
	case proto.TypePing:
		if len(p) != 8 {
			return ErrProtocol
		}
		s.onPing(p)
		return nil
	case proto.TypeClose:
		if h.Stream != 0 {
			return s.onStreamClose(h.Stream, p)
		}
		s.fail(ErrClosed, reasonClosed)
		return nil
	default:
		// PAD, MIG, ACK, AUTH/AUTH_OK после handshake — игнор
		return nil
	}
}

func (s *Session) onPing(p []byte) {
	s.pingMu.Lock()
	ours := bytes.Equal(p, s.pingNonce[:])
	s.pingMu.Unlock()
	if ours {
		return
	}
	s.send(proto.Header{Type: proto.TypePing}, p)
}

func (s *Session) onData(h proto.Header, p []byte) error {
	if h.Stream == 0 {
		return ErrProtocol
	}
	fin := h.Flags&proto.FlagFin != 0
	if h.Flags&proto.FlagOpen != 0 {
		if (h.Stream%2 == 0) != s.cfg.IsClient {
			return ErrProtocol // чужая чётность (§3)
		}
		n := 0
		if h.Flags&proto.FlagIP == 0 { // у потока IP-пакетов адресного блока нет
			if n = proto.TargetLen(p); n < 0 || n != len(p) {
				return ErrProtocol
			}
		}
		st := s.newStream(h.Stream, append([]byte(nil), p[:n]...))
		st.udp = h.Flags&proto.FlagUDP != 0
		st.ip = h.Flags&proto.FlagIP != 0
		if !s.register(st) {
			// Дубль OPEN: рвём только этот id, сессию не трогаем.
			if old := s.stream(h.Stream); old != nil {
				s.killStream(old, reasonProtocol)
			}
			return nil
		}
		select {
		case s.accept <- st:
		default:
			// Очередь accept полна: отказываем одному потоку, а не всей
			// сессии — иначе 400 OPEN рвут все живые туннели.
			s.killStream(st, reasonProtocol)
			return nil
		}
		if err := st.deliver(p[n:], fin); err != nil {
			if err == ErrProtocol { // превышено окно приёма: валим сессию
				return err
			}
			if err == errAfterFin {
				s.killStream(st, reasonProtocol)
			}
		}
		return nil
	}
	st := s.stream(h.Stream)
	if st == nil {
		// Поток уже сброшен (CLOSE в пути): кадры, отправленные до CLOSE,
		// просто отбрасываем — но окно соединения за них возвращаем, иначе
		// кредит пира тает на каждом Reset. Это не нарушение протокола,
		// иначе сессия падала бы после каждого Reset.
		if n := len(p); n > 0 {
			wu := proto.WUPayload(0, uint32(n))
			s.trySend(proto.Header{Type: proto.TypeWU}, wu[:])
		}
		return nil
	}
	if err := st.deliver(p, fin); err != nil {
		switch err {
		case ErrProtocol: // превышено окно приёма: пир нарушил протокол
			return err
		case errAfterFin: // данные после чистого FIN: виноват один поток
			s.killStream(st, reasonProtocol)
		}
	}
	return nil
}

func (s *Session) writeLoop() {
	defer close(s.writerD)
	bp := pBatch.Get().(*batchBuf)
	batch := bp[:0]
	t := time.NewTimer(time.Hour)
	t.Stop()
	var tc <-chan time.Time

	flush := func() error {
		if len(batch) == 0 {
			return nil
		}
		if _, err := s.conn.Write(batch); err != nil {
			s.fail(err, reasonClosed)
			return err
		}
		batch = batch[:0]
		return nil
	}
	push := func(f frame) error {
		if len(batch)+f.n > cap(batch) {
			if err := flush(); err != nil {
				pFrame.Put(f.buf)
				return err
			}
		}
		batch = append(batch, f.buf[:f.n]...)
		pFrame.Put(f.buf)
		return nil
	}
	stopTimer := func() {
		if tc != nil {
			if !t.Stop() {
				select {
				case <-t.C:
				default:
				}
			}
			tc = nil
		}
	}

loop:
	for {
		select {
		case f := <-s.out:
			urgent := f.buf[1]&proto.FlagUrgent != 0
			if push(f) != nil {
				break loop
			}
			if urgent || len(batch) >= batchSize {
				stopTimer()
				if flush() != nil {
					break loop
				}
				continue
			}
			if tc == nil {
				t.Reset(batchWait)
				tc = t.C
			}
		case <-tc:
			tc = nil
			if flush() != nil {
				break loop
			}
		case <-s.done:
			for {
				select {
				case f := <-s.out:
					if push(f) != nil {
						break loop
					}
				default:
					flush()
					break loop
				}
			}
		}
	}
	stopTimer()
	pBatch.Put(bp)
	// соединение закрывает только writer: reader разблокируется на ошибке чтения
	if c, ok := s.conn.(io.Closer); ok {
		c.Close()
	}
}

func (s *Session) keepalive() {
	t := time.NewTimer(s.pingEvery)
	defer t.Stop()
	prev := s.lastRecv.Load()
	misses := 0
	for {
		select {
		case <-s.done:
			return
		case <-t.C:
		}
		cur := s.lastRecv.Load()
		if cur == prev {
			misses++
			if misses >= s.pingMiss {
				s.fail(ErrPingTimeout, reasonProtocol)
				return
			}
			s.ping()
		} else {
			misses = 0
		}
		prev = cur
		t.Reset(s.pingEvery)
	}
}

func (s *Session) ping() {
	var n [8]byte
	rand.Read(n[:])
	s.pingMu.Lock()
	s.pingNonce = n
	s.pingMu.Unlock()
	s.send(proto.Header{Type: proto.TypePing}, n[:])
}
TRGO_MUXMUX

mkdir -p "$(dirname "$src"/mux/stream.go)"
cat > "$src"/mux/stream.go <<'TRGO_MUXSTREAM'
package mux

import (
	"context"
	"errors"
	"io"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"shadow/proto"
)

type recvChunk struct {
	buf *chunkBuf
	n   int // записано
	off int // прочитано
}

type Stream struct {
	s   *Session
	id  uint16
	tgt []byte
	udp bool // датаграммный поток (SOCKS5 UDP ASSOCIATE)
	ip  bool // поток IP-пакетов (режим TUN)

	rmu   sync.Mutex
	rq    []recvChunk
	rhead int
	rerr  error
	rfin  bool
	rwake chan struct{} // семафор: 1 токен = «проверь очередь»

	// под rmu: дедлайн чтения. Срабатывая, он кидает токен в rwake — тот же
	// семафор, что и у данных, поэтому select в Read не подорожал.
	rdl    time.Time
	rdlGen uint64 // поколение: таймер прошлого поколения не стреляет
	rdlTmr *time.Timer

	// под s.mu
	sendWin     int32
	recvUsed    int32
	recvPending int32 // доставлено приложению, но ещё не прочитано
	wait        chan struct{}

	sfin   atomic.Bool
	urgent atomic.Bool
}

// Target — адресный блок §3, с которым поток открыт.
func (st *Stream) Target() []byte { return st.tgt }

// IsUDP — поток датаграммный (открыт с proto.FlagUDP).
func (st *Stream) IsUDP() bool { return st.udp }

// IsIP — поток несёт IP-пакеты (открыт с proto.FlagIP, режим TUN).
func (st *Stream) IsIP() bool { return st.ip }

func (st *Stream) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	st.rmu.Lock()
	for {
		if st.rhead < len(st.rq) {
			c := &st.rq[st.rhead]
			n := copy(p, c.buf[c.off:c.n])
			if n > 0 {
				c.off += n
				var done *chunkBuf
				if c.off == c.n {
					done = c.buf
					st.rq[st.rhead] = recvChunk{}
					st.rhead++
					st.compact()
				}
				drained := st.rhead == len(st.rq)
				st.rmu.Unlock()
				if done != nil {
					pChunk.Put(done)
				}
				st.consumed(n, drained)
				return n, nil
			}
		}
		if st.rerr != nil {
			err := st.rerr
			st.rmu.Unlock()
			return 0, err
		}
		// Истёкший дедлайн проверяем до блокировки: данные из очереди важнее.
		expired := st.readExpired()
		st.rmu.Unlock()
		if expired {
			return 0, os.ErrDeadlineExceeded
		}
		select {
		case <-st.rwake:
		case <-st.s.done:
			return 0, st.s.closedErr()
		}
		st.rmu.Lock()
	}
}

// readExpired (под rmu) сообщает, что дедлайн чтения истёк, и снимает его:
// следующий Read снова блокируется, а не спотыкается о мёртвый дедлайн.
func (st *Stream) readExpired() bool {
	if st.rdl.IsZero() || st.rdl.After(time.Now()) {
		return false
	}
	st.rdl = time.Time{}
	if st.rdlTmr != nil {
		st.rdlTmr.Stop()
		st.rdlTmr = nil
	}
	return true
}

// kick (под rmu) будит блокирующий Read: данные пришли или дедлайн истёк.
func (st *Stream) kick() {
	select {
	case st.rwake <- struct{}{}:
	default:
	}
}

// SetReadDeadline взводит дедлайн чтения: по его истечении блокирующий Read
// вернёт os.ErrDeadlineExceeded. Нулевое время снимает дедлайн, повторный
// вызов заменяет прежний таймер.
func (st *Stream) SetReadDeadline(t time.Time) error {
	st.rmu.Lock()
	defer st.rmu.Unlock()
	if st.rdlTmr != nil {
		st.rdlTmr.Stop()
		st.rdlTmr = nil
	}
	st.rdl = t
	st.rdlGen++
	switch d := time.Until(t); {
	case t.IsZero():
	case d <= 0:
		st.kick()
	default:
		gen := st.rdlGen
		st.rdlTmr = time.AfterFunc(d, func() {
			st.rmu.Lock()
			if st.rdlGen == gen { // таймер своего поколения: чужой не стреляет
				st.rdlTmr = nil
				st.kick()
			}
			st.rmu.Unlock()
		})
	}
	return nil
}

// WriteContext — Write, у которого ожидание окна отменяется ctx.
func (st *Stream) WriteContext(ctx context.Context, p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if st.sfin.Load() {
		return 0, ErrStream
	}
	h := proto.Header{Type: proto.TypeData, Stream: st.id}
	if st.urgent.Load() {
		h.Flags = proto.FlagUrgent
	}
	return st.write(ctx, h, p)
}

func (st *Stream) Write(p []byte) (int, error) {
	return st.WriteContext(context.Background(), p)
}

// Close — полузакрытие: FIN в свою сторону; поток освобождается после FIN пира.
func (st *Stream) Close() error {
	if st.sfin.Swap(true) {
		return nil
	}
	s := st.s
	s.mu.Lock()
	close(st.wait)
	st.wait = make(chan struct{})
	s.mu.Unlock()
	err := s.send(proto.Header{Type: proto.TypeFin, Stream: st.id}, nil)
	st.maybeFree()
	return err
}

// Reset рвёт поток: CLOSE пиру + локальная очистка. В отличие от Close (FIN),
// говорит пиру «перестань слать», поэтому освобождает окно соединения.
func (st *Stream) Reset() error {
	s := st.s
	// Байты, доставленные нам, но не прочитанные приложением, надо вернуть
	// пиру как окно — иначе его connWin утекает и он замолкает навсегда.
	err := s.send(proto.Header{Type: proto.TypeClose, Stream: st.id}, []byte{reasonClosed})
	st.resetLocal(ErrStream)
	s.returnRecvWindow(st)
	return err
}

// resetLocal помечает поток закрытым с обеих сторон и будит читателей/писателей.
func (st *Stream) resetLocal(err error) {
	s := st.s
	st.rmu.Lock()
	if st.rerr == nil {
		st.rerr = err
	}
	st.rfin = true
	st.rmu.Unlock()
	st.sfin.Store(true) // писатели выходят из reserve с ErrStream
	s.mu.Lock()
	close(st.wait)
	st.wait = make(chan struct{})
	s.mu.Unlock()
	st.kick()
	s.drop(st)
}

// SetUrgent ставит URGENT на исходящие кадры потока.
func (st *Stream) SetUrgent(on bool) { st.urgent.Store(on) }

func (st *Stream) write(ctx context.Context, h proto.Header, p []byte) (int, error) {
	written := 0
	for {
		n, err := st.reserve(ctx, len(p))
		if err != nil {
			return written, err
		}
		h.Length = uint16(n)
		if err := st.s.send(h, p[:n]); err != nil {
			st.release(n)
			return written, err
		}
		written += n
		p = p[n:]
		if len(p) == 0 {
			return written, nil
		}
	}
}

// reserve списывает окно и ждёт, если оно кончилось.
func (st *Stream) reserve(ctx context.Context, max int) (int, error) {
	s := st.s
	for {
		s.mu.Lock()
		if st.sfin.Load() {
			s.mu.Unlock()
			return 0, ErrStream
		}
		// Сессия могла умереть: кредит выдавать нельзя, иначе Write вернёт nil,
		// а кадр уйдёт в очередь мёртвого writer'а (данные потеряны молча).
		if s.isClosed() {
			s.mu.Unlock()
			return 0, s.closedErr()
		}
		// Кадр без полезной нагрузки окно не тратит — иначе write() с пустым
		// payload ждал бы кредит вечно (OPEN потока IP-пакетов, FIN).
		if max == 0 {
			s.mu.Unlock()
			return 0, nil
		}
		if st.sendWin < 0 {
			st.sendWin = 0
		}
		if s.connWin < 0 {
			s.connWin = 0
		}
		n := min(max, s.max)
		if int32(n) > st.sendWin {
			n = int(st.sendWin)
		}
		if int32(n) > s.connWin {
			n = int(s.connWin)
		}
		if n > 0 {
			st.sendWin -= int32(n)
			s.connWin -= int32(n)
			s.mu.Unlock()
			return n, nil
		}
		ch, cch := st.wait, s.connWait
		s.mu.Unlock()
		select {
		case <-ch:
		case <-cch:
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-s.done:
			return 0, s.closedErr()
		}
	}
}

func (st *Stream) release(n int) {
	s := st.s
	s.mu.Lock()
	st.sendWin += int32(n)
	s.connWin += int32(n)
	s.mu.Unlock()
}

// consumed возвращает окно пиру через WU при 1/8 расхода (§5).
func (st *Stream) consumed(n int, drained bool) {
	s := st.s
	s.mu.Lock()
	st.recvUsed += int32(n)
	st.recvPending -= int32(n)
	if st.recvPending < 0 {
		st.recvPending = 0
	}
	if s.recvTotal -= int32(n); s.recvTotal < 0 {
		s.recvTotal = 0
	}
	s.connUsed += int32(n)
	var sDelta, cDelta uint32
	// Порог 1/8 окна; при опустевшей очереди хвост отдаём раньше, но не мельче
	// 1/64 окна — иначе на каждый Read уходит кадр WU и трафик растёт впустую.
	tailMin := int32(winStream / 64)
	if st.recvUsed >= winStream/8 || (drained && st.recvUsed >= tailMin) {
		sDelta, st.recvUsed = uint32(st.recvUsed), 0
	}
	if s.connUsed >= winConn/8 || (drained && s.connUsed >= tailMin) {
		cDelta, s.connUsed = uint32(s.connUsed), 0
	}
	s.mu.Unlock()

	// consumed вызывается из Read: блокирующий send здесь останавливает приём
	// целиком. Если очередь полна — возвращаем кредит в счётчики и отдадим
	// при следующем чтении.
	if sDelta > 0 {
		p := proto.WUPayload(st.id, sDelta)
		if !s.trySend(proto.Header{Type: proto.TypeWU}, p[:]) {
			s.mu.Lock()
			st.recvUsed += int32(sDelta)
			s.mu.Unlock()
		}
	}
	if cDelta > 0 {
		p := proto.WUPayload(0, cDelta)
		if !s.trySend(proto.Header{Type: proto.TypeWU}, p[:]) {
			s.mu.Lock()
			s.connUsed += int32(cDelta)
			s.mu.Unlock()
		}
	}
}

// errAfterFin — данные после чистого FIN: рвём поток, но не сессию.
var errAfterFin = errors.New("mux: данные после FIN")

// deliver кладёт данные в очередь приёма; вызывается только reader'ом.
func (st *Stream) deliver(p []byte, fin bool) error {
	st.rmu.Lock()
	if st.rerr != nil {
		err := st.rerr
		st.rmu.Unlock()
		if err == ErrStream {
			return ErrStream // поток сброшен нами: кадр в пути — не нарушение
		}
		return errAfterFin // данные после чистого FIN — виноват только поток
	}
	if n := len(p); n > 0 {
		// под s.mu и ДО push: пир, игнорирующий окна, не должен набить
		// очередь приёма целиком (иначе одна сессия кладёт сервер по памяти).
		s := st.s
		s.mu.Lock()
		if st.recvPending+int32(n) > winStream || s.recvTotal+int32(n) > s.recvWin {
			s.mu.Unlock()
			st.rmu.Unlock()
			return ErrProtocol
		}
		st.recvPending += int32(n)
		s.recvTotal += int32(n)
		s.mu.Unlock()
		st.push(p)
	}
	if fin {
		st.rfin = true
		st.rerr = io.EOF
	}
	st.kick()
	st.rmu.Unlock()
	if fin {
		st.maybeFree()
	}
	return nil
}

func (st *Stream) push(p []byte) {
	if n := len(st.rq); n > st.rhead {
		c := &st.rq[n-1]
		if len(c.buf)-c.n >= len(p) {
			copy(c.buf[c.n:], p)
			c.n += len(p)
			return
		}
	}
	cb := pChunk.Get().(*chunkBuf)
	copy(cb[:], p)
	st.rq = append(st.rq, recvChunk{buf: cb, n: len(p)})
}

func (st *Stream) compact() {
	if st.rhead > 16 && st.rhead*2 >= len(st.rq) {
		n := copy(st.rq, st.rq[st.rhead:])
		st.rq = st.rq[:n]
		st.rhead = 0
	}
}

func (st *Stream) remoteFin() {
	st.rmu.Lock()
	if st.rfin {
		st.rmu.Unlock()
		return
	}
	st.rfin = true
	if st.rerr == nil {
		st.rerr = io.EOF
	}
	st.kick()
	st.rmu.Unlock()
	st.maybeFree()
}

func (st *Stream) maybeFree() {
	st.rmu.Lock()
	both := st.rfin && st.sfin.Load()
	st.rmu.Unlock()
	if both {
		// Поток уходит из таблицы: недочитанный кредит обязан вернуться пиру,
		// иначе connWin тает и новые потоки встают навсегда.
		st.s.returnRecvWindow(st)
		st.s.drop(st)
	}
}
TRGO_MUXSTREAM

mkdir -p "$(dirname "$src"/proto/auth.go)"
cat > "$src"/proto/auth.go <<'TRGO_AUTH'
package proto

import (
	"container/list"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"sync"
	"time"
)

const (
	AuthVersion = 1
	authLen     = 50
	AuthSkew    = 120 // секунд, §4

	// KeyLen — длина PSK и любого ключевого материала протокола.
	KeyLen = 32

	// caps в AUTH_OK
	CapUrgent   = 1 << 0
	CapDatagram = 1 << 1
	CapWeb      = 1 << 2
)

var (
	ErrAuth   = errors.New("proto: AUTH отклонён")
	ErrAuthOK = errors.New("proto: AUTH_OK битый")
	authLabel = []byte("SHADOW1-AUTH")
)

// AuthTag = HMAC-SHA256(psk, "SHADOW1-AUTH" || exporter || ver || ts || nonce)[32].
// ver и ts — big-endian, как в заголовке кадра.
// Контракт: len(psk) == len(exporter) == KeyLen. Длины проверяют MakeAuth и
// VerifyAuth; сам AuthTag копирует в 32-байтовый слот сообщения и ошибку не
// возвращает — вызывать его напрямую с другими длинами нельзя.
func AuthTag(psk, exporter []byte, ver uint16, ts uint64, nonce []byte) [32]byte {
	var msg [9 + KeyLen + 2 + 8 + 8]byte
	var nb [8]byte
	copy(nb[:], nonce)
	n := copy(msg[:], authLabel)
	n += copy(msg[n:], exporter[:min(len(exporter), KeyLen)])
	binary.BigEndian.PutUint16(msg[n:], ver)
	binary.BigEndian.PutUint64(msg[n+2:], ts)
	copy(msg[n+10:], nb[:])

	m := hmac.New(sha256.New, psk)
	m.Write(msg[:n+18])
	var tag [32]byte
	copy(tag[:], m.Sum(nil))
	return tag
}

// skewOK — |now - ts| <= AuthSkew без знаковой арифметики: разность двух uint64
// определена по модулю 2^64, поэтому ts = now+2^63 даёт разницу 2^63 > AuthSkew,
// а не MinInt64 с последующим -d (старый вариант такую метку пропускал).
func skewOK(now time.Time, ts uint64) bool {
	n := uint64(now.Unix())
	d := n - ts
	if ts > n {
		d = ts - n
	}
	return d <= AuthSkew
}

// MakeAuth собирает 50-байтовый payload AUTH с текущим ts и случайным nonce.
func MakeAuth(psk, exporter []byte, now time.Time) ([]byte, error) {
	if len(psk) != KeyLen || len(exporter) != KeyLen {
		return nil, ErrAuth
	}
	b := make([]byte, authLen)
	binary.BigEndian.PutUint16(b[0:], AuthVersion)
	ts := uint64(now.Unix())
	binary.BigEndian.PutUint64(b[2:], ts)
	if _, err := rand.Read(b[10:18]); err != nil {
		return nil, err
	}
	tag := AuthTag(psk, exporter, AuthVersion, ts, b[10:18])
	copy(b[18:], tag[:])
	return b, nil
}

// VerifyAuth проверяет ver, |now-ts| <= 120 c и тег (constant-time). Replay — ReplayCache.
func VerifyAuth(psk, exporter, payload []byte, now time.Time) error {
	if len(psk) != KeyLen || len(exporter) != KeyLen {
		return ErrAuth
	}
	if len(payload) != authLen {
		return ErrAuth
	}
	if binary.BigEndian.Uint16(payload[0:]) != AuthVersion {
		return ErrAuth
	}
	ts := binary.BigEndian.Uint64(payload[2:])
	if !skewOK(now, ts) {
		return ErrAuth
	}
	want := AuthTag(psk, exporter, AuthVersion, ts, payload[10:18])
	if !hmac.Equal(want[:], payload[18:50]) {
		return ErrAuth
	}
	return nil
}

// AuthPayloadTS разбирает ts и nonce из payload AUTH (уже проверенного VerifyAuth).
func AuthPayloadTS(payload []byte) (ts uint64, nonce []byte, ok bool) {
	if len(payload) != authLen {
		return 0, nil, false
	}
	return binary.BigEndian.Uint64(payload[2:]), payload[10:18], true
}

// AUTH_OK: ver u16, maxPayload u16, windowConn u32, caps u32.
func MakeAuthOK(maxPayload uint16, windowConn, caps uint32) []byte {
	b := make([]byte, 12)
	binary.BigEndian.PutUint16(b[0:], AuthVersion)
	binary.BigEndian.PutUint16(b[2:], maxPayload)
	binary.BigEndian.PutUint32(b[4:], windowConn)
	binary.BigEndian.PutUint32(b[8:], caps)
	return b
}

func ParseAuthOK(p []byte) (maxPayload uint16, windowConn, caps uint32, err error) {
	if len(p) != 12 || binary.BigEndian.Uint16(p[0:]) != AuthVersion {
		return 0, 0, 0, ErrAuthOK
	}
	return binary.BigEndian.Uint16(p[2:]), binary.BigEndian.Uint32(p[4:]), binary.BigEndian.Uint32(p[8:]), nil
}

const (
	replayTTL = 5 * time.Minute
	replayCap = 10000
)

type replayKey struct {
	ts    uint64
	nonce [8]byte
}

type replayEntry struct {
	k  replayKey
	at time.Time
}

// ReplayCache — LRU на (ts, nonce) с TTL 5 мин и ёмкостью 10000 (§4).
// Безопасен для конкурентного использования: живёт столько же, сколько сервер,
// и передаётся всем сессиям. Кэш на одну сессию бесполезен — AUTH в сессии
// бывает ровно один раз, повторить его негде.
type ReplayCache struct {
	mu  sync.Mutex
	ll  *list.List
	m   map[replayKey]*list.Element
	ttl time.Duration
	cap int
}

// NewReplayCache — кэш с параметрами по умолчанию (5 мин, 10000).
func NewReplayCache() *ReplayCache {
	return NewReplayCacheWith(replayTTL, replayCap)
}

// NewReplayCacheWith — кэш с явными TTL и ёмкостью; <= 0 означает дефолт.
func NewReplayCacheWith(ttl time.Duration, capacity int) *ReplayCache {
	if ttl <= 0 {
		ttl = replayTTL
	}
	if capacity <= 0 {
		capacity = replayCap
	}
	return &ReplayCache{ll: list.New(), m: make(map[replayKey]*list.Element, 64), ttl: ttl, cap: capacity}
}

// Seen сообщает, что (ts, nonce) уже видели, и запоминает пару.
func (c *ReplayCache) Seen(now time.Time, ts uint64, nonce []byte) bool {
	if len(nonce) < 8 {
		return true
	}
	var k replayKey
	k.ts = ts
	copy(k.nonce[:], nonce)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ll == nil { // нулевое значение: всё считаем реплеем, паниковать незачем
		return true
	}
	// вытесняем с головы: просроченные и лишние (порядок вставки)
	for f := c.ll.Front(); f != nil; f = c.ll.Front() {
		e := f.Value.(replayEntry)
		if len(c.m) < c.cap && now.Sub(e.at) < c.ttl {
			break
		}
		c.ll.Remove(f)
		delete(c.m, e.k)
	}
	if e, ok := c.m[k]; ok {
		c.ll.MoveToBack(e)
		return true
	}
	c.m[k] = c.ll.PushBack(replayEntry{k: k, at: now})
	return false
}

// --- AUTH v2: X25519 + MAC в обе стороны (docs/13-plan-v2.md §3) ---
//
// Зачем: в v1 сервер доказывает знание PSK только самим фактом AUTH_OK, поэтому
// MITM с доверенным клиенту сертификатом выдаёт себя за сервер. В v2 сервер
// обязан прислать MAC, клиент его проверяет, а привязка к соединению идёт через
// ECDH, а не через TLS-exporter: exporter недоступен под uTLS (браузерные
// ClientHello включают renegotiation_info, см. 12-security-audit.md §5).

const (
	// AuthVersionV2 — версия AUTH с X25519 и MAC в AUTH_OK.
	AuthVersionV2 = 2
	// PubKeyLen — длина публичного ключа X25519.
	PubKeyLen = KeyLen
	// NonceLen — длина nonce в AUTH/AUTH_OK.
	NonceLen = 8

	authV2Len   = 2 + 8 + NonceLen + PubKeyLen + 32 // 82
	authOKV2Len = 2 + NonceLen + PubKeyLen + 32     // 74

	// AuthV2Len и AuthOKV2Len — длины кадров на проводе: по ним сервер
	// отличает AUTH v2 от v1 без отдельного согласования версии.
	AuthV2Len   = authV2Len
	AuthOKV2Len = authOKV2Len
)

var (
	ErrAuthV2     = errors.New("proto: AUTH v2 отклонён")
	authV2Label   = []byte("SHADOW1-AUTH-V2")
	authOKV2Label = []byte("SHADOW1-AUTH-OK-V2")
	sessionV2Info = "SHADOW1-SESSION-V2"
)

// NewEphemeralKeyV2 — эфемерная пара X25519 на одну сессию.
func NewEphemeralKeyV2() (*ecdh.PrivateKey, error) {
	return ecdh.X25519().GenerateKey(rand.Reader)
}

// PublicKeyV2 — 32 байта публичного ключа для провода.
func PublicKeyV2(k *ecdh.PrivateKey) []byte { return k.PublicKey().Bytes() }

// MakeAuthV2 собирает 82-байтовый AUTH v2:
// ver u16 | ts u64 | nonce 8 | clientPub 32 | tag 32,
// tag = HMAC-SHA256(psk, "SHADOW1-AUTH-V2" ‖ ver ‖ ts ‖ nonce ‖ clientPub).
func MakeAuthV2(psk, clientPub []byte, now time.Time) ([]byte, error) {
	return makeAuthV2At(psk, clientPub, now, rand.Read)
}

// makeAuthV2At — шов для детерминированного nonce в тестах.
func makeAuthV2At(psk, clientPub []byte, now time.Time, rnd func([]byte) (int, error)) ([]byte, error) {
	if len(psk) != KeyLen || len(clientPub) != PubKeyLen {
		return nil, ErrAuthV2
	}
	b := make([]byte, authV2Len)
	binary.BigEndian.PutUint16(b[0:], AuthVersionV2)
	binary.BigEndian.PutUint64(b[2:], uint64(now.Unix()))
	if _, err := rnd(b[10:18]); err != nil {
		return nil, err
	}
	copy(b[18:50], clientPub)
	tag := authV2Tag(psk, b[0:2], b[2:10], b[10:18], b[18:50])
	copy(b[50:], tag[:])
	return b, nil
}

// VerifyAuthV2 проверяет ver=2, окно ts и тег (constant-time) и возвращает
// разобранные ts, nonce и clientPub (копии — payload можно освобождать).
func VerifyAuthV2(psk, payload []byte, now time.Time) (ts uint64, nonce, clientPub []byte, err error) {
	if len(psk) != KeyLen || len(payload) != authV2Len {
		return 0, nil, nil, ErrAuthV2
	}
	if binary.BigEndian.Uint16(payload[0:]) != AuthVersionV2 {
		return 0, nil, nil, ErrAuthV2
	}
	ts = binary.BigEndian.Uint64(payload[2:])
	if !skewOK(now, ts) {
		return 0, nil, nil, ErrAuthV2
	}
	want := authV2Tag(psk, payload[0:2], payload[2:10], payload[10:18], payload[18:50])
	if !hmac.Equal(want[:], payload[50:82]) {
		return 0, nil, nil, ErrAuthV2
	}
	nonce = append([]byte(nil), payload[10:18]...)
	clientPub = append([]byte(nil), payload[18:50]...)
	return ts, nonce, clientPub, nil
}

// authV2Tag — HMAC по фиксированной раскладке: варьируемых длин нет, поэтому
// усечение/склейка полей невозможны.
func authV2Tag(psk, ver, ts, nonce, pub []byte) [32]byte {
	m := hmac.New(sha256.New, psk)
	m.Write(authV2Label)
	m.Write(ver)
	m.Write(ts)
	m.Write(nonce)
	m.Write(pub)
	var tag [32]byte
	copy(tag[:], m.Sum(nil))
	return tag
}

// MakeAuthOKV2 собирает 74-байтовый AUTH_OK v2:
// ver u16 | nonce 8 (эхо из AUTH) | serverPub 32 | tag 32,
// tag = HMAC-SHA256(psk, "SHADOW1-AUTH-OK-V2" ‖ clientPub ‖ serverPub ‖ ts ‖ nonce).
// Именно этот MAC не даёт MITM выдать себя за сервер.
func MakeAuthOKV2(psk, clientPub, serverPub, nonce []byte, ts uint64) ([]byte, error) {
	if len(psk) != KeyLen || len(clientPub) != PubKeyLen || len(serverPub) != PubKeyLen || len(nonce) != NonceLen {
		return nil, ErrAuthV2
	}
	b := make([]byte, authOKV2Len)
	binary.BigEndian.PutUint16(b[0:], AuthVersionV2)
	copy(b[2:10], nonce)
	copy(b[10:42], serverPub)
	var tsb [8]byte
	binary.BigEndian.PutUint64(tsb[:], ts)
	m := hmac.New(sha256.New, psk)
	m.Write(authOKV2Label)
	m.Write(clientPub)
	m.Write(serverPub)
	m.Write(tsb[:])
	m.Write(nonce)
	copy(b[42:], m.Sum(nil))
	return b, nil
}

// VerifyAuthOKV2 проверяет AUTH_OK v2 против того, что клиент сам отправил в AUTH
// (clientPub, ts, nonce). Несовпадение nonce-эха или тега — ErrAuthV2.
func VerifyAuthOKV2(psk, payload, clientPub, nonce []byte, ts uint64) error {
	if len(psk) != KeyLen || len(payload) != authOKV2Len || len(clientPub) != PubKeyLen || len(nonce) != NonceLen {
		return ErrAuthV2
	}
	if binary.BigEndian.Uint16(payload[0:]) != AuthVersionV2 {
		return ErrAuthV2
	}
	if !hmac.Equal(payload[2:10], nonce) {
		return ErrAuthV2
	}
	var tsb [8]byte
	binary.BigEndian.PutUint64(tsb[:], ts)
	m := hmac.New(sha256.New, psk)
	m.Write(authOKV2Label)
	m.Write(clientPub)
	m.Write(payload[10:42])
	m.Write(tsb[:])
	m.Write(nonce)
	if !hmac.Equal(m.Sum(nil), payload[42:74]) {
		return ErrAuthV2
	}
	return nil
}

// SessionKeyV2 — сессионный ключ: X25519(свой приватный, публичный пира) →
// HKDF-SHA256(salt=psk, info="SHADOW1-SESSION-V2") → 32 байта.
// Знают только двое участников — это и есть привязка AUTH к соединению.
func SessionKeyV2(psk []byte, priv *ecdh.PrivateKey, peerPub []byte) ([32]byte, error) {
	var out [32]byte
	if len(psk) != KeyLen || priv == nil || len(peerPub) != PubKeyLen {
		return out, ErrAuthV2
	}
	pub, err := ecdh.X25519().NewPublicKey(peerPub)
	if err != nil {
		return out, ErrAuthV2
	}
	shared, err := priv.ECDH(pub)
	if err != nil {
		return out, ErrAuthV2 // low-order point: X25519 отказывает
	}
	k, err := hkdf.Key(sha256.New, shared, psk, sessionV2Info, KeyLen)
	if err != nil {
		return out, ErrAuthV2
	}
	copy(out[:], k)
	return out, nil
}
TRGO_AUTH

mkdir -p "$(dirname "$src"/proto/frame.go)"
cat > "$src"/proto/frame.go <<'TRGO_FRAME'
// Package proto — кадрирование и AUTH Shadow/1 (docs/07-proto-v1-spec.md, §2 и §4).
package proto

import (
	"encoding/binary"
	"errors"
	"io"
)

// Типы кадров (§2).
const (
	TypeData   = 0x01
	TypeAck    = 0x02
	TypePad    = 0x03
	TypePing   = 0x04
	TypeWU     = 0x05
	TypeFin    = 0x06
	TypeMig    = 0x07
	TypeAuth   = 0x08
	TypeAuthOK = 0x09
	TypeClose  = 0x0A
)

// Флаги кадра (§2).
const (
	FlagOpen   = 0x01
	FlagFin    = 0x02
	FlagMore   = 0x04
	FlagUrgent = 0x08
	// FlagUDP на OPEN: поток несёт датаграммы, а не поток байт. Старый сервер
	// неизвестный бит игнорирует и попробует TCP — UDP на нём не работает,
	// поэтому клиент и сервер обновляются вместе.
	FlagUDP = 0x10
	// FlagIP на OPEN: поток несёт IP-пакеты (режим TUN). Адресного блока у
	// такого потока нет, цель выбирает стек вызывающей стороны.
	FlagIP = 0x20
)

const (
	MaxPayload = 1400
	headerLen  = 8
	maxStream  = 0x7FFF
)

var (
	ErrShortFrame = errors.New("proto: кадр короче заголовка")
	ErrLength     = errors.New("proto: length > 1400")
	ErrType       = errors.New("proto: неизвестный тип")
	ErrStream     = errors.New("proto: stream вне [0, 0x7FFF]")
	ErrBufSmall   = errors.New("proto: буфер меньше 8+1400")
)

type Header struct {
	Type, Flags uint8
	Stream      uint16
	Length      uint16
}

// MarshalTo пишет 8 байт заголовка; b должен быть >= 8.
func (h Header) MarshalTo(b []byte) {
	b = b[:headerLen]
	b[0] = h.Type
	b[1] = h.Flags
	binary.BigEndian.PutUint16(b[2:], h.Stream)
	binary.BigEndian.PutUint16(b[4:], h.Length)
	binary.BigEndian.PutUint16(b[6:], 0) // reserved
}

// ParseHeader валидирует заголовок по §2; неизвестные биты flags не ошибка.
func ParseHeader(b []byte) (Header, error) {
	if len(b) < headerLen {
		return Header{}, ErrShortFrame
	}
	h := Header{
		Type:   b[0],
		Flags:  b[1],
		Stream: binary.BigEndian.Uint16(b[2:]),
		Length: binary.BigEndian.Uint16(b[4:]),
	}
	if h.Length > MaxPayload {
		return Header{}, ErrLength
	}
	if int(h.Stream) > maxStream {
		return Header{}, ErrStream
	}
	if !knownType(h.Type) {
		return Header{}, ErrType
	}
	return h, nil
}

func knownType(t uint8) bool { return t >= TypeData && t <= TypeClose }

// ReadFrame читает кадр в buf (>= 8+MaxPayload); payload — срез buf, без аллокаций.
func ReadFrame(r io.Reader, buf []byte) (Header, []byte, error) {
	if len(buf) < headerLen+MaxPayload {
		return Header{}, nil, ErrBufSmall
	}
	if _, err := io.ReadFull(r, buf[:headerLen]); err != nil {
		return Header{}, nil, err
	}
	h, err := ParseHeader(buf[:headerLen])
	if err != nil {
		return Header{}, nil, err
	}
	p := buf[headerLen : headerLen+int(h.Length)]
	if _, err := io.ReadFull(r, p); err != nil {
		return Header{}, nil, err
	}
	return h, p, nil
}

// WriteFrame пишет кадр; Length всегда равен len(payload).
func WriteFrame(w io.Writer, h Header, payload []byte) error {
	if len(payload) > MaxPayload {
		return ErrLength
	}
	h.Length = uint16(len(payload))
	var hb [headerLen]byte
	h.MarshalTo(hb[:])
	if _, err := w.Write(hb[:]); err != nil {
		return err
	}
	if len(payload) == 0 {
		return nil
	}
	_, err := w.Write(payload)
	return err
}

// WUPayload кодирует WU: stream u16 + delta u32.
func WUPayload(stream uint16, delta uint32) [6]byte {
	var b [6]byte
	binary.BigEndian.PutUint16(b[0:], stream)
	binary.BigEndian.PutUint32(b[2:], delta)
	return b
}

func ParseWU(p []byte) (stream uint16, delta uint32, ok bool) {
	if len(p) != 6 {
		return 0, 0, false
	}
	return binary.BigEndian.Uint16(p[0:]), binary.BigEndian.Uint32(p[2:]), true
}
TRGO_FRAME

mkdir -p "$(dirname "$src"/proto/target.go)"
cat > "$src"/proto/target.go <<'TRGO_TARGET'
package proto

// Адресный блок §3: atyp + адрес + port. Общий кодек для клиента и сервера.

import (
	"errors"
	"net"
	"strconv"
)

const (
	AtypIPv4   = 1
	AtypDomain = 2
	AtypIPv6   = 3
)

var ErrTarget = errors.New("proto: битый адрес цели")

// EncodeTarget кодирует host:port в адресный блок §3.
// host — IPv4, IPv6 (без скобок) или домен; port — число или строка с числом.
func EncodeTarget(host, port string) ([]byte, error) {
	p, err := strconv.Atoi(port)
	if err != nil || p < 1 || p > 65535 {
		return nil, ErrTarget
	}
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			b := make([]byte, 0, 1+4+2)
			b = append(b, AtypIPv4)
			b = append(b, v4...)
			return append(b, byte(p>>8), byte(p)), nil
		}
		b := make([]byte, 0, 1+16+2)
		b = append(b, AtypIPv6)
		b = append(b, ip.To16()...)
		return append(b, byte(p>>8), byte(p)), nil
	}
	if len(host) == 0 || len(host) > 255 {
		return nil, ErrTarget
	}
	b := make([]byte, 0, 2+len(host)+2)
	b = append(b, AtypDomain, byte(len(host)))
	b = append(b, host...)
	return append(b, byte(p>>8), byte(p)), nil
}

// DecodeTarget разбирает адресный блок §3 в host и port.
func DecodeTarget(b []byte) (host, port string, err error) {
	if len(b) < 1 {
		return "", "", ErrTarget
	}
	var rest []byte
	switch b[0] {
	case AtypIPv4:
		if len(b) < 1+4+2 {
			return "", "", ErrTarget
		}
		host = net.IP(b[1 : 1+4]).String()
		rest = b[1+4:]
	case AtypIPv6:
		if len(b) < 1+16+2 {
			return "", "", ErrTarget
		}
		host = net.IP(b[1 : 1+16]).String()
		rest = b[1+16:]
	case AtypDomain:
		if len(b) < 2 {
			return "", "", ErrTarget
		}
		n := int(b[1])
		if n == 0 || len(b) < 2+n+2 {
			return "", "", ErrTarget
		}
		host = string(b[2 : 2+n])
		rest = b[2+n:]
	default:
		return "", "", ErrTarget
	}
	p := int(rest[0])<<8 | int(rest[1])
	if p == 0 {
		return "", "", ErrTarget
	}
	return host, strconv.Itoa(p), nil
}

// TargetLen возвращает длину адресного блока или -1, если он битый.
func TargetLen(b []byte) int {
	if _, _, err := DecodeTarget(b); err != nil {
		return -1
	}
	_, _, _ = DecodeTarget(b)
	// длина = весь блок; считаем по atyp
	switch b[0] {
	case AtypIPv4:
		return 1 + 4 + 2
	case AtypIPv6:
		return 1 + 16 + 2
	case AtypDomain:
		return 2 + int(b[1]) + 2
	}
	return -1
}
TRGO_TARGET

mkdir -p "$(dirname "$src"/cmd/shadow-relay/main.go)"
cat > "$src"/cmd/shadow-relay/main.go <<'TRGO_MAIN'
// shadow-relay — продакшен-версия, RELAY (РФ).
//
// Архитектура «Единый отпечаток»: эта программа НЕ держит собственный TLS.
// TLS и XHTTP-грамматику делает Xray (тот же процесс и код, что обслуживает
// пользователей Happ/Incy). Xray's TUNNEL-инбаунд — protocol:"dokodemo-door",
// network:"xhttp" — просто форвардит уже расшифрованные сырые байты на
// 127.0.0.1:<port>, где и слушает эта программа. Снаружи для зонда это тот
// же самый 443-порт, тот же сертификат, та же XHTTP-грамматика, что и у
// обычных пользователей — отдельной открытой поверхности не появляется.
//
// На каждое входящее соединение: пикаем первые 8 байт. Похоже на Shadow
// AUTH-кадр -> поднимаем mux-сессию (PSK, AuthV2) и кладём в пул. Иначе ->
// отдаём сайт-прикрытие настоящим HTTP-ответом (200/404/405), а не просто
// держим соединение до таймаута.
//
// Пул живых сессий раздаётся локальным SOCKS5 (127.0.0.1:socks_listen), на
// который Xray заворачивает трафик пользовательского VLESS+XHTTP инбаунда
// обычным outbound-правилом routing.
package main

import (
	"bufio"
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"shadow/mux"
	"shadow/proto"
)

type conf struct {
	Listen    string // плоский TCP-адрес, который форвардит dokodemo-door (обычно 127.0.0.1:...)
	PSKFile   string
	SocksAddr string
	CoverDir  string // index.html + 404.html — обязательно для anti-probing
}

func loadConf(path string) (conf, error) {
	f, err := os.Open(path)
	if err != nil {
		return conf{}, err
	}
	defer f.Close()
	m := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		i := idx(line, '=')
		if i < 0 {
			continue
		}
		k, v := trim(line[:i]), trim(line[i+1:])
		if len(v) >= 2 && v[0] == '"' && v[len(v)-1] == '"' {
			v = v[1 : len(v)-1]
		}
		m[k] = v
	}
	c := conf{Listen: m["listen"], PSKFile: m["psk_file"], SocksAddr: m["socks_listen"], CoverDir: m["cover_dir"]}
	if c.SocksAddr == "" {
		c.SocksAddr = "127.0.0.1:11080"
	}
	return c, nil
}
func idx(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}
func trim(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t') {
		s = s[:len(s)-1]
	}
	return s
}

// pskStore — текущий PSK, перечитывается по SIGHUP без перезапуска процесса.
// Уже установленные mux-сессии продолжают жить на старом PSK (он зашит в
// их собственный AUTH, случившийся в момент установки) — ротация касается
// только новых подключений после сигнала.
type pskStore struct {
	mu   sync.RWMutex
	path string
	val  []byte
}

func (s *pskStore) load() error {
	b, err := os.ReadFile(s.path)
	if err != nil {
		return err
	}
	p, err := parsePSK(b)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.val = p
	s.mu.Unlock()
	return nil
}
func (s *pskStore) get() []byte {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.val
}
func parsePSK(b []byte) ([]byte, error) {
	s := string(trimBytes(b))
	if len(s) == 64 {
		dst := make([]byte, 32)
		n, err := decodeHex(dst, s)
		if err != nil || n != 32 {
			return nil, &parseErr{"psk: кривой hex"}
		}
		return dst, nil
	}
	if len(b) == 32 {
		return b, nil
	}
	return nil, &parseErr{"psk: нужно 32 байта или 64 hex-символа"}
}
func decodeHex(dst []byte, s string) (int, error) {
	n := 0
	for i := 0; i+1 < len(s); i += 2 {
		hi, err1 := hexVal(s[i])
		lo, err2 := hexVal(s[i+1])
		if err1 != nil || err2 != nil {
			return n, &parseErr{"bad hex"}
		}
		dst[n] = hi<<4 | lo
		n++
	}
	return n, nil
}
func hexVal(c byte) (byte, error) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', nil
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, nil
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, nil
	}
	return 0, &parseErr{"bad hex digit"}
}

type parseErr struct{ s string }

func (e *parseErr) Error() string { return e.s }

func trimBytes(b []byte) []byte {
	for len(b) > 0 && (b[len(b)-1] == '\n' || b[len(b)-1] == '\r' || b[len(b)-1] == ' ') {
		b = b[:len(b)-1]
	}
	return b
}

// ---- пул mux-сессий ----

type pool struct {
	mu   sync.Mutex
	ss   []*mux.Session
	next int
}

func (p *pool) add(s *mux.Session) {
	p.mu.Lock()
	p.ss = append(p.ss, s)
	n := len(p.ss)
	p.mu.Unlock()
	slog.Info("мост подключён", "total", n)
	go func() {
		<-s.Done()
		p.mu.Lock()
		for i, x := range p.ss {
			if x == s {
				p.ss = append(p.ss[:i], p.ss[i+1:]...)
				break
			}
		}
		n := len(p.ss)
		p.mu.Unlock()
		slog.Info("сессия моста завершена", "total", n)
	}()
}
func (p *pool) pick() *mux.Session {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.ss) == 0 {
		return nil
	}
	p.next %= len(p.ss)
	s := p.ss[p.next]
	p.next++
	return s
}

// ---- сайт-прикрытие ----

type coverSite struct{ index, notFound []byte }

func loadCover(dir string) (coverSite, error) {
	var c coverSite
	var err error
	if c.index, err = os.ReadFile(dir + "/index.html"); err != nil {
		return c, err
	}
	if c.notFound, err = os.ReadFile(dir + "/404.html"); err != nil {
		return c, err
	}
	return c, nil
}
func (c coverSite) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		body, code := c.notFound, http.StatusNotFound
		if r.URL.Path == "/" || r.URL.Path == "/index.html" {
			body, code = c.index, http.StatusOK
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.WriteHeader(code)
		w.Write(body)
	})
}

type oneConn struct {
	c  net.Conn
	a  net.Addr
	mu sync.Mutex
}

func (l *oneConn) Accept() (net.Conn, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.c == nil {
		return nil, net.ErrClosed
	}
	c := l.c
	l.c = nil
	return c, nil
}
func (l *oneConn) Close() error   { return nil }
func (l *oneConn) Addr() net.Addr { return l.a }

type peeked struct {
	net.Conn
	r *bufio.Reader
}

func (c *peeked) Read(p []byte) (int, error) { return c.r.Read(p) }

func shadowFrame(b []byte) bool {
	if len(b) < 8 || b[0] != proto.TypeAuth {
		return false
	}
	_, err := proto.ParseHeader(b)
	return err == nil
}

func main() {
	path := "/etc/shadow-relay/shadow-relay.toml"
	if len(os.Args) > 2 && os.Args[1] == "-config" {
		path = os.Args[2]
	}
	c, err := loadConf(path)
	if err != nil {
		slog.Error("config", "err", err)
		os.Exit(1)
	}
	psk := &pskStore{path: c.PSKFile}
	if err := psk.load(); err != nil {
		slog.Error("psk", "err", err)
		os.Exit(1)
	}
	cover, err := loadCover(c.CoverDir)
	if err != nil {
		slog.Error("cover_dir обязателен для anti-probing", "err", err)
		os.Exit(1)
	}
	httpSrv := &http.Server{Handler: cover.handler()}

	// SIGHUP — перечитать PSK без рестарта (существующие мосты не рвутся).
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGHUP)
	go func() {
		for range sig {
			if err := psk.load(); err != nil {
				slog.Error("ротация PSK не удалась, оставлен прежний", "err", err)
			} else {
				slog.Info("PSK перечитан по SIGHUP")
			}
		}
	}()

	p := &pool{}

	ln, err := net.Listen("tcp", c.Listen)
	if err != nil {
		slog.Error("listen", "err", err)
		os.Exit(1)
	}
	slog.Info("shadow-relay слушает (за dokodemo-door+XHTTP, без своего TLS)", "addr", c.Listen)

	go acceptLoop(ln, psk, p, httpSrv)
	runSocks(c.SocksAddr, p)
}

func acceptLoop(ln net.Listener, psk *pskStore, p *pool, httpSrv *http.Server) {
	for {
		raw, err := ln.Accept()
		if err != nil {
			slog.Error("accept", "err", err)
			continue
		}
		go func() {
			br := bufio.NewReaderSize(raw, 1<<12)
			raw.SetReadDeadline(time.Now().Add(8 * time.Second))
			hdr, err := br.Peek(8)
			if err != nil {
				raw.Close()
				return
			}
			raw.SetReadDeadline(time.Time{})
			conn := &peeked{Conn: raw, r: br}

			if shadowFrame(hdr) {
				s, err := mux.New(conn, mux.Config{IsClient: false, PSK: psk.get(), AuthV2: true})
				if err == nil {
					p.add(s)
					return
				}
				slog.Debug("похоже на Shadow, но AUTH не сошёлся", "err", err)
			}
			httpSrv.Serve(&oneConn{c: conn, a: raw.LocalAddr()})
		}()
	}
}

func runSocks(addr string, p *pool) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		slog.Error("socks listen", "err", err)
		os.Exit(1)
	}
	slog.Info("SOCKS5 для Xray-outbound слушает", "addr", addr)
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go handleSocks(c, p)
	}
}

func handleSocks(c net.Conn, p *pool) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(15 * time.Second))
	buf := make([]byte, 262)
	if _, err := io.ReadFull(c, buf[:2]); err != nil || buf[0] != 0x05 {
		return
	}
	n := int(buf[1])
	if _, err := io.ReadFull(c, buf[:n]); err != nil {
		return
	}
	c.Write([]byte{0x05, 0x00})
	if _, err := io.ReadFull(c, buf[:4]); err != nil || buf[0] != 0x05 || buf[1] != 0x01 {
		c.Write([]byte{0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	var host string
	switch buf[3] {
	case 0x01:
		if _, err := io.ReadFull(c, buf[:4]); err != nil {
			return
		}
		host = net.IP(buf[:4]).String()
	case 0x03:
		if _, err := io.ReadFull(c, buf[:1]); err != nil {
			return
		}
		l := int(buf[0])
		if _, err := io.ReadFull(c, buf[:l]); err != nil {
			return
		}
		host = string(buf[:l])
	case 0x04:
		if _, err := io.ReadFull(c, buf[:16]); err != nil {
			return
		}
		host = net.IP(buf[:16]).String()
	default:
		return
	}
	if _, err := io.ReadFull(c, buf[:2]); err != nil {
		return
	}
	port := strconv.Itoa(int(buf[0])<<8 | int(buf[1]))

	s := p.pick()
	if s == nil {
		c.Write([]byte{0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	target, err := proto.EncodeTarget(host, port)
	if err != nil {
		c.Write([]byte{0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	st, err := s.OpenStream(ctx, target)
	if err != nil {
		c.Write([]byte{0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	defer st.Close()
	c.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
	c.SetDeadline(time.Time{})

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); io.Copy(st, c); st.Close() }()
	go func() { defer wg.Done(); io.Copy(c, st) }()
	wg.Wait()
}
TRGO_MAIN
  ( cd "$src" && /usr/local/bin/go build -o /usr/local/bin/shadow-relay ./cmd/shadow-relay ) || return 1

  mkdir -p /etc/shadow-relay
  if [ ! -s /etc/shadow-relay/psk ]; then
    openssl rand -hex 32 > /etc/shadow-relay/psk
  fi
  chmod 600 /etc/shadow-relay/psk

  local cover="/var/www/honeypot/$DOMAIN"
  cat > /etc/shadow-relay/shadow-relay.toml <<EOT
listen = "127.0.0.1:$CHAIN_SHADOW_RELAY_PORT"
psk_file = "/etc/shadow-relay/psk"
socks_listen = "127.0.0.1:$CHAIN_SHADOW_SOCKS_PORT"
cover_dir = "$cover"
EOT
  chmod 600 /etc/shadow-relay/shadow-relay.toml

  cat > /etc/systemd/system/shadow-relay.service <<'EOT'
[Unit]
Description=shadow-relay (Shadow/1 reverse acceptor, behind dokodemo-door+XHTTP)
After=network-online.target
Wants=network-online.target
Before=x-ui.service

[Service]
Type=simple
ExecStart=/usr/local/bin/shadow-relay -config /etc/shadow-relay/shadow-relay.toml
Restart=always
RestartSec=2
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/etc/shadow-relay
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOT
  systemctl daemon-reload
  systemctl enable --now shadow-relay >/dev/null 2>&1
  sleep 1
  systemctl is-active --quiet shadow-relay
}

# инбаунды и маршрутизация в 3x-ui; результат: CHAIN_USER_ID, CHAIN_SUB_ID, TUNNEL_OBFS
# ВАЖНО: step_run запускает команду в подоболочке, поэтому переменные оттуда не возвращаются —
# результат передаётся через файл $TMPD/chain.env, который родительский процесс читает (chain_load)
chain_inbounds() {
  local out cu sb to
  [ -n "${xt:-}" ] || return 1
  out=$(python3 "$TMPD/chain-inbounds.py" "http://127.0.0.1:$PANEL_PORT/${xw#/}" "$xt" "$DOMAIN" "$USER_PATH" "$TUNNEL_PATH" "$CHAIN_USER_PORT" "$CHAIN_TUNNEL_PORT" "$CHAIN_SHADOW_RELAY_PORT" "$CHAIN_SHADOW_SOCKS_PORT" "${TUNNEL_OBFS:-0}" 2>>"$LOG") || return 1
  cu=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["user_id"])') || return 1
  sb=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sub_id"])') || return 1
  to=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tunnel_obfs"])') || return 1
  [ -n "$cu" ] || return 1
  ( umask 077; printf 'CHAIN_USER_ID=%q\nCHAIN_SUB_ID=%q\nTUNNEL_OBFS=%q\n' "$cu" "$sb" "$to" > "$TMPD/chain.env" )
}
chain_load() {  # читает результат chain_inbounds в переменные родительского процесса
  [ -s "$TMPD/chain.env" ] || return 1
  # shellcheck disable=SC1091
  . "$TMPD/chain.env"
  [ -n "${CHAIN_USER_ID:-}" ]
}

# мост BACKEND: установка и запуск. Секрет между shadow-relay и shadow-bridge — SHADOW_PSK
# (не VLESS UUID: туннельный инбаунд теперь dokodemo-door, у него нет понятия клиента)
backend_bridge() {
  rscript "$TMPD/bridge-install.sh" "$RELAY_IP" "$DOMAIN" "$TUNNEL_PATH" "$SHADOW_PSK" "${TUNNEL_OBFS:-0}"
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
    USER_PATH=""; TUNNEL_PATH=""; SHADOW_PSK=""   # новая установка — новые секретные пути
  fi
}

# ───────────────────────── настройка цепочки ─────────────────────────
run_install() {
  INSTALL_KIND="chain"
  STEP=0; TOTAL=12
  check_reinstall
  STEP=0; TOTAL=12
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
  SHADOW_PSK="${SHADOW_PSK:-$(openssl rand -hex 32)}"   # 32 байта — секрет Shadow-уровня между shadow-relay и shadow-bridge

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
  kv "Tunnel" "BACKEND → RELAY:443, TLS 1.3, отпечаток Chrome, dokodemo-door+XHTTP (та же грамматика, что у пользователей) → shadow-relay/shadow-bridge (Shadow/1, PSK-AUTH, без второго TLS)"
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

  # [3] сеть
  section "Сетевая оптимизация (RELAY и BACKEND)"
  step_run "RELAY: BBR, буферы TCP/UDP, MTU probing, keepalive" tune_network || warn "твики на RELAY применены не полностью"
  step_run "BACKEND: BBR, буферы TCP/UDP, MTU probing, keepalive" rscript "$TMPD/tune.sh" || warn "твики на BACKEND применены не полностью"

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
  info "Публичный сайт: https://$DOMAIN/ (+ эндпоинты: $EP_LIST)"
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
  step_run "shadow-relay: сборка из исходников (Go) и запуск (анти-probing, SOCKS для Xray)" relay_shadow_install || die "не удалось собрать/запустить shadow-relay (см. лог)"
  step_run "3x-ui: инбаунд пользователей (VLESS+XHTTP), инбаунд туннеля (dokodemo-door+XHTTP), маршрутизация" chain_inbounds || die "не удалось настроить 3x-ui через API (см. лог)"
  chain_load || die "3x-ui не вернул идентификаторы инбаундов (см. лог)"
  save_conf
  step_run "nginx: сертификат, секретные пути, «живые» эндпоинты, автопродление (панель: $([ $HIDE_PANEL -eq 1 ] && echo скрыта || echo опубликована))" python3 "$TMPD/nginx-final.py" "$DOMAIN" "$xw" "$USER_PATH" "$TUNNEL_PATH" "$CHAIN_USER_PORT" "$CHAIN_TUNNEL_PORT" "$BACKEND_IP" "$HIDE_PANEL" || die "не удалось включить финальный конфиг nginx"
  /usr/local/bin/sync-sub-path >>"$LOG" 2>&1 || true
  step_run "Перезапуск 3x-ui (применение маршрутизации)" bash -c 'systemctl restart x-ui && sleep 4 && systemctl is-active --quiet x-ui' || warn "x-ui не перезапустился"

  # [10] мост на BACKEND
  section "BACKEND: мост Xray"
  step_run "Установка Xray и shadow-bridge (проверка SHA-256) и запуск моста" backend_bridge || die "мост не запустился (journalctl -u chain-xray-local -u shadow-bridge на BACKEND)"

  # [11] проверка цепочки
  section "Проверка цепочки"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    [ "$(tunnel_conns)" -ge 1 ] && break
    sleep 2
  done
  if [ "$(tunnel_conns)" -ge 1 ]; then ok "мост подключился к RELAY (туннельный путь, HTTP/2)"; else warn "мост пока не подключился: проверьте journalctl -u chain-xray-local -u shadow-bridge на BACKEND"; fi
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
    fail "трафик через цепочку не проходит (ответа нет). Диагностика: chain-test на RELAY; journalctl -u shadow-bridge -n 50 на BACKEND"
    CHECK_FAIL=1
  else
    warn "выходной IP цепочки отличается от внешнего IP BACKEND (общий NAT или несколько адресов); если у клиента интернет работает, это не ошибка"
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
    echo "ShadowRat v$VERSION — $(date '+%F %T')"
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
  if [ $HIDE_PANEL -eq 1 ]; then printf '  Доступ:    %sтолько через SSH-туннель (из интернета панель недоступна)%s\n' "$B" "$R"; else printf '  URL:       %s%s%s\n' "$B" "$panel_url" "$R"; fi
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
  echo "   BACKEND:"
  echo "     chain-set-relay IP           указать новый IP RELAY и перезапустить мост (chain-xray-local)"
  echo "     systemctl status shadow-bridge chain-xray-local, journalctl -u shadow-bridge -u chain-xray-local   состояние и журнал моста"
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

# ───────────────────────── откат ─────────────────────────
backend_uninstall() {
  local rc=0
  rscript "$TMPD/uninstall-backend.sh" || rc=$?
  bk "rm -f '$MARKER_FILE'" || true
  return $rc
}

relay_uninstall() {  # relay_uninstall rm_xui rm_web
  local rm_xui="$1" rm_web="$2" d="${DOMAIN:-$(marker_get DOMAIN)}"
  systemctl disable --now chain-site-refresh.timer sync-sub-path.timer shadow-relay >/dev/null 2>&1 || true
  rm -rf /var/lib/chain /etc/shadow-relay /opt/shadow-src
  rm -f /etc/systemd/system/shadow-relay.service /usr/local/bin/shadow-relay /etc/chain-site.endpoints
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
  info "мост shadow-bridge, локальный chain-xray-local и команда chain-set-relay"
  info "сетевые настройки (BBR, буферы TCP); firewall остаётся закрытым, только SSH"
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
  info "служебные команды chain-status, chain-test, chain-set-backend, chain-site-refresh, sync-sub-path и их таймеры; shadow-relay"
  info "сетевые настройки (BBR, буферы TCP)"
  if [ "$scope" = 1 ]; then
    echo "  ${B}BACKEND${R}: не затрагивается"
  elif [ $reach -eq 1 ]; then
    echo "  ${B}BACKEND${R} ($BACKEND_IP):"
    info "мост shadow-bridge, локальный chain-xray-local и команда chain-set-relay"
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
  menu
  case "$MODE" in
    prepare) run_prepare ;;
    install) run_install ;;
    uninstall) do_uninstall ;;
  esac
}

if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
