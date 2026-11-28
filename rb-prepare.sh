#!/usr/bin/env bash
# RatBurrow: подготовка сервера (run_prepare и помощники sshd).
# Часть основного скрипта: подключается из ratburrow.sh (source) и отдельно не запускается.
RB_PART_VERSION="4.14"
if [ "${BASH_SOURCE[0]}" = "$0" ]; then echo "Это часть RatBurrow, запускайте ratburrow.sh"; exit 1; fi

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
  APT_OPTS=(-o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

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

  # [2] обновление системы: каждая стадия — отдельный шаг со своим прогрессом
  section "Обновление системы"
  sub; step_run "$SUBL Обновление списков пакетов" apt_run 0 update -qq || die "apt update не удался"
  apt_upgrade_phase upgrade "Обновление пакетов (upgrade)" 0
  apt_upgrade_phase dist-upgrade "Обновление дистрибутива (dist-upgrade)" 1800
  sub; step_run "$SUBL Удаление ненужных пакетов" apt_run 0 autoremove -y || warn "autoremove не выполнен"

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
