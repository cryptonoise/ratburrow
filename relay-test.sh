#!/usr/bin/env bash
# relay-test.sh — диагностика задержек, потерь пакетов и состояния сети. Запускается на КЛИЕНТЕ (macOS или Linux).
#
# Что делает: спрашивает IP relay (обязательно) и IP backend (если нужен), затем с клиента меряет пинг и потери
# до своего шлюза, контрольных адресов (Google, Яндекс), relay и backend, строит маршруты (mtr),
# проверяет MTU пути, время TCP/TLS-соединений и сравнивает счётчики сетевой карты и TCP до/после теста.
# Каждая команда показана в отчёте вместе с выводом. Отчёт выводится только в консоль, файл не создаётся.
#
# Запуск:  curl -fsSL https://raw.githubusercontent.com/cryptonoise/ratburrow/refs/heads/main/relay-test.sh | sudo bash
#
# Совместимость: скрипт работает в bash 3.2 (стандартный bash на macOS), поэтому без ассоциативных массивов.

RT_VERSION="2.2"
set -o pipefail

# ───────────────────────── система ─────────────────────────
OS=$(uname -s); IS_MAC=0; [ "$OS" = "Darwin" ] && IS_MAC=1
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1
if [ $IS_MAC -eq 1 ]; then
  export PATH="$PATH:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin"   # сюда Homebrew ставит mtr
fi
# одинаковая работа с кириллицей и десятичной точкой независимо от локали
if locale -a 2>/dev/null | grep -qix 'C.UTF-8'; then export LC_ALL=C.UTF-8
elif locale -a 2>/dev/null | grep -qi '^en_US.utf-\?8$'; then export LC_ALL=en_US.UTF-8
else export LC_ALL=C; fi

# ───────────────────────── настройки ─────────────────────────
RELAY_IP=""             # IP или имя RELAY (вводится после запуска, обязательно)
BACKEND_IP=""           # IP или имя BACKEND (вводится после запуска, необязательно)
COUNT=100               # сколько ICMP-пакетов слать на каждую цель
MTR_COUNT=150           # сколько циклов mtr на каждую цель
AUTO_INSTALL=1          # ставить недостающие пакеты (apt-get на Linux, brew на macOS)
PING_I=0.2              # интервал между пакетами, с

if [ $IS_MAC -eq 1 ]; then PING_W=2000; PING_DF="-D"; else PING_W=2; PING_DF="-M do"; fi   # -W: на macOS в мс, на Linux в секундах
if [ $IS_MAC -eq 1 ] && [ $IS_ROOT -eq 0 ]; then PING_I=1; COUNT=30; fi                     # macOS: интервал меньше 1 с только от root

TMO=""; have_t() { command -v "$1" >/dev/null 2>&1; }
have_t timeout && TMO="timeout"; have_t gtimeout && TMO="gtimeout"                          # на macOS timeout есть только в coreutils

# ───────────────────────── оформление ─────────────────────────
if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'
else
  B=""; D=""; R=""; RED=""; GRN=""; YLW=""; CYN=""
fi
FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)                                                          # кадры брайлевской анимации
GRAD=(39 45 51 50 49 48 78 114 150 186 222 216 210 204 198 199 165 129 93 63)          # градиент: от голубого к розовому

# текст с переливающимся градиентом (только ASCII, чтобы не резать многобайтовые символы)
grad_text() {
  local s="$1" i n=${#1} out=""
  if [ ! -t 1 ]; then printf '%s' "$s"; return; fi
  for ((i = 0; i < n; i++)); do out+=$'\033[38;5;'"${GRAD[i * ${#GRAD[@]} / n]}"'m'"${s:i:1}"; done
  printf '%s%s' "$out" "$R"
}

TMPD=$(mktemp -d /tmp/relay-test.XXXXXX) || { echo "не удалось создать временный каталог"; exit 1; }

cleanup() { local p; for p in $(jobs -p 2>/dev/null); do kill "$p" 2>/dev/null; done; rm -rf "$TMPD"; [ -t 1 ] && printf '\033[?25h'; return 0; }
trap cleanup EXIT
trap 'echo; echo "прервано"; exit 130' INT TERM

emit()    { printf '%s\n' "$*"; }
section() { emit ""; emit "${B}${CYN}━━ $* ━━${R}"; }
have()    { command -v "$1" >/dev/null 2>&1; }

# ───────────────────────── запуск команд с анимацией ─────────────────────────
# брайлевский «спиннер» с переливающимся цветом, пока жив процесс $1
spin() {
  local pid=$1 msg=$2 i=0 t0=$SECONDS
  printf '\033[?25l'
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[K  \033[38;5;%sm%s\033[0m %s \033[2m%s с\033[0m' "${GRAD[i % ${#GRAD[@]}]}" "${FRAMES[i % ${#FRAMES[@]}]}" "$msg" "$((SECONDS - t0))"
    i=$((i + 1)); sleep 0.08
  done
  printf '\r\033[K\033[?25h'
}

show_out() {   # вывод файла в отчёт (не больше 150 строк)
  local f="$1" n=0 l
  while IFS= read -r l || [ -n "$l" ]; do
    n=$((n + 1)); [ $n -le 150 ] && emit "    ${l%$'\r'}"
  done <"$f"
  [ $n -eq 0 ] && emit "    ${D}(нет вывода)${R}"
  [ $n -gt 150 ] && emit "    ${D}… ещё $((n - 150)) строк опущены${R}"
  return 0
}

RT_N=0; RT_OUT=""; RT_RC=0; RT_SEC=0
# run "описание" "команда" ["как показать команду в отчёте"] — команда выполняется под анимацией, вывод идёт в отчёт
run() {
  local desc="$1" cmd="$2" shown="${3:-$2}" t0=$SECONDS pid
  RT_N=$((RT_N + 1)); RT_OUT="$TMPD/out.$RT_N"
  ( eval "$cmd" ) >"$RT_OUT" 2>&1 </dev/null &
  pid=$!
  [ -t 1 ] && spin "$pid" "$desc"
  wait "$pid"; RT_RC=$?
  RT_SEC=$((SECONDS - t0))
  emit ""
  emit "${B}▶ ${desc}${R}"
  emit "${D}  \$ ${shown}${R}"
  show_out "$RT_OUT"
  if [ "$RT_RC" -eq 0 ]; then emit "  ${GRN}✔${R} ${D}выполнено за ${RT_SEC} с${R}"; else emit "  ${YLW}▲${R} ${D}код возврата ${RT_RC}, ${RT_SEC} с${R}"; fi
  return 0
}

# ───────────────────────── ввод адресов ─────────────────────────
# ввод идёт с терминала (/dev/tty), поэтому работает и при запуске через «curl ... | sudo bash»
ask_host() {   # ask_host "что спрашиваем" ИМЯ_ПЕРЕМЕННОЙ ОБЯЗАТЕЛЬНО(1/0)
  local q="$1" var="$2" req="${3:-0}" a hint
  if [ "$req" = "1" ]; then hint="обязательно"; else hint="Enter — пропустить"; fi
  while true; do
    printf '  %s%s%s %s(%s)%s: ' "$B" "$q" "$R" "$D" "$hint" "$R"
    IFS= read -r a </dev/tty || { echo; echo "ввод прерван"; exit 1; }
    a="${a//[[:space:]]/}"
    if [ -z "$a" ]; then
      if [ "$req" = "1" ]; then echo "  ${YLW}▲${R} этот адрес обязателен, введите IP или имя хоста"; continue; fi
      printf -v "$var" '%s' ""; return 0
    fi
    if [[ "$a" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then printf -v "$var" '%s' "$a"; return 0; fi
    echo "  ${RED}недопустимый адрес${R}, введите IP или имя хоста ещё раз"
  done
}

# ───────────────────────── разбор результатов ─────────────────────────
num_ok() { [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
fgt()    { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }   # a >= b (числа с точкой)

# пинг: результаты складываются в массивы P_*
P_NAME=(); P_ADDR=(); P_LOSS=(); P_MIN=(); P_AVG=(); P_MAX=(); P_MDEV=()
ping_target() {   # ping_target имя адрес
  local name="$1" ip="$2" loss mn av mx md line
  run "Пинг: $name ($ip), $COUNT пакетов с интервалом $PING_I с" "ping -n -c $COUNT -i $PING_I -W $PING_W -q $ip"
  loss=$(grep -oE '[0-9.]+% packet loss' "$RT_OUT" | grep -oE '^[0-9.]+')
  line=$(sed -n 's/.*= \([0-9.]*\)\/\([0-9.]*\)\/\([0-9.]*\)\/\([0-9.]*\) ms.*/\1 \2 \3 \4/p' "$RT_OUT" | head -n1)
  read -r mn av mx md <<<"$line"
  P_NAME+=("$name"); P_ADDR+=("$ip"); P_LOSS+=("${loss:--}"); P_MIN+=("${mn:--}"); P_AVG+=("${av:--}"); P_MAX+=("${mx:--}"); P_MDEV+=("${md:--}")
}

verdict() {   # verdict потери% → слово для таблицы
  local l="$1"
  if ! num_ok "$l"; then echo "н/д"
  elif fgt "$l" 99; then echo "нет ответа"
  elif fgt "$l" 2; then echo "ПЛОХО"
  elif fgt "$l" 0.5; then echo "ВНИМАНИЕ"
  else echo "ОК"; fi
}

# mtr: ищет хоп, с которого потери ≥2% сохраняются до самой цели (одиночные хопы, режущие ICMP, не в счёт)
mtr_analyze() {   # статус|потери_на_цели|хоп|адрес_хопа|потери_хопа|адрес_цели
  awk '
    { loss = ""
      for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+(\.[0-9]+)?%$/) { loss = $i; host = $(i - 1); break }
      if (loss == "") next
      sub(/%/, "", loss); hop = $1; gsub(/[^0-9]/, "", hop)
      n++; H[n] = hop; A[n] = host; L[n] = loss + 0 }
    END {
      if (!n) { print "none|||||"; exit }
      fin = L[n]
      if (fin >= 99) { printf "blocked|%s|||%s|%s\n", fin, L[n], A[n]; exit }
      j = n; while (j >= 1 && L[j] >= 2) j--
      s = j + 1
      if (s > n) { printf "ok|%s|||%s|%s\n", fin, "", A[n]; exit }
      printf "loss|%s|%s|%s|%s|%s\n", fin, H[s], A[s], L[s], A[n]
    }' "$1"
}
M_NAME=(); M_RES=()
mtr_target() {   # mtr_target имя адрес
  local name="$1" ip="$2" args="-c 30" res
  [ $IS_ROOT -eq 1 ] && args="-i 0.2 -c $MTR_COUNT"
  run "Маршрут (mtr): $name ($ip)" "${TMO:+$TMO 240 }mtr -rwn $args $ip" "mtr -rwn $args $ip"
  res=$(mtr_analyze "$RT_OUT")
  M_NAME+=("$name"); M_RES+=("$res")
}

# ───────────────────────── счётчики до/после ─────────────────────────
# значения лежат в переменных C0_<имя> («до») и C1_<имя> («после»)
num0()   { if [[ "${1:-}" =~ ^[0-9]+$ ]]; then echo "$1"; else echo 0; fi; }
setv()   { printf -v "$1" '%s' "$(num0 "${2:-}")"; }
snmp_val() { awk -v p="$1:" -v k="$2" '$1 == p { if (!h) { for (i = 2; i <= NF; i++) c[$i] = i; h = 1 } else { print $(c[k]); exit } }' /proc/net/snmp; }
snap() {   # snap ПРЕФИКС (C0 или C1): снимок счётчиков интерфейса и TCP/UDP
  local p=$1 f tcp udp
  if [ $IS_MAC -eq 1 ]; then
    # netstat -I DEV -d -b: колонки считаем с конца строки (адрес в середине бывает пустым)
    set -- $(netstat -I "$DEV" -d -b 2>/dev/null | awk '
      NR == 1 { dc = ($NF == "Drop") ? 0 : 1; next }
      $3 ~ /^<Link/ && !d { d = 1; print $(NF - 7 + dc), $(NF - 6 + dc), $(NF - 4 + dc), $(NF - 3 + dc), (dc ? 0 : $NF) }')
    setv "${p}_rx_packets" "${1:-0}"; setv "${p}_rx_errors" "${2:-0}"; setv "${p}_rx_dropped" 0; setv "${p}_rx_fifo_errors" 0
    setv "${p}_tx_packets" "${3:-0}"; setv "${p}_tx_errors" "${4:-0}"; setv "${p}_tx_dropped" "${5:-0}"
    tcp=$(netstat -s -p tcp 2>/dev/null); udp=$(netstat -s -p udp 2>/dev/null)
    setv "${p}_tcp_out"    "$(awk '$2 == "packets" && $3 == "sent" { print $1; exit }' <<<"$tcp")"
    setv "${p}_tcp_retr"   "$(awk '$2 == "data" && $3 == "packets" && /retransmitted/ { print $1; exit }' <<<"$tcp")"
    setv "${p}_udp_inerr"  "$(awk '/with bad checksum/ { print $1; exit }' <<<"$udp")"
    setv "${p}_udp_rcvbuf" "$(awk '/dropped due to full socket buffers/ { print $1; exit }' <<<"$udp")"
    setv "${p}_ip_disc" 0
  else
    for f in rx_packets rx_errors rx_dropped rx_fifo_errors tx_packets tx_errors tx_dropped; do setv "${p}_$f" "$(cat "/sys/class/net/$DEV/statistics/$f" 2>/dev/null)"; done
    setv "${p}_tcp_out" "$(snmp_val Tcp OutSegs)"; setv "${p}_tcp_retr" "$(snmp_val Tcp RetransSegs)"
    setv "${p}_udp_inerr" "$(snmp_val Udp InErrors)"; setv "${p}_udp_rcvbuf" "$(snmp_val Udp RcvbufErrors)"
    setv "${p}_ip_disc" "$(snmp_val Ip InDiscards)"
  fi
}
delta() { local k1="C1_$1" k0="C0_$1"; echo $(( ${!k1:-0} - ${!k0:-0} )); }

# ───────────────────────── функции для сбора сведений ─────────────────────────
f_system() {
  local v
  echo "время (UTC): $(date -u '+%F %T')"
  echo "хост:        $(hostname)"
  echo "ядро:        $(uname -srm)"
  if [ $IS_MAC -eq 1 ]; then
    echo "ОС:          $(sw_vers -productName) $(sw_vers -productVersion)"
    echo "аптайм:      $(uptime)"
    echo "нагрузка:    $(sysctl -n vm.loadavg)"
    echo "CPU:         $(sysctl -n hw.ncpu) ($(sysctl -n machdep.cpu.brand_string 2>/dev/null))"
    echo "память:      $(( $(sysctl -n hw.memsize) / 1048576 )) МБ"
  else
    (. /etc/os-release 2>/dev/null && echo "ОС:          ${PRETTY_NAME:-?}")
    echo "аптайм:      $(uptime -p 2>/dev/null || uptime)"
    echo "нагрузка:    $(cut -d' ' -f1-3 /proc/loadavg)"
    v=$(systemd-detect-virt 2>/dev/null); echo "виртуализ.:  ${v:-н/д}"
    echo "CPU:         $(nproc) ($(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //'))"
    free -m
  fi
}
f_ipinfo() { curl -4 -sS -m 10 https://ipinfo.io/json || curl -4 -sS -m 10 https://ifconfig.me; }
f_netinfo() {
  if [ $IS_MAC -eq 1 ]; then
    ifconfig "$DEV" | head -n 12; echo
    netstat -rn -f inet | head -n 20; echo
    scutil --dns | grep -E 'nameserver\[|search domain' | head -n 10
  else
    ip -br addr; echo; ip -4 route; echo
    ip -d link show dev "$DEV" | sed -n 1,4p; echo
    grep -vE '^[[:space:]]*(#|$)' /etc/resolv.conf
  fi
}
f_nic() {
  if [ $IS_MAC -eq 1 ]; then
    ifconfig "$DEV" | grep -E 'mtu|media|status|options'
    if have wdutil && [ $IS_ROOT -eq 1 ]; then echo "— Wi-Fi (wdutil):"; wdutil info 2>/dev/null | grep -E 'SSID|RSSI|Noise|Tx Rate|Channel|PHY Mode' | head -n 10; fi
    echo; sysctl net.inet.tcp.delayed_ack net.inet.tcp.sendspace net.inet.tcp.recvspace net.inet.tcp.mssdflt 2>&1
    return 0
  fi
  if have ethtool; then
    ethtool -i "$DEV" 2>&1
    ethtool "$DEV" 2>&1 | grep -E 'Speed|Duplex|Link detected'
    echo "— счётчики с ошибками/потерями (ethtool -S):"
    ethtool -S "$DEV" 2>&1 | grep -iE 'drop|err|miss|fifo|discard' | head -30
  else
    echo "ethtool не установлен"
  fi
  echo; tc qdisc show dev "$DEV" 2>&1
  echo; sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_mtu_probing 2>&1
}
f_mtu() {   # f_mtu адрес: максимальный размер пакета без фрагментации (двоичный поиск по ping с флагом «не фрагментировать»)
  local ip="$1" lo=1200 hi=1472 mid
  if ! ping -n $PING_DF -c 2 -W $PING_W -s $lo "$ip" >/dev/null 2>&1; then echo "ICMP до $ip не проходит: проверить MTU нельзя"; return 0; fi
  while [ $lo -lt $hi ]; do
    mid=$(((lo + hi + 1) / 2))
    if ping -n $PING_DF -c 2 -W $PING_W -s $mid "$ip" >/dev/null 2>&1; then lo=$mid; else hi=$((mid - 1)); fi
  done
  echo "максимальный payload без фрагментации: $lo байт, MTU пути = $((lo + 28))"
}
f_curl() {   # f_curl url: 5 запросов с разбивкой по этапам
  local i
  for i in 1 2 3 4 5; do
    curl -4 -o /dev/null -s -m 15 -w 'dns=%{time_namelookup}с  tcp=%{time_connect}с  tls=%{time_appconnect}с  ttfb=%{time_starttransfer}с  всего=%{time_total}с  код=%{http_code}\n' "$1" || echo "ошибка curl (код $?)"
    sleep 0.4
  done
}

# ───────────────────────── приветствие и ввод адресов ─────────────────────────
echo
printf '  '; grad_text "RELAY TEST"; printf '  %sv%s%s\n' "$D" "$RT_VERSION" "$R"
echo "  ${D}задержки, потери и состояние сети: запуск на клиенте, отчёт в консоль${R}"
echo

if ! { : </dev/tty; } 2>/dev/null; then
  echo "нет терминала для ввода адресов: запустите скрипт в интерактивной сессии"
  exit 1
fi

ask_host "IP relay" RELAY_IP 1
ask_host "IP backend, если нужен" BACKEND_IP 0
echo

# ───────────────────────── подготовка ─────────────────────────
if [ $IS_MAC -eq 1 ]; then
  DEV=$(route -n get 77.88.8.8 2>/dev/null | awk '/interface:/ { print $2; exit }')
  GW=$(route -n get default 2>/dev/null | awk '/gateway:/ { print $2; exit }')
  LOCAL_IP=$([ -n "$DEV" ] && ifconfig "$DEV" 2>/dev/null | awk '$1 == "inet" { print $2; exit }')
else
  DEV=$(ip -4 route get 77.88.8.8 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
  LOCAL_IP=$(ip -4 route get 77.88.8.8 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')
  GW=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit }}')
fi
if [ -z "$DEV" ]; then echo "не удалось определить сетевой интерфейс (нет маршрута по умолчанию?)"; exit 1; fi
PUB_IP=$(curl -4 -s -m 8 https://ifconfig.me 2>/dev/null); num_ok "${PUB_IP//./}" || PUB_IP="${LOCAL_IP:-?}"

if [ $IS_ROOT -eq 0 ]; then
  if [ $IS_MAC -eq 1 ]; then
    emit "  ${YLW}▲${R} запущено не от root: на macOS пинг идёт с интервалом 1 с (30 пакетов), mtr недоступен. Запускайте через sudo"
  else
    emit "  ${YLW}▲${R} запущено не от root: интервал пинга и mtr ограничены, установка пакетов недоступна"
  fi
fi

# недостающие пакеты
if [ $IS_MAC -eq 1 ]; then
  if ! have mtr && [ $AUTO_INSTALL -eq 1 ] && have brew; then
    if [ $IS_ROOT -eq 1 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
      run "Установка mtr через Homebrew" "sudo -u $SUDO_USER env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 $(command -v brew) install mtr"
    elif [ $IS_ROOT -eq 0 ]; then
      run "Установка mtr через Homebrew" "HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew install mtr"
    fi
  fi
  have mtr || emit "  ${YLW}▲${R} mtr не установлен: выполните «brew install mtr» и запускайте скрипт через sudo; раздел маршрутов будет пропущен"
else
  miss=()
  have ping    || miss+=(iputils-ping)
  have ip      || miss+=(iproute2)
  have curl    || miss+=(curl)
  have mtr     || miss+=(mtr-tiny)
  have ethtool || miss+=(ethtool)
  if [ ${#miss[@]} -gt 0 ]; then
    if [ $AUTO_INSTALL -eq 1 ] && [ $IS_ROOT -eq 1 ] && have apt-get; then
      run "Установка недостающих пакетов: ${miss[*]}" "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ${miss[*]}"
    else
      emit "  ${YLW}▲${R} не хватает: ${miss[*]} (соответствующие проверки будут пропущены)"
    fi
  fi
fi
have ping || { echo "ping не найден: продолжать нельзя"; exit 1; }

snap C0   # счётчики «до»
T_START=$SECONDS

# ───────────────────────── 1. сведения о клиенте ─────────────────────────
section "1. Клиент и сеть"
emit "  публичный IP клиента: ${B}$PUB_IP${R}   интерфейс: $DEV   локальный IP: ${LOCAL_IP:-?}   шлюз: ${GW:-нет}"
emit "  relay: ${B}${RELAY_IP}${R}   backend: ${B}${BACKEND_IP:-не указан}${R}"
if [ $IS_MAC -eq 1 ]; then
  run "Система, ядро, процессор, память" "f_system" "date; hostname; uname -srm; sw_vers; uptime; sysctl hw.ncpu hw.memsize"
  have curl && run "Публичный IP и провайдер (ASN, город)" "f_ipinfo" "curl -4 -sS https://ipinfo.io/json"
  run "Адреса, маршруты, DNS-серверы" "f_netinfo" "ifconfig $DEV; netstat -rn -f inet; scutil --dns"
  run "Сетевой интерфейс: параметры, Wi-Fi, TCP-настройки" "f_nic" "ifconfig $DEV; wdutil info; sysctl net.inet.tcp.* ..."
else
  run "Система, ядро, виртуализация, процессор, память" "f_system" "date; hostname; uname -srm; uptime; systemd-detect-virt; nproc; free -m"
  have curl && run "Публичный IP и провайдер (ASN, город)" "f_ipinfo" "curl -4 -sS https://ipinfo.io/json"
  run "Адреса, маршруты, MTU интерфейса, DNS-серверы" "f_netinfo" "ip -br addr; ip -4 route; ip -d link show dev $DEV; cat /etc/resolv.conf"
  run "Сетевая карта: драйвер, скорость, счётчики ошибок, очередь, TCP-настройки" "f_nic" "ethtool -i/-S $DEV; tc qdisc show dev $DEV; sysctl net.ipv4.tcp_congestion_control ..."
fi

# ───────────────────────── 2. задержки и потери ICMP ─────────────────────────
section "2. Задержки и потери (ICMP, ${COUNT} пакетов на цель)"
emit "  ${D}Важно: потери ICMP не всегда равны потерям TCP, но потери на шлюзе или у контрольных адресов объясняют просадки скорости.${R}"
[ -n "$GW" ] && ping_target "gateway" "$GW"
ping_target "google" "8.8.8.8"
ping_target "yandex" "77.88.8.8"
ping_target "relay" "$RELAY_IP"
[ -n "$BACKEND_IP" ] && ping_target "backend" "$BACKEND_IP"

# ───────────────────────── 3. MTU ─────────────────────────
section "3. MTU пути"
MTU_NAME=(); MTU_VAL=()
mtu_target() {   # mtu_target имя адрес
  run "MTU до $1 ($2)" "f_mtu $2" "ping $PING_DF -s <размер> $2 (двоичный поиск)"
  MTU_NAME+=("$1"); MTU_VAL+=("$(sed -n 's/.*MTU пути = \([0-9]*\).*/\1/p' "$RT_OUT")")
}
mtu_target "yandex" "77.88.8.8"
mtu_target "relay" "$RELAY_IP"
[ -n "$BACKEND_IP" ] && mtu_target "backend" "$BACKEND_IP"

# ───────────────────────── 4. маршруты ─────────────────────────
section "4. Маршруты (mtr)"
emit "  ${D}Хоп, на котором потери ≥2% не исчезают до самой цели, — место, куда направлять запрос в поддержку.${R}"
if have mtr; then
  mtr_target "relay" "$RELAY_IP"
  [ -n "$BACKEND_IP" ] && mtr_target "backend" "$BACKEND_IP"
  mtr_target "yandex" "77.88.8.8"
  mtr_target "google" "8.8.8.8"
else
  emit "  ${YLW}▲${R} mtr не установлен: раздел пропущен"
fi

# ───────────────────────── 5. TCP/HTTPS ─────────────────────────
section "5. Время TCP- и TLS-соединений (5 запросов)"
if have curl; then
  run "Яндекс: dns / tcp / tls / первый байт" "f_curl https://ya.ru" "curl -4 -w '…' https://ya.ru  (×5)"
  run "Google" "f_curl https://www.google.com/generate_204" "curl -4 -w '…' https://www.google.com/generate_204  (×5)"
  run "GitHub (нужен установщику)" "f_curl https://raw.githubusercontent.com/cryptonoise/ratburrow/refs/heads/main/README.md" "curl -4 -w '…' https://raw.githubusercontent.com/…  (×5)"
else
  emit "  ${YLW}▲${R} curl не установлен: раздел пропущен"
fi

# ───────────────────────── 6. счётчики до/после ─────────────────────────
section "6. Счётчики клиента за время теста ($((SECONDS - T_START)) с)"
snap C1
if [ $IS_MAC -eq 1 ]; then
  run "Статистика интерфейса $DEV (ошибки и потери)" "netstat -I $DEV -d -b"
else
  run "Статистика интерфейса $DEV (ошибки и потери в ядре)" "ip -s -s link show dev $DEV"
fi
D_RXE=$(delta rx_errors); D_RXD=$(delta rx_dropped); D_TXE=$(delta tx_errors); D_TXD=$(delta tx_dropped); D_FIFO=$(delta rx_fifo_errors)
D_OUT=$(delta tcp_out); D_RETR=$(delta tcp_retr); D_UDPE=$(delta udp_inerr); D_UDPB=$(delta udp_rcvbuf); D_DISC=$(delta ip_disc)
RETR_PCT=$(awk -v r="$D_RETR" -v o="$D_OUT" 'BEGIN { if (o > 0) printf "%.2f", r * 100 / o; else print "0.00" }')
emit ""
emit "${B}  Изменение счётчиков за время теста${R}"
emit "    интерфейс $DEV:  rx_errors=$D_RXE  rx_dropped=$D_RXD  rx_fifo=$D_FIFO  tx_errors=$D_TXE  tx_dropped=$D_TXD"
emit "    IP:             InDiscards=$D_DISC"
emit "    UDP:            InErrors=$D_UDPE  RcvbufErrors=$D_UDPB"
emit "    TCP:            отправлено сегментов=$D_OUT  из них повторных=$D_RETR (${RETR_PCT}%)"
emit "    ${D}(TCP-счётчики включают весь трафик клиента за время теста; повторные передачи при BBR бывают и без реальных потерь)${R}"

# ───────────────────────── итоги ─────────────────────────
FIND_RU=(); FIND_EN=()
add() { FIND_RU+=("$1"); FIND_EN+=("$2"); }   # add «по-русски» «in English»

gw_loss="-"; base_bad=0; base_n=0; base_list=""
for i in "${!P_NAME[@]}"; do
  n=${P_NAME[$i]}; l=${P_LOSS[$i]}
  case "$n" in
    gateway) gw_loss=$l ;;
    google|yandex)
      if num_ok "$l" && ! fgt "$l" 99; then
        base_n=$((base_n + 1))
        if fgt "$l" 2; then base_bad=$((base_bad + 1)); base_list+=" $n=${l}%"; fi
      fi ;;
  esac
done
gw_bad=0; num_ok "$gw_loss" && fgt "$gw_loss" 0.5 && ! fgt "$gw_loss" 99 && gw_bad=1

if [ $gw_bad -eq 1 ]; then
  add "Потери ${gw_loss}% уже до вашего шлюза (${GW}): проблема в локальной сети (Wi-Fi, роутер, кабель) или на первом участке у интернет-провайдера." \
      "${gw_loss}% packet loss already to your default gateway (${GW}): the problem is in the local network (Wi-Fi, router, cable) or at the first ISP hop."
fi
if [ $base_bad -gt 0 ] && [ $gw_bad -eq 0 ]; then
  add "Шлюз отвечает без потерь, но до контрольных адресов потери ≥2%:${base_list}. Причина дальше шлюза: магистраль или стык вашего интернет-провайдера." \
      "The gateway answers without loss, but reference targets show loss ≥2%:${base_list}. The cause is beyond the gateway: ISP backbone or peering."
fi
if [ $base_n -gt 0 ] && [ $base_bad -eq 0 ] && [ $gw_bad -eq 0 ]; then
  add "Потерь ICMP ≥2% до контрольных адресов (Google, Яндекс) нет: интернет-канал клиента в целом исправен." \
      "No ICMP loss ≥2% to the reference targets (Google, Yandex): the client's internet connection looks healthy."
fi

tgt_find() {   # tgt_find имя потери% — вывод по relay / backend
  local n="$1" l="$2"
  num_ok "$l" || return 0
  if fgt "$l" 99; then
    add "$n не отвечает на ICMP (100% потерь): ping заблокирован или адрес недоступен; ориентируйтесь на mtr и TCP-проверки." \
        "$n does not answer ICMP (100% loss): ping may be blocked or the host is unreachable; rely on mtr and TCP checks."
  elif fgt "$l" 2; then
    if [ $gw_bad -eq 1 ]; then
      add "Потери ${l}% до $n, но потери есть уже до вашего шлюза: сначала нужно исправить локальный канал клиента, затем перепроверить $n." \
          "${l}% loss to $n, but there is loss already to your gateway: fix the client's local link first, then re-test $n."
    elif [ $base_bad -eq 0 ]; then
      add "Потери ${l}% до $n при чистых шлюзе и контрольных адресах: проблема на маршруте до $n или на самом $n (сеть его хостера)." \
          "${l}% loss to $n while the gateway and reference targets are clean: the problem is on the path to $n or on $n itself (its hosting network)."
    else
      add "Потери ${l}% до $n; шлюз чистый, локальный канал клиента исправен. Потери есть и до части контрольных адресов (${base_list# }): это может быть общая проблема провайдера, а может быть ICMP-фильтрация на самих адресах; смотрите mtr и повторите тест из другой сети." \
          "${l}% loss to $n; the gateway is clean, so the client's local link is fine. Some reference targets are lossy too (${base_list# }): this may be an ISP-wide issue or ICMP filtering at those hosts; check mtr and re-test from another network."
    fi
  else
    add "Потерь ICMP ≥2% до $n нет (${l}%)." "No ICMP loss ≥2% to $n (${l}%)."
  fi
}
for i in "${!P_NAME[@]}"; do
  case "${P_NAME[$i]}" in relay|backend) tgt_find "${P_NAME[$i]}" "${P_LOSS[$i]}" ;; esac
done

for i in "${!M_NAME[@]}"; do
  IFS='|' read -r st fin hop hip hloss last <<<"${M_RES[$i]}"
  if [ "$st" = "loss" ]; then
    add "mtr до ${M_NAME[$i]}: потери ${hloss}% начинаются с хопа ${hop} (${hip}) и сохраняются до цели (${fin}% на ${last}). Это место и нужно проверять." \
        "mtr to ${M_NAME[$i]}: ${hloss}% loss starts at hop ${hop} (${hip}) and persists to the destination (${fin}% at ${last}). Please check this segment."
  fi
done
if [ "$((D_RXE + D_RXD + D_FIFO + D_TXE + D_TXD))" -gt 0 ]; then
  add "Счётчики интерфейса $DEV выросли: rx_errors=$D_RXE rx_dropped=$D_RXD rx_fifo=$D_FIFO tx_errors=$D_TXE tx_dropped=$D_TXD (потери на самом клиенте: драйвер, Wi-Fi или виртуальная карта)." \
      "Interface $DEV counters increased: rx_errors=$D_RXE rx_dropped=$D_RXD rx_fifo=$D_FIFO tx_errors=$D_TXE tx_dropped=$D_TXD (loss on the client itself: driver, Wi-Fi or virtual NIC)."
else
  add "Счётчики интерфейса $DEV за время теста не росли: сам клиент пакеты не теряет, потери (если есть) происходят в сети." \
      "Interface $DEV error/drop counters did not grow during the test: the client itself is not dropping packets, so any loss happens in the network."
fi
for i in "${!MTU_NAME[@]}"; do
  v=${MTU_VAL[$i]}
  if [ -n "$v" ] && [ "$v" -lt 1500 ]; then
    add "MTU пути до ${MTU_NAME[$i]} равен ${v} (меньше 1500): возможны проблемы с фрагментацией крупных пакетов." \
        "Path MTU to ${MTU_NAME[$i]} is ${v} (below 1500): large packets may be fragmented or dropped."
  fi
done

emit ""
emit "${B}${CYN}━━ ИТОГ: relay-test.sh $RT_VERSION ━━${R}"
emit "  клиент: ${B}${PUB_IP}${R} ($(hostname)), интерфейс $DEV, шлюз ${GW:-нет}"
emit "  relay:  ${RELAY_IP}   backend: ${BACKEND_IP:-не указан}"
emit "  время:  $(date -u '+%F %T') UTC, тест шёл $((SECONDS - T_START)) с"
emit ""
printf -v hdr '  %-11s %-18s %8s %8s %8s %8s %8s  %s' "target" "address" "loss%" "min" "avg" "max" "jitter" "verdict"   # заголовок на латинице: printf выравнивает по байтам
emit "${B}${hdr}${R}"
for i in "${!P_NAME[@]}"; do
  v=$(verdict "${P_LOSS[$i]}")
  case "$v" in "ОК") c=$GRN ;; "ПЛОХО") c=$RED ;; "н/д"|"нет ответа") c=$D ;; *) c=$YLW ;; esac
  printf -v row '  %-11s %-18s %8s %8s %8s %8s %8s  ' "${P_NAME[$i]}" "${P_ADDR[$i]}" "${P_LOSS[$i]}" "${P_MIN[$i]}" "${P_AVG[$i]}" "${P_MAX[$i]}" "${P_MDEV[$i]}"
  emit "${row}${c}${v}${R}"
done
emit "  ${D}время в мс; jitter — стандартное отклонение RTT; потери в процентах${R}"
emit ""
emit "${B}  Выводы${R}"
for f in "${FIND_RU[@]}"; do emit "   • $f"; done
emit ""
emit "${B}  Текст для обращения в поддержку (хостинг relay или интернет-провайдер)${R}"
emit "  ${D}— по-русски —${R}"
emit "  Здравствуйте! С клиента (публичный IP ${PUB_IP}, интерфейс ${DEV}, шлюз ${GW:-?}) при работе с relay ${RELAY_IP}${BACKEND_IP:+ и backend ${BACKEND_IP}} наблюдаются потери пакетов и просадки скорости."
emit "  Автоматическая диагностика (relay-test.sh ${RT_VERSION}, $(date -u '+%F %T') UTC) показала:"
for f in "${FIND_RU[@]}"; do emit "   - $f"; done
emit "  Прошу проверить сеть на указанном участке, стык с апстримом, ограничения скорости и числа пакетов в секунду (pps). Полный вывод команд могу предоставить."
emit "  ${D}— in English —${R}"
emit "  Hello! From the client (public IP ${PUB_IP}, interface ${DEV}, gateway ${GW:-?}) we see packet loss and degraded throughput when working with relay ${RELAY_IP}${BACKEND_IP:+ and backend ${BACKEND_IP}}."
emit "  An automated diagnostic (relay-test.sh ${RT_VERSION}, $(date -u '+%F %T') UTC) shows:"
for f in "${FIND_EN[@]}"; do emit "   - $f"; done
emit "  Please check the network segment mentioned above, the upstream peering, and any rate / packets-per-second limits. The full command output is available on request."
emit ""
