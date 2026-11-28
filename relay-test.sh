#!/usr/bin/env bash
# relay-test.sh — отчёт о задержках, потерях пакетов и состоянии сети сервера (RELAY)
#
# Что делает: меряет пинг и потери до шлюза хостера и внешних адресов, строит маршруты (mtr),
# проверяет MTU пути, время TCP/TLS-соединений, «соседей по гипервизору» (CPU steal, джиттер таймера),
# сравнивает счётчики сетевой карты и TCP до/после и (если указан --client) считает, сколько пакетов
# клиента реально дошло до сервера. Каждая команда показана в отчёте вместе с выводом.
# Итоговый файл отчёта можно целиком отправить в поддержку хостинга.
#
# Запуск:  curl -fsSL https://raw.githubusercontent.com/cryptonoise/ratburrow/refs/heads/main/relay-test.sh | sudo bash
# Параметры:  | sudo bash -s -- --backend IP --client IP   (см. --help)

RT_VERSION="1.0"
set -u
set -o pipefail
shopt -s extglob
export LC_ALL=C.UTF-8   # одинаковая работа с кириллицей и десятичной точкой независимо от локали сервера

# ───────────────────────── параметры ─────────────────────────
CLIENT_IP=""            # IP клиента: включает подсчёт пакетов клиента, дошедших до сервера
BACKEND_IP=""           # IP или имя BACKEND: пинг, mtr и MTU до него
COUNT=100               # сколько ICMP-пакетов слать на каждую цель (каждые 0.2 с)
MTR_COUNT=150           # сколько циклов mtr на каждую цель
CAPTURE_SECS=80         # сколько секунд слушать пинг клиента
AUTO_INSTALL=1          # ставить недостающие пакеты (apt-get)
REPORT=""               # куда сохранить итоговый отчёт

usage() {
  cat <<EOF
relay-test.sh $RT_VERSION — диагностика задержек и потерь сервера

Использование: relay-test.sh [параметры]

  --backend IP|имя   адрес BACKEND (пинг, mtr, MTU до него)
  --client IP        IPv4 клиента: считает, сколько его пакетов дошло до сервера
                     (во время теста нужно запустить на клиенте: ping -c 300 -i 0.2 IP_СЕРВЕРА)
  --count N          пакетов пинга на цель (по умолчанию $COUNT)
  --quick            короткий прогон (30 пакетов, mtr 40 циклов, 50 с на захват)
  --out ФАЙЛ         куда сохранить отчёт (по умолчанию /root/relay-test-ХОСТ-ДАТА.txt)
  --no-install       не устанавливать недостающие пакеты
  -h, --help         эта справка
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --client)     [ $# -ge 2 ] || { echo "нужно значение для $1"; exit 1; }; CLIENT_IP="$2"; shift 2 ;;
    --backend)    [ $# -ge 2 ] || { echo "нужно значение для $1"; exit 1; }; BACKEND_IP="$2"; shift 2 ;;
    --count)      [ $# -ge 2 ] || { echo "нужно значение для $1"; exit 1; }; COUNT="$2"; shift 2 ;;
    --out)        [ $# -ge 2 ] || { echo "нужно значение для $1"; exit 1; }; REPORT="$2"; shift 2 ;;
    --quick)      COUNT=30; MTR_COUNT=40; CAPTURE_SECS=50; shift ;;
    --no-install) AUTO_INSTALL=0; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "неизвестный параметр: $1"; usage; exit 1 ;;
  esac
done

case "$COUNT" in ''|*[!0-9]*) echo "--count: нужно целое число"; exit 1 ;; esac
[ "$COUNT" -ge 5 ] || { echo "--count: минимум 5"; exit 1; }
if [ -n "$CLIENT_IP" ] && ! [[ "$CLIENT_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "--client: нужен IPv4-адрес"; exit 1; fi
if [ -n "$BACKEND_IP" ] && ! [[ "$BACKEND_IP" =~ ^[A-Za-z0-9.-]+$ ]]; then echo "--backend: недопустимый адрес"; exit 1; fi

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

plain() { printf '%s' "${1//$'\033'\[*([0-9;])[A-Za-z]/}"; }   # убирает цветовые коды для файла отчёта

TMPD=$(mktemp -d /tmp/relay-test.XXXXXX) || { echo "не удалось создать временный каталог"; exit 1; }
DETAIL="$TMPD/detail.txt"; SUMMARY="$TMPD/summary.txt"; : >"$DETAIL"; : >"$SUMMARY"

cleanup() { jobs -p 2>/dev/null | xargs -r kill 2>/dev/null; rm -rf "$TMPD"; [ -t 1 ] && printf '\033[?25h'; return 0; }
trap cleanup EXIT
trap 'echo; echo "прервано"; exit 130' INT TERM

emit()     { local l="$*"; printf '%s\n' "$l"; printf '%s\n' "$(plain "$l")" >>"$DETAIL"; }    # терминал + подробная часть отчёта
emit_sum() { local l="$*"; printf '%s\n' "$l"; printf '%s\n' "$(plain "$l")" >>"$SUMMARY"; }  # терминал + сводка (в файле — вверху)
section()  { emit ""; emit "${B}${CYN}━━ $* ━━${R}"; }
have()     { command -v "$1" >/dev/null 2>&1; }

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
  [ $n -gt 150 ] && emit "    ${D}… ещё $((n - 150)) строк в полном выводе опущены${R}"
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

# ───────────────────────── разбор результатов ─────────────────────────
num_ok() { [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
fgt()    { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }   # a >= b (числа с точкой)
fmt()    { awk -v v="$1" 'BEGIN { printf "%.1f", v + 0 }'; }

# пинг: результаты складываются в массивы P_*
P_NAME=(); P_ADDR=(); P_LOSS=(); P_MIN=(); P_AVG=(); P_MAX=(); P_MDEV=()
ping_target() {   # ping_target имя адрес
  local name="$1" ip="$2" loss mn av mx md line
  run "Пинг: $name ($ip), $COUNT пакетов с интервалом 0.2 с" "ping -n -c $COUNT -i 0.2 -W 2 -q $ip"
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
  [ "$(id -u)" -eq 0 ] && args="-i 0.2 -c $MTR_COUNT"
  run "Маршрут (mtr): $name ($ip)" "timeout 240 mtr -rwn $args $ip" "mtr -rwn $args $ip"
  res=$(mtr_analyze "$RT_OUT")
  M_NAME+=("$name"); M_RES+=("$res")
}

# ───────────────────────── счётчики до/после ─────────────────────────
declare -A C0=() C1=()
snmp_val() { awk -v p="$1:" -v k="$2" '$1 == p { if (!h) { for (i = 2; i <= NF; i++) c[$i] = i; h = 1 } else { print $(c[k]); exit } }' /proc/net/snmp; }
snap() {   # snap ИМЯ_МАССИВА: снимок счётчиков интерфейса и TCP/UDP
  local -n S=$1; local f
  for f in rx_packets rx_errors rx_dropped rx_fifo_errors tx_packets tx_errors tx_dropped; do S[$f]=$(cat "/sys/class/net/$DEV/statistics/$f" 2>/dev/null || echo 0); done
  S[tcp_out]=$(snmp_val Tcp OutSegs); S[tcp_retr]=$(snmp_val Tcp RetransSegs); S[tcp_in]=$(snmp_val Tcp InSegs); S[tcp_inerr]=$(snmp_val Tcp InErrs)
  S[udp_inerr]=$(snmp_val Udp InErrors); S[udp_rcvbuf]=$(snmp_val Udp RcvbufErrors)
  S[ip_disc]=$(snmp_val Ip InDiscards); S[ip_hdr]=$(snmp_val Ip InHdrErrors)
}
delta() { echo $(( ${C1[$1]:-0} - ${C0[$1]:-0} )); }

# ───────────────────────── функции для сбора сведений ─────────────────────────
f_system() {
  local v
  echo "время (UTC): $(date -u '+%F %T')"
  echo "хост:        $(hostname)"
  echo "ядро:        $(uname -srm)"
  (. /etc/os-release 2>/dev/null && echo "ОС:          ${PRETTY_NAME:-?}")
  echo "аптайм:      $(uptime -p 2>/dev/null || uptime)"
  echo "нагрузка:    $(cut -d' ' -f1-3 /proc/loadavg)"
  v=$(systemd-detect-virt 2>/dev/null); echo "виртуализ.:  ${v:-н/д}"
  echo "vCPU:        $(nproc) ($(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //'))"
  free -m
}
f_ipinfo() { curl -4 -sS -m 10 https://ipinfo.io/json || curl -4 -sS -m 10 https://ifconfig.me; }
f_netinfo() {
  ip -br addr; echo; ip -4 route; echo
  ip -d link show dev "$DEV" | sed -n 1,4p; echo
  grep -vE '^[[:space:]]*(#|$)' /etc/resolv.conf
}
f_nic() {
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
f_mtu() {   # f_mtu адрес: максимальный размер пакета без фрагментации (двоичный поиск по ping -M do)
  local ip="$1" lo=1200 hi=1472 mid
  if ! ping -n -M do -c 2 -W 2 -s $lo "$ip" >/dev/null 2>&1; then echo "ICMP до $ip не проходит: проверить MTU нельзя"; return 0; fi
  while [ $lo -lt $hi ]; do
    mid=$(((lo + hi + 1) / 2))
    if ping -n -M do -c 2 -W 2 -s $mid "$ip" >/dev/null 2>&1; then lo=$mid; else hi=$((mid - 1)); fi
  done
  echo "максимальный payload без фрагментации: $lo байт, MTU пути = $((lo + 28))"
}
f_jitter() {   # насколько точно сервер просыпается после sleep(1 мс): показывает «шумных соседей» и нехватку CPU
  python3 - <<'PY'
import time
d = []
for _ in range(2500):
    t = time.perf_counter(); time.sleep(0.001)
    d.append((time.perf_counter() - t) * 1000 - 1.0)
d.sort(); n = len(d)
print("замеров=%d  среднее_опоздание=%.3f мс  p50=%.3f  p99=%.3f  макс=%.3f мс" % (n, sum(d) / n, d[n // 2], d[int(n * 0.99)], d[-1]))
PY
}
f_curl() {   # f_curl url: 5 запросов с разбивкой по этапам
  local i
  for i in 1 2 3 4 5; do
    curl -4 -o /dev/null -s -m 15 -w 'dns=%{time_namelookup}с  tcp=%{time_connect}с  tls=%{time_appconnect}с  ttfb=%{time_starttransfer}с  всего=%{time_total}с  код=%{http_code}\n' "$1" || echo "ошибка curl (код $?)"
    sleep 0.4
  done
}

# ───────────────────────── подготовка ─────────────────────────
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1
[ -n "$REPORT" ] || { if [ $IS_ROOT -eq 1 ]; then REPORT="/root/relay-test-$(hostname)-$(date -u +%Y%m%d-%H%M%S).txt"; else REPORT="$PWD/relay-test-$(hostname)-$(date -u +%Y%m%d-%H%M%S).txt"; fi; }

echo
printf '  '; grad_text "RELAY TEST"; printf '  %sv%s%s\n' "$D" "$RT_VERSION" "$R"
echo "  ${D}задержки, потери и состояние сети сервера: отчёт для вас и для поддержки хостинга${R}"
emit "relay-test.sh $RT_VERSION"

DEV=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')
GW=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit }}')
if [ -z "$DEV" ]; then echo "не удалось определить сетевой интерфейс (нет маршрута по умолчанию?)"; exit 1; fi
PUB_IP=$(curl -4 -s -m 8 https://ifconfig.me 2>/dev/null); num_ok "${PUB_IP//./}" || PUB_IP="${LOCAL_IP:-?}"

[ $IS_ROOT -eq 1 ] || { emit "  ${YLW}▲${R} запущено не от root: интервал пинга и mtr ограничены, захват пакетов и установка пакетов недоступны"; }

# недостающие пакеты
miss=()
have ping    || miss+=(iputils-ping)
have ip      || miss+=(iproute2)
have curl    || miss+=(curl)
have mtr     || miss+=(mtr-tiny)
have ethtool || miss+=(ethtool)
have vmstat  || miss+=(procps)
have python3 || miss+=(python3)
{ [ -z "$CLIENT_IP" ] || have tcpdump; } || miss+=(tcpdump)
if [ ${#miss[@]} -gt 0 ]; then
  if [ $AUTO_INSTALL -eq 1 ] && [ $IS_ROOT -eq 1 ] && have apt-get; then
    run "Установка недостающих пакетов: ${miss[*]}" "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ${miss[*]}"
  else
    emit "  ${YLW}▲${R} не хватает: ${miss[*]} (соответствующие проверки будут пропущены)"
  fi
fi
have ping || { echo "ping не найден: продолжать нельзя"; exit 1; }

snap C0   # счётчики «до»
T_START=$SECONDS

# ───────────────────────── 1. сведения о сервере ─────────────────────────
section "1. Сервер и сеть"
emit "  публичный IP: ${B}$PUB_IP${R}   интерфейс: $DEV   локальный IP: ${LOCAL_IP:-?}   шлюз: ${GW:-нет}"
run "Система, ядро, виртуализация, процессор, память" "f_system" "date; hostname; uname -srm; uptime; systemd-detect-virt; nproc; free -m"
have curl && run "Публичный IP и провайдер (ASN, город)" "f_ipinfo" "curl -4 -sS https://ipinfo.io/json"
run "Адреса, маршруты, MTU интерфейса, DNS-серверы" "f_netinfo" "ip -br addr; ip -4 route; ip -d link show dev $DEV; cat /etc/resolv.conf"
run "Сетевая карта: драйвер, скорость, счётчики ошибок, очередь, TCP-настройки" "f_nic" "ethtool -i/-S $DEV; tc qdisc show dev $DEV; sysctl net.ipv4.tcp_congestion_control ..."

# ───────────────────────── 2. процессор и «соседи» ─────────────────────────
section "2. Процессор и соседи по гипервизору"
STEAL_AVG="-"; STEAL_MAX="-"; JIT_P99="-"; JIT_MAX="-"
if have vmstat; then
  run "CPU за 10 секунд: колонка st — время, отнятое гипервизором" "vmstat 1 10"
  read -r STEAL_AVG STEAL_MAX < <(awk 'NR == 2 { for (i = 1; i <= NF; i++) if ($i == "st") s = i }
    NR > 3 && s { v = $s + 0; sum += v; n++; if (v > mx) mx = v }
    END { if (n) printf "%.1f %.1f\n", sum / n, mx; else print "- -" }' "$RT_OUT")
  emit "  ${B}steal:${R} в среднем ${STEAL_AVG}%, максимум ${STEAL_MAX}%"
fi
if have python3; then
  run "Джиттер таймера: опоздание пробуждения после sleep(1 мс), 2500 замеров" "f_jitter" "python3 (sleep 1 мс × 2500, замер опоздания)"
  JIT_P99=$(sed -n 's/.*p99=\([0-9.]*\).*/\1/p' "$RT_OUT" | head -n1); JIT_MAX=$(sed -n 's/.*макс=\([0-9.]*\).*/\1/p' "$RT_OUT" | head -n1)
  JIT_P99=${JIT_P99:--}; JIT_MAX=${JIT_MAX:--}
fi

# ───────────────────────── 3. задержки и потери ICMP ─────────────────────────
section "3. Задержки и потери (ICMP, ${COUNT} пакетов на цель)"
emit "  ${D}Важно: потери ICMP не всегда равны потерям TCP, но потери на шлюзе или у соседних адресов объясняют просадки скорости.${R}"
[ -n "$GW" ] && ping_target "gateway" "$GW"
ping_target "cloudflare" "1.1.1.1"
ping_target "google" "8.8.8.8"
ping_target "yandex" "77.88.8.8"
[ -n "$BACKEND_IP" ] && ping_target "backend" "$BACKEND_IP"
[ -n "$CLIENT_IP" ] && ping_target "client" "$CLIENT_IP"

# ───────────────────────── 4. MTU ─────────────────────────
section "4. MTU пути"
MTU_NAME=(); MTU_VAL=()
mtu_target() {   # mtu_target имя адрес
  run "MTU до $1 ($2)" "f_mtu $2" "ping -M do -s <размер> $2 (двоичный поиск)"
  MTU_NAME+=("$1"); MTU_VAL+=("$(sed -n 's/.*MTU пути = \([0-9]*\).*/\1/p' "$RT_OUT")")
}
mtu_target "cloudflare" "1.1.1.1"
[ -n "$BACKEND_IP" ] && mtu_target "backend" "$BACKEND_IP"

# ───────────────────────── 5. маршруты ─────────────────────────
section "5. Маршруты (mtr)"
emit "  ${D}Хоп, на котором потери ≥2% не исчезают до самой цели, — место, куда направлять запрос поддержке.${R}"
if have mtr; then
  [ -n "$BACKEND_IP" ] && mtr_target "backend" "$BACKEND_IP"
  [ -n "$CLIENT_IP" ] && mtr_target "client" "$CLIENT_IP"
  mtr_target "cloudflare" "1.1.1.1"
  mtr_target "yandex" "77.88.8.8"
else
  emit "  ${YLW}▲${R} mtr не установлен: раздел пропущен"
fi

# ───────────────────────── 6. TCP/HTTPS ─────────────────────────
section "6. Время TCP- и TLS-соединений (5 запросов)"
if have curl; then
  run "Cloudflare: dns / tcp / tls / первый байт" "f_curl https://www.cloudflare.com/cdn-cgi/trace" "curl -4 -w '…' https://www.cloudflare.com/cdn-cgi/trace  (×5)"
  run "Яндекс" "f_curl https://ya.ru" "curl -4 -w '…' https://ya.ru  (×5)"
  run "GitHub (нужен установщику)" "f_curl https://raw.githubusercontent.com/cryptonoise/ratburrow/refs/heads/main/README.md" "curl -4 -w '…' https://raw.githubusercontent.com/…  (×5)"
else
  emit "  ${YLW}▲${R} curl не установлен: раздел пропущен"
fi

# ───────────────────────── 7. пакеты клиента ─────────────────────────
CAP_RES=""   # «получено диапазон ответов потеряно»
if [ -n "$CLIENT_IP" ] && [ $IS_ROOT -eq 1 ] && have tcpdump; then
  section "7. Сколько пакетов клиента дошло до сервера"
  emit "  ${B}Действие на КЛИЕНТЕ (не на сервере):${R} в течение ближайших ${CAPTURE_SECS} секунд запустите"
  emit "      ${B}ping -c 300 -i 0.2 ${PUB_IP}${R}"
  emit "  Сервер считает номера ICMP-пакетов (seq): пропуски в номерах — потеря ДО сервера, а не после него."
  run "Захват ICMP от ${CLIENT_IP} (${CAPTURE_SECS} с): ждём ping с клиента" "timeout $CAPTURE_SECS tcpdump -l -nn -i any 'icmp and host $CLIENT_IP' 2>&1" "timeout $CAPTURE_SECS tcpdump -l -nn -i any 'icmp and host $CLIENT_IP'"
  CAP_RES=$(awk -v c="$CLIENT_IP" '
    /ICMP echo request/ && index($0, "IP " c " >") { if (match($0, /seq [0-9]+/)) { s = substr($0, RSTART + 4, RLENGTH - 4) + 0; if (!(s in R)) { R[s] = 1; nr++; if (mn == "" || s < mn) mn = s; if (s > mx) mx = s } } }
    /ICMP echo reply/ && index($0, "> " c ":")      { if (match($0, /seq [0-9]+/)) { s = substr($0, RSTART + 4, RLENGTH - 4) + 0; if (!(s in P)) { P[s] = 1; np++ } } }
    END { range = nr ? mx - mn + 1 : 0; printf "%d %d %d\n", nr, range, np }' "$RT_OUT")
  read -r CAP_REQ CAP_RANGE CAP_REPL <<<"$CAP_RES"
  CAP_REQ=${CAP_REQ:-0}; CAP_RANGE=${CAP_RANGE:-0}; CAP_REPL=${CAP_REPL:-0}
  if [ "$CAP_REQ" -eq 0 ]; then
    emit "  ${YLW}▲${R} от клиента не пришло ни одного ping: он не запускался или ICMP блокируется"
  else
    CAP_GAP=$((CAP_RANGE - CAP_REQ))
    emit "  получено запросов: ${B}${CAP_REQ}${R} из ${CAP_RANGE} (по номерам seq); не дошло до сервера: ${B}${CAP_GAP}${R} ($(awk -v g="$CAP_GAP" -v r="$CAP_RANGE" 'BEGIN { printf "%.1f", g * 100 / r }')%)"
    emit "  отправлено ответов: ${B}${CAP_REPL}${R} из ${CAP_REQ} полученных"
  fi
elif [ -n "$CLIENT_IP" ]; then
  section "7. Сколько пакетов клиента дошло до сервера"
  emit "  ${YLW}▲${R} пропущено: нужны root и tcpdump"
fi

# ───────────────────────── 8. счётчики до/после ─────────────────────────
section "8. Счётчики сервера за время теста ($((SECONDS - T_START)) с)"
snap C1
run "Статистика интерфейса $DEV (ошибки и потери в ядре)" "ip -s -s link show dev $DEV"
D_RXE=$(delta rx_errors); D_RXD=$(delta rx_dropped); D_TXE=$(delta tx_errors); D_TXD=$(delta tx_dropped); D_FIFO=$(delta rx_fifo_errors)
D_OUT=$(delta tcp_out); D_RETR=$(delta tcp_retr); D_UDPE=$(delta udp_inerr); D_UDPB=$(delta udp_rcvbuf); D_DISC=$(delta ip_disc)
RETR_PCT=$(awk -v r="$D_RETR" -v o="$D_OUT" 'BEGIN { if (o > 0) printf "%.2f", r * 100 / o; else print "0.00" }')
emit ""
emit "${B}  Изменение счётчиков за время теста${R}"
emit "    интерфейс $DEV:  rx_errors=$D_RXE  rx_dropped=$D_RXD  rx_fifo=$D_FIFO  tx_errors=$D_TXE  tx_dropped=$D_TXD"
emit "    IP:             InDiscards=$D_DISC"
emit "    UDP:            InErrors=$D_UDPE  RcvbufErrors=$D_UDPB"
emit "    TCP:            отправлено сегментов=$D_OUT  из них повторных=$D_RETR (${RETR_PCT}%)"
emit "    ${D}(TCP-счётчики включают реальный трафик пользователей на сервере; повторные передачи при BBR бывают и без реальных потерь)${R}"

# ───────────────────────── итоги ─────────────────────────
FIND_RU=(); FIND_EN=()
add() { FIND_RU+=("$1"); FIND_EN+=("$2"); }   # add «по-русски» «in English»

gw_loss="-"; ext_bad=0; ext_n=0; ext_list_ru=""; ext_list_en=""
for i in "${!P_NAME[@]}"; do
  n=${P_NAME[$i]}; l=${P_LOSS[$i]}
  [ "$n" = "gateway" ] && gw_loss=$l
  case "$n" in cloudflare|google|yandex|backend)
    if num_ok "$l" && ! fgt "$l" 99; then
      ext_n=$((ext_n + 1))
      if fgt "$l" 2; then ext_bad=$((ext_bad + 1)); ext_list_ru+=" $n=${l}%"; ext_list_en+=" $n=${l}%"; fi
    fi ;;
  esac
done

if num_ok "$gw_loss" && ! fgt "$gw_loss" 99 && fgt "$gw_loss" 0.5; then
  add "Потери ${gw_loss}% уже до шлюза хостера (${GW}): проблема в сети хостера на первом участке, до выхода в интернет." \
      "${gw_loss}% packet loss already to the provider's default gateway (${GW}): the problem is inside the hosting network, before any transit."
fi
if [ $ext_bad -gt 0 ] && { ! num_ok "$gw_loss" || ! fgt "$gw_loss" 0.5; }; then
  add "Шлюз отвечает без потерь, но до внешних адресов потери ≥2%:${ext_list_ru}. Причина дальше шлюза: магистраль или стык хостера с апстримом." \
      "The gateway answers without loss, but external targets show loss ≥2%:${ext_list_en}. The cause is beyond the gateway: provider backbone or upstream peering."
fi
if [ $ext_n -gt 0 ] && [ $ext_bad -eq 0 ] && { ! num_ok "$gw_loss" || ! fgt "$gw_loss" 0.5; }; then
  add "Потерь ICMP ≥2% до проверенных адресов нет." "No ICMP loss ≥2% to the tested targets."
fi
for i in "${!M_NAME[@]}"; do
  IFS='|' read -r st fin hop hip hloss last <<<"${M_RES[$i]}"
  if [ "$st" = "loss" ]; then
    add "mtr до ${M_NAME[$i]}: потери ${hloss}% начинаются с хопа ${hop} (${hip}) и сохраняются до цели (${fin}% на ${last}). Это место и нужно проверять." \
        "mtr to ${M_NAME[$i]}: ${hloss}% loss starts at hop ${hop} (${hip}) and persists to the destination (${fin}% at ${last}). Please check this segment."
  fi
done
if num_ok "$STEAL_AVG" && fgt "$STEAL_AVG" 3; then
  add "CPU steal в среднем ${STEAL_AVG}% (максимум ${STEAL_MAX}%): гипервизор отдаёт виртуалке меньше процессорного времени, чем положено; возможна перегрузка хоста." \
      "CPU steal averages ${STEAL_AVG}% (max ${STEAL_MAX}%): the hypervisor gives the VM less CPU time than it should; the host may be oversold."
fi
if num_ok "$JIT_P99" && fgt "$JIT_P99" 5; then
  add "Джиттер таймера: 99-й процентиль опоздания ${JIT_P99} мс (максимум ${JIT_MAX} мс): заметные задержки планировщика на хосте." \
      "Timer jitter: 99th percentile wake-up delay ${JIT_P99} ms (max ${JIT_MAX} ms): noticeable scheduling delays on the host."
fi
if [ "$((D_RXE + D_RXD + D_FIFO + D_TXE + D_TXD))" -gt 0 ]; then
  add "Счётчики интерфейса $DEV выросли: rx_errors=$D_RXE rx_dropped=$D_RXD rx_fifo=$D_FIFO tx_errors=$D_TXE tx_dropped=$D_TXD (потери внутри виртуалки или виртуальной карты)." \
      "Interface $DEV counters increased: rx_errors=$D_RXE rx_dropped=$D_RXD rx_fifo=$D_FIFO tx_errors=$D_TXE tx_dropped=$D_TXD (loss inside the VM or virtual NIC)."
elif [ -n "$D_OUT" ]; then
  add "Счётчики интерфейса $DEV за время теста не росли: потери ядра сервера исключены, потери происходят до виртуалки." \
      "Interface $DEV error/drop counters did not grow during the test: the guest kernel is not dropping packets, so loss happens before the VM."
fi
if [ -n "$CAP_RES" ] && [ "${CAP_REQ:-0}" -gt 0 ]; then
  if [ "${CAP_GAP:-0}" -gt 0 ]; then
    add "Из ${CAP_RANGE} ping-пакетов клиента ${CLIENT_IP} до сервера дошло ${CAP_REQ} (не дошло ${CAP_GAP}): потеря происходит на пути до сервера или на входе в виртуалку." \
        "Of ${CAP_RANGE} ping packets from client ${CLIENT_IP}, ${CAP_REQ} reached the server (${CAP_GAP} missing): loss happens on the way to the server or at the VM ingress."
  else
    add "Все ${CAP_RANGE} ping-пакетов клиента ${CLIENT_IP} дошли до сервера: в этом тесте входящих потерь нет." \
        "All ${CAP_RANGE} ping packets from client ${CLIENT_IP} reached the server: no inbound loss in this test."
  fi
fi
for i in "${!MTU_NAME[@]}"; do
  v=${MTU_VAL[$i]}
  if [ -n "$v" ] && [ "$v" -lt 1500 ]; then
    add "MTU пути до ${MTU_NAME[$i]} равен ${v} (меньше 1500): возможны проблемы с фрагментацией крупных пакетов." \
        "Path MTU to ${MTU_NAME[$i]} is ${v} (below 1500): large packets may be fragmented or dropped."
  fi
done

emit_sum ""
emit_sum "${B}${CYN}━━ ИТОГ: relay-test.sh $RT_VERSION ━━${R}"
emit_sum "  сервер: ${B}${PUB_IP}${R} ($(hostname)), интерфейс $DEV, шлюз ${GW:-нет}"
emit_sum "  время:  $(date -u '+%F %T') UTC, тест шёл $((SECONDS - T_START)) с"
emit_sum ""
printf -v hdr '  %-11s %-18s %8s %8s %8s %8s %8s  %s' "target" "address" "loss%" "min" "avg" "max" "jitter" "verdict"   # заголовок на латинице: printf выравнивает по байтам
emit_sum "${B}${hdr}${R}"
for i in "${!P_NAME[@]}"; do
  v=$(verdict "${P_LOSS[$i]}")
  case "$v" in "ОК") c=$GRN ;; "ПЛОХО") c=$RED ;; "н/д"|"нет ответа") c=$D ;; *) c=$YLW ;; esac
  printf -v row '  %-11s %-18s %8s %8s %8s %8s %8s  ' "${P_NAME[$i]}" "${P_ADDR[$i]}" "${P_LOSS[$i]}" "${P_MIN[$i]}" "${P_AVG[$i]}" "${P_MAX[$i]}" "${P_MDEV[$i]}"
  emit_sum "${row}${c}${v}${R}"
done
emit_sum "  ${D}время в мс; jitter — стандартное отклонение RTT; потери в процентах${R}"
emit_sum ""
emit_sum "${B}  Выводы${R}"
if [ ${#FIND_RU[@]} -eq 0 ]; then emit_sum "   • явных проблем в этом тесте не найдено"; fi
for f in "${FIND_RU[@]}"; do emit_sum "   • $f"; done
emit_sum ""
emit_sum "${B}  Текст для поддержки хостинга${R}"
emit_sum "  ${D}— по-русски —${R}"
emit_sum "  Здравствуйте! На сервере ${PUB_IP} (интерфейс ${DEV}, шлюз ${GW:-?}) наблюдаются потери пакетов и просадки скорости загрузки."
emit_sum "  Автоматический отчёт (relay-test.sh ${RT_VERSION}, $(date -u '+%F %T') UTC) показал:"
for f in "${FIND_RU[@]}"; do emit_sum "   - $f"; done
emit_sum "  Прошу проверить сеть на участке до шлюза и стык с апстримом, наличие ограничений скорости и числа пакетов в секунду (pps), загрузку гипервизора. Полный отчёт с выводом всех команд прилагаю."
emit_sum "  ${D}— in English —${R}"
emit_sum "  Hello! On server ${PUB_IP} (interface ${DEV}, gateway ${GW:-?}) we see packet loss and degraded upload throughput."
emit_sum "  An automated report (relay-test.sh ${RT_VERSION}, $(date -u '+%F %T') UTC) shows:"
for f in "${FIND_EN[@]}"; do emit_sum "   - $f"; done
emit_sum "  Please check the network segment up to the gateway and the upstream peering, any rate / packets-per-second limits, and hypervisor load. The full report with all command outputs is attached."

{ printf 'relay-test.sh %s\n%s\n\n' "$RT_VERSION" "$(date -u '+%F %T') UTC"; cat "$SUMMARY"; printf '\n\n══════════ ПОДРОБНЫЙ ВЫВОД КОМАНД ══════════\n'; cat "$DETAIL"; } >"$REPORT" 2>/dev/null
chmod 600 "$REPORT" 2>/dev/null
echo
if [ -s "$REPORT" ]; then
  echo "  ${GRN}✔${R} Отчёт сохранён: ${B}${REPORT}${R}   (сводка вверху, затем вывод всех команд)"
  echo "  ${D}Скачать на свой компьютер:  scp root@${PUB_IP}:${REPORT} .${R}"
else
  echo "  ${YLW}▲${R} не удалось записать отчёт в ${REPORT}"
fi
echo
